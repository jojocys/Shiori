import AppKit
import Foundation
import SwiftUI

// 统一游戏图标解析（完整实现，验收阻塞解除后整体替换 Shiori/Sources/GameIconProvider.swift）。
// 解析优先级：自定义图标 > 已缓存/在线封面(Steam CDN + VNDB) > EXE 内嵌图标 > 本地松散图片(递归) > 平台符号。
// 在线按“多身份字符串”匹配（显示名 + 清洗名 + exe/ROM/目录文件名 + 清洗文件名），严格归一化匹配避免错配；抓到即磁盘缓存离线复用。

// MARK: - 内存图片缓存（NSCache 线程安全，键含 updatedAt/路径，配置变化即自然失效）

private let iconImageCache = NSCache<NSString, NSImage>()

// MARK: - 在线封面开关（UserDefaults，默认开；RootView 工具栏 Toggle 写同一键）

private var onlineCoverEnabled: Bool {
    if UserDefaults.standard.object(forKey: "icon.onlineFetch") == nil { return true }
    return UserDefaults.standard.bool(forKey: "icon.onlineFetch")
}

// MARK: - 后台执行小工具（CPU 工作移出主线程；返回 Sendable）

private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .utility, operation: work).value
}

// MARK: - 字节读取（全程边界检查，越界返回 nil，绝不崩溃）

private struct ByteReader {
    let raw: UnsafeRawBufferPointer
    var count: Int { raw.count }

    init(_ raw: UnsafeRawBufferPointer) { self.raw = raw }

    func u8(_ o: Int) -> UInt8? {
        guard o >= 0, o + 1 <= count else { return nil }
        return raw[o]
    }

    func u16(_ o: Int) -> UInt16? {
        guard o >= 0, o + 2 <= count else { return nil }
        return UInt16(raw[o]) | (UInt16(raw[o + 1]) << 8)
    }

    func u32(_ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= count else { return nil }
        return UInt32(raw[o]) | (UInt32(raw[o + 1]) << 8) | (UInt32(raw[o + 2]) << 16) | (UInt32(raw[o + 3]) << 24)
    }

    func bytes(at o: Int, count n: Int) -> Data? {
        guard o >= 0, n >= 0, o + n <= count, let base = raw.baseAddress else { return nil }
        return Data(bytes: base.advanced(by: o), count: n)
    }
}

// MARK: - Windows PE (.exe) 内嵌图标提取（离线兜底；不解包 xp3/pac/rpa 等引擎归档）

enum PEIconExtractor {
    private static let rtIcon = 3
    private static let rtGroupIcon = 14

    static func icoData(fromEXEPath path: String) -> Data? {
        guard !path.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              data.count > 0x40 else {
            return nil
        }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            build(ByteReader(raw))
        }
    }

    private static func build(_ reader: ByteReader) -> Data? {
        guard reader.u16(0) == 0x5A4D, let peOffset = reader.u32(0x3C).map({ Int($0) }) else { return nil }
        guard reader.u32(peOffset) == 0x0000_4550 else { return nil }

        let coff = peOffset + 4
        guard let numberOfSections = reader.u16(coff + 2).map({ Int($0) }),
              let sizeOfOptionalHeader = reader.u16(coff + 16).map({ Int($0) }),
              numberOfSections > 0, numberOfSections < 256 else { return nil }

        let optHeader = coff + 20
        guard let magic = reader.u16(optHeader) else { return nil }
        let dataDirOffset: Int
        switch magic {
        case 0x10B: dataDirOffset = optHeader + 96
        case 0x20B: dataDirOffset = optHeader + 112
        default: return nil
        }

        guard let resourceRVA = reader.u32(dataDirOffset + 2 * 8).map({ Int($0) }), resourceRVA != 0 else { return nil }

        let sectionTableOffset = optHeader + sizeOfOptionalHeader
        var sections: [(va: Int, vSize: Int, rawPtr: Int, rawSize: Int)] = []
        for i in 0..<numberOfSections {
            let s = sectionTableOffset + i * 40
            guard let vSize = reader.u32(s + 8).map({ Int($0) }),
                  let vAddr = reader.u32(s + 12).map({ Int($0) }),
                  let rSize = reader.u32(s + 16).map({ Int($0) }),
                  let rPtr = reader.u32(s + 20).map({ Int($0) }) else { return nil }
            sections.append((vAddr, vSize, rPtr, rSize))
        }

        func fileOffset(forRVA rva: Int) -> Int? {
            for sec in sections {
                let span = max(sec.vSize, sec.rawSize)
                if rva >= sec.va, rva < sec.va + span {
                    return sec.rawPtr + (rva - sec.va)
                }
            }
            return nil
        }

        guard let resourceBase = fileOffset(forRVA: resourceRVA) else { return nil }

        struct ResEntry {
            let id: Int
            let isNamed: Bool
            let isDirectory: Bool
            let offset: Int
        }

        func entries(atAbs offset: Int) -> [ResEntry]? {
            guard let named = reader.u16(offset + 12).map({ Int($0) }),
                  let ids = reader.u16(offset + 14).map({ Int($0) }) else { return nil }
            let total = named + ids
            guard total >= 0, total < 4096 else { return nil }
            var result: [ResEntry] = []
            var p = offset + 16
            for _ in 0..<total {
                guard let nameOrId = reader.u32(p).map({ Int($0) }),
                      let off = reader.u32(p + 4).map({ Int($0) }) else { return nil }
                result.append(ResEntry(
                    id: nameOrId & 0x7FFF_FFFF,
                    isNamed: (nameOrId & 0x8000_0000) != 0,
                    isDirectory: (off & 0x8000_0000) != 0,
                    offset: off & 0x7FFF_FFFF
                ))
                p += 8
            }
            return result
        }

        func firstDataEntry(dirRel: Int, depth: Int = 0) -> (rva: Int, size: Int)? {
            guard depth < 8, let list = entries(atAbs: resourceBase + dirRel), let first = list.first else { return nil }
            if first.isDirectory {
                return firstDataEntry(dirRel: first.offset, depth: depth + 1)
            }
            let de = resourceBase + first.offset
            guard let rva = reader.u32(de).map({ Int($0) }), let size = reader.u32(de + 4).map({ Int($0) }) else { return nil }
            return (rva, size)
        }

        guard let level1 = entries(atAbs: resourceBase),
              let groupType = level1.first(where: { !$0.isNamed && $0.id == rtGroupIcon && $0.isDirectory }),
              let iconType = level1.first(where: { !$0.isNamed && $0.id == rtIcon && $0.isDirectory }) else { return nil }

        var iconBlobs: [Int: (offset: Int, size: Int)] = [:]
        if let iconIDs = entries(atAbs: resourceBase + iconType.offset) {
            for entry in iconIDs where entry.isDirectory {
                guard let (rva, size) = firstDataEntry(dirRel: entry.offset),
                      let off = fileOffset(forRVA: rva), size > 0 else { continue }
                iconBlobs[entry.id] = (off, size)
            }
        }
        guard !iconBlobs.isEmpty else { return nil }

        guard let groupIDs = entries(atAbs: resourceBase + groupType.offset),
              let firstGroup = groupIDs.first(where: { $0.isDirectory }),
              let (grva, _) = firstDataEntry(dirRel: firstGroup.offset),
              let groupOffset = fileOffset(forRVA: grva),
              let count = reader.u16(groupOffset + 4).map({ Int($0) }),
              count > 0, count < 1024 else { return nil }

        struct GroupEntry {
            let w: UInt8, h: UInt8, colorCount: UInt8
            let planes: UInt16, bits: UInt16
            let iconID: Int
        }
        var groupEntries: [GroupEntry] = []
        var p = groupOffset + 6
        for _ in 0..<count {
            guard let w = reader.u8(p), let h = reader.u8(p + 1), let cc = reader.u8(p + 2),
                  let planes = reader.u16(p + 4), let bits = reader.u16(p + 6),
                  let iconID = reader.u16(p + 12).map({ Int($0) }) else { return nil }
            groupEntries.append(GroupEntry(w: w, h: h, colorCount: cc, planes: planes, bits: bits, iconID: iconID))
            p += 14
        }

        var usable: [(GroupEntry, Data)] = []
        for entry in groupEntries {
            guard let src = iconBlobs[entry.iconID], let blob = reader.bytes(at: src.offset, count: src.size) else { continue }
            usable.append((entry, blob))
        }
        guard !usable.isEmpty else { return nil }

        var ico = Data()
        func appendU16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { ico.append(contentsOf: $0) } }
        func appendU32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { ico.append(contentsOf: $0) } }

        appendU16(0)
        appendU16(1)
        appendU16(UInt16(usable.count))

        var imageOffset = 6 + usable.count * 16
        for (entry, blob) in usable {
            ico.append(entry.w)
            ico.append(entry.h)
            ico.append(entry.colorCount)
            ico.append(0)
            appendU16(entry.planes)
            appendU16(entry.bits)
            appendU32(UInt32(blob.count))
            appendU32(UInt32(imageOffset))
            imageOffset += blob.count
        }
        for (_, blob) in usable { ico.append(blob) }
        return ico
    }
}

// MARK: - 标题归一化 / 清洗 / 安全匹配

enum TitleMatch {
    private static let noiseTokens: Set<String> = [
        "standard", "deluxe", "edition", "complete", "full", "repack", "nsp", "xci", "iso",
        "cn", "chs", "cht", "jp", "en", "us", "hd", "r18", "steam", "ver", "version", "update", "patch",
        "汉化", "漢化", "简中", "繁中", "全年龄", "体験版"
    ]

    /// 归一化用于比较：小写、去括号内容与噪声词、仅保留字母/数字/CJK。
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        for (open, close) in [("[", "]"), ("(", ")"), ("（", "）"), ("【", "】"), ("「", "」")] {
            while let r1 = t.range(of: open), let r2 = t.range(of: close), r1.lowerBound < r2.lowerBound {
                t.removeSubrange(r1.lowerBound..<t.index(after: r2.lowerBound))
            }
        }
        for tag in noiseTokens { t = t.replacingOccurrences(of: tag, with: " ") }
        var out = ""
        for ch in t where ch.isLetter || ch.isNumber { out.append(ch) }
        return out
    }

    /// 清洗成适合搜索 API 的关键词：去扩展名、分隔符转空格、剔除版本/版本号/区域等噪声 token。
    static func cleanForSearch(_ s: String) -> String {
        var t = s
        if let dot = t.lastIndex(of: "."), t.distance(from: dot, to: t.endIndex) <= 5 {
            t = String(t[t.startIndex..<dot])
        }
        t = String(t.map { "-_.+~".contains($0) ? " " : $0 })
        let tokens = t.split(separator: " ").map(String.init).filter { tok in
            let low = tok.lowercased()
            if noiseTokens.contains(low) { return false }
            if low.first == "v", low.count > 1, low.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) { return false }
            if low.allSatisfy({ $0.isNumber }) { return false }
            if low.range(of: "^[0-9]+\\.[0-9.]+$", options: .regularExpression) != nil { return false }
            return true
        }
        let cleaned = tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? s : cleaned
    }

    /// 严格匹配：归一化相等，或较长一方包含另一方（最短长度≥5，避免短词误配）。
    static func matches(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        if min(x.count, y.count) >= 5, x.contains(y) || y.contains(x) { return true }
        return false
    }

    /// FNV-1a，稳定哈希用于磁盘缓存文件名。
    static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

// MARK: - 在线封面磁盘缓存（~/.shiori/icons/cache）

enum RemoteIconCache {
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shiori/icons/cache", isDirectory: true)
    }

    static func fileURL(_ key: String) -> URL { dir.appendingPathComponent(key + ".img") }

    static func read(_ key: String) -> Data? {
        let url = fileURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func write(_ data: Data, key: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL(key), options: .atomic)
    }

    static func clear(_ key: String) {
        try? FileManager.default.removeItem(at: fileURL(key))
    }
}

/// 会话级“查不到”缓存：避免同一游戏每次出现都重复打网络。
private actor NegativeCoverCache {
    static let shared = NegativeCoverCache()
    private var keys: Set<String> = []
    func contains(_ k: String) -> Bool { keys.contains(k) }
    func insert(_ k: String) { keys.insert(k) }
    func remove(_ k: String) { keys.remove(k) }
}

// MARK: - 在线封面源（Steam CDN + Steam 商店搜索 + VNDB，均免 key）

/// 网络层异常：transient（连不上/超时/被限流/5xx）应重试，不能毒化负缓存。
enum CoverError: Error { case network }

/// 限制并发抓取数，避免启动时多游戏齐发把 Steam/VNDB 打到限流而集体失败。
private actor CoverFetchGate {
    static let shared = CoverFetchGate()
    private let limit = 2
    private var inUse = 0
    private var queue: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if inUse < limit { inUse += 1; return }
        await withCheckedContinuation { queue.append($0) }
    }

    func release() {
        if queue.isEmpty {
            inUse -= 1
        } else {
            queue.removeFirst().resume()   // 名额直接转交等待者，inUse 不变
        }
    }
}

enum CoverSources {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 12
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private enum HTTPResult { case ok(Data); case status(Int); case transport }

    private static func http(_ request: URLRequest) async -> HTTPResult {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .transport }
            return (200...299).contains(http.statusCode) ? .ok(data) : .status(http.statusCode)
        } catch {
            return .transport
        }
    }

    /// 返回匹配的 appID；nil = 服务器答了但无匹配；throw = 网络/服务异常（应重试）。
    static func steamAppID(matching query: String) async throws -> Int? {
        guard let term = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://store.steampowered.com/api/storesearch/?term=\(term)&cc=us&l=en") else { return nil }
        let data: Data
        switch await http(URLRequest(url: url)) {
        case .ok(let d): data = d
        case .status, .transport: throw CoverError.network
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return nil }
        for item in items {
            guard (item["type"] as? String) == "app",
                  let name = item["name"] as? String,
                  TitleMatch.matches(name, query) else { continue }
            if let id = item["id"] as? Int { return id }
            if let idStr = item["id"] as? String, let id = Int(idStr) { return id }
        }
        return nil
    }

    /// 取封面图；nil = 各尺寸都 404（确无图）；throw = 网络/限流（应重试）。
    static func steamCoverData(appID: Int) async throws -> Data? {
        for file in ["library_600x900.jpg", "header.jpg", "capsule_616x353.jpg"] {
            guard let url = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/\(file)") else { continue }
            switch await http(URLRequest(url: url)) {
            case .ok(let data) where data.count > 1024: return data
            case .ok, .status(404): continue                      // 该尺寸不存在，试下一个
            case .status, .transport: throw CoverError.network     // 429/5xx/连不上 → 重试
            }
        }
        return nil
    }

    /// 取 VNDB 封面；nil = 无匹配；throw = 网络/服务异常（应重试）。
    static func vndbCoverData(matching query: String) async throws -> Data? {
        guard let url = URL(string: "https://api.vndb.org/kana/vn") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "filters": ["search", "=", query],
            "fields": "title,titles.title,image.url",
            "results": 6
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let data: Data
        switch await http(request) {
        case .ok(let d): data = d
        case .status, .transport: throw CoverError.network
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return nil }
        for result in results {
            var names: [String] = []
            if let t = result["title"] as? String { names.append(t) }
            if let ts = result["titles"] as? [[String: Any]] { names += ts.compactMap { $0["title"] as? String } }
            guard names.contains(where: { TitleMatch.matches($0, query) }) else { continue }
            if let image = result["image"] as? [String: Any],
               let urlStr = image["url"] as? String,
               let imgURL = URL(string: urlStr) {
                if case .ok(let cover) = await http(URLRequest(url: imgURL)) { return cover }
            }
        }
        return nil
    }
}

// MARK: - 统一图标解析（分层异步管线）

enum GameIconResolver {
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "icns", "ico", "bmp", "tiff", "gif", "webp"]
    private static let preferredNames = ["icon", "cover", "logo", "title", "package", "jacket", "poster", "banner", "app", "game", "favicon", "thumbnail", "表紙", "ジャケ"]

    /// 主入口：返回可被 NSImage 解析的图片数据（在主线程构建 NSImage）。
    static func iconData(for game: GameEntry) async -> Data? {
        if let manual = await offMain({ manualIconData(game) }) { return manual }
        if let cover = await remoteCoverData(for: game) { return cover }
        if let local = await offMain({ localIconData(game) }) { return local }
        return nil
    }

    private static func manualIconData(_ game: GameEntry) -> Data? {
        guard !game.iconPath.isEmpty, FileManager.default.fileExists(atPath: game.iconPath) else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: game.iconPath))
    }

    private static func localIconData(_ game: GameEntry) -> Data? {
        if game.platform == .windows, !game.exePath.isEmpty,
           FileManager.default.fileExists(atPath: game.exePath),
           let ico = PEIconExtractor.icoData(fromEXEPath: game.exePath) {
            return ico
        }
        return folderIconData(folderPath: game.gameFolderPath)
    }

    // MARK: 在线封面（多身份候选 + 磁盘缓存 + 负缓存）

    /// 构造身份候选：显示名、清洗名、主文件名(exe/rom/script)与其清洗、目录名与其清洗。按归一化去重。
    static func identityCandidates(for game: GameEntry) -> [String] {
        var raw: [String] = [game.name, TitleMatch.cleanForSearch(game.name)]
        let mainFile = !game.exePath.isEmpty ? game.exePath
            : (!game.romPath.isEmpty ? game.romPath : game.launchScriptPath)
        if !mainFile.isEmpty {
            let base = URL(fileURLWithPath: mainFile).deletingPathExtension().lastPathComponent
            raw.append(base)
            raw.append(TitleMatch.cleanForSearch(base))
        }
        if !game.gameFolderPath.isEmpty {
            let folder = URL(fileURLWithPath: game.gameFolderPath).lastPathComponent
            raw.append(folder)
            raw.append(TitleMatch.cleanForSearch(folder))
        }
        // 按“实际搜索串”去重（而非归一化）：清洗会抹掉 _cn / 版本号等，
        // 但这些恰恰是搜索 API 的关键差异（"DimensionToTsuLovers_cn" 搜不到，"DimensionToTsuLovers" 能搜到），
        // 所以两者都要保留尝试；仅丢弃归一化后为空（无可用字符）的候选。
        var seen = Set<String>()
        var result: [String] = []
        for cand in raw {
            let trimmed = cand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !TitleMatch.normalize(trimmed).isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func cacheKey(_ candidate: String) -> String {
        "name-" + TitleMatch.stableHash(TitleMatch.normalize(candidate))
    }

    private static func remoteCoverData(for game: GameEntry) async -> Data? {
        let candidates = identityCandidates(for: game)
        guard let primary = candidates.first else { return nil }
        // 任一候选命中磁盘缓存即返回（离线可用）。
        for cand in candidates {
            if let cached = RemoteIconCache.read(cacheKey(cand)) { return cached }
        }
        guard onlineCoverEnabled else { return nil }
        let primaryKey = cacheKey(primary)
        if await NegativeCoverCache.shared.contains(primaryKey) { return nil }

        await CoverFetchGate.shared.acquire()
        let (cover, sawNetworkError) = await fetchCover(candidates: candidates)
        await CoverFetchGate.shared.release()

        if let cover {
            RemoteIconCache.write(cover, key: primaryKey)
            return cover
        }
        // 仅在“服务器答复了但确无匹配”时毒化负缓存；网络/限流失败留待下次重试。
        if !sawNetworkError {
            await NegativeCoverCache.shared.insert(primaryKey)
        }
        return nil
    }

    /// 逐候选试 Steam → VNDB。返回（命中封面 / 是否遇到网络异常）。
    private static func fetchCover(candidates: [String]) async -> (Data?, Bool) {
        var sawNetworkError = false
        for cand in candidates {
            do {
                if let id = try await CoverSources.steamAppID(matching: cand),
                   let cover = try await CoverSources.steamCoverData(appID: id) {
                    return (cover, false)
                }
            } catch { sawNetworkError = true }
            do {
                if let cover = try await CoverSources.vndbCoverData(matching: cand) {
                    return (cover, false)
                }
            } catch { sawNetworkError = true }
        }
        return (nil, sawNetworkError)
    }

    /// 清掉某游戏的在线缓存与负缓存（“重新获取封面”用）。
    static func clearRemoteCache(for game: GameEntry) {
        for cand in identityCandidates(for: game) {
            let key = cacheKey(cand)
            RemoteIconCache.clear(key)
            Task { await NegativeCoverCache.shared.remove(key) }
        }
    }

    // MARK: 本地松散图片（有界递归，不解包引擎归档）

    private static func folderIconData(folderPath: String) -> Data? {
        guard !folderPath.isEmpty else { return nil }
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        let images = collectImages(in: folderURL, maxDepth: 2, limit: 300)
        guard !images.isEmpty else { return nil }
        let ranked = images.sorted { iconScore($0) > iconScore($1) }
        for url in ranked.prefix(8) {
            if let data = try? Data(contentsOf: url) { return data }
        }
        return nil
    }

    private static func collectImages(in root: URL, maxDepth: Int, limit: Int) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        var stack: [(URL, Int)] = [(root, 0)]
        var visited = 0
        while let (dir, depth) = stack.popLast(), results.count < limit {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                visited += 1
                if visited > limit * 4 { break }
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    if depth < maxDepth { stack.append((item, depth + 1)) }
                } else if imageExtensions.contains(item.pathExtension.lowercased()) {
                    results.append(item)
                    if results.count >= limit { break }
                }
            }
        }
        return results
    }

    private static func iconScore(_ url: URL) -> Int {
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        var score = 0
        if preferredNames.contains(where: { base == $0 }) { score += 100 }
        else if preferredNames.contains(where: { base.contains($0) }) { score += 50 }
        if ext == "ico" || ext == "icns" { score += 20 }
        if ext == "png" { score += 10 }
        return score
    }
}

// MARK: - 封面呈现样式

/// 方案 B（.blur）：前景 fit 完整显示，背景同图放大 + 高斯模糊 + 压暗铺满 → 完整、填满、统一。
/// .fillCrop：填充裁切（小尺寸用，如侧栏；小图上模糊会发灰）。
enum CoverStyle { case blur, fillCrop }

// MARK: - 游戏图标视图（异步加载 + 缓存 + 方案 B 模糊底 / 填充裁切 + 平台符号回退）

struct GameIconView: View {
    let game: GameEntry
    var size: CGFloat? = nil        // nil = 填充父容器（随窗口/侧栏等比例缩放）；非 nil = 固定宽
    var height: CGFloat? = nil      // 竖版高度；与 size 配合贴合封面比例
    var cornerRadius: CGFloat = 10
    var style: CoverStyle = .blur
    var dim: Double = 0.32          // 方案 B 背景压暗强度

    @State private var image: NSImage?

    private var signature: String {
        "game|\(game.id.uuidString)|\(game.iconPath)|\(game.exePath)|\(game.romPath)|\(game.gameFolderPath)|\(game.name)|\(game.platform.rawValue)|\(game.updatedAt.timeIntervalSince1970)"
    }

    private var fallbackSymbol: String {
        game.platform == .switchEmu ? "gamecontroller.fill" : "puzzlepiece.fill"
    }

    private var fallbackColor: Color {
        game.platform == .switchEmu ? .green : .accentColor
    }

    var body: some View {
        Group {
            if let size {
                iconContent.frame(width: size, height: height ?? size)
            } else {
                iconContent     // 由调用方用 .aspectRatio/.frame 决定尺寸 → 自适应缩放
            }
        }
        .task(id: signature) { await load() }
    }

    private var blurRadius: CGFloat { max(6, (size ?? 190) * 0.12) }

    // base（RoundedRectangle）决定尺寸；封面图层作为 overlay 绝不撑大容器；末尾 clipShape 裁掉一切溢出。
    private var iconContent: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .overlay(coverLayers)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var coverLayers: some View {
        if let image {
            switch style {
            case .blur:
                // 方案 B：同图放大模糊压暗作底 + 前景完整 fit。
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(1.15)
                        .blur(radius: blurRadius)
                    Color.black.opacity(dim)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
            case .fillCrop:
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            }
        } else {
            GeometryReader { geo in
                Image(systemName: fallbackSymbol)
                    .font(.system(size: max(12, min(geo.size.width, geo.size.height) * 0.42), weight: .semibold))
                    .foregroundStyle(fallbackColor)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func load() async {
        let key = signature as NSString
        if let cached = iconImageCache.object(forKey: key) {
            image = cached
            return
        }
        image = nil
        let snapshot = game
        let data = await GameIconResolver.iconData(for: snapshot)
        guard let data, let resolved = NSImage(data: data) else { return }
        iconImageCache.setObject(resolved, forKey: key)
        if key == (signature as NSString) {
            image = resolved
        }
    }
}

// MARK: - Steam 游戏图标（appID → Steam CDN 优先；离线退 librarycache；完整显示）

enum SteamIconResolver {
    static func iconData(for game: SteamLibraryGame) async -> Data? {
        if !game.appID.isEmpty {
            let key = "steam-\(game.appID)"
            if let cached = RemoteIconCache.read(key) { return cached }
            if onlineCoverEnabled, let id = Int(game.appID) {
                await CoverFetchGate.shared.acquire()
                let cover = try? await CoverSources.steamCoverData(appID: id)
                await CoverFetchGate.shared.release()
                if let cover {
                    RemoteIconCache.write(cover, key: key)
                    return cover
                }
            }
        }
        return await offMain { librarycacheData(game) }
    }

    private static func librarycacheData(_ game: SteamLibraryGame) -> Data? {
        guard !game.appID.isEmpty, !game.libraryPath.isEmpty else { return nil }
        let fm = FileManager.default
        let cacheRoot = URL(fileURLWithPath: game.libraryPath, isDirectory: true)
            .appendingPathComponent("appcache", isDirectory: true)
            .appendingPathComponent("librarycache", isDirectory: true)

        let legacy = cacheRoot.appendingPathComponent("\(game.appID)_icon.jpg")
        if fm.fileExists(atPath: legacy.path), let data = try? Data(contentsOf: legacy) { return data }

        let perAppDir = cacheRoot.appendingPathComponent(game.appID, isDirectory: true)
        if let items = try? fm.contentsOfDirectory(at: perAppDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let images = items.filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            let ranked = images.sorted { score($0) > score($1) }
            for url in ranked.prefix(4) {
                if let data = try? Data(contentsOf: url) { return data }
            }
        }
        return nil
    }

    private static func score(_ url: URL) -> Int {
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        if base.contains("icon") { return 100 }
        if base.contains("logo") { return 60 }
        if base.contains("header") { return 30 }
        return 10
    }
}

struct SteamGameIconView: View {
    let game: SteamLibraryGame
    var size: CGFloat? = nil
    var height: CGFloat? = nil
    var cornerRadius: CGFloat = 10
    var style: CoverStyle = .blur
    var dim: Double = 0.32

    @State private var image: NSImage?

    private var signature: String {
        "steam|\(game.id)|\(game.libraryPath)|\(game.appID)"
    }

    private var blurRadius: CGFloat { max(6, (size ?? 190) * 0.12) }

    var body: some View {
        Group {
            if let size {
                iconContent.frame(width: size, height: height ?? size)
            } else {
                iconContent
            }
        }
        .task(id: signature) { await load() }
    }

    private var iconContent: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.blue.opacity(0.25), Color.blue.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(coverLayers)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var coverLayers: some View {
        if let image {
            switch style {
            case .blur:
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(1.15)
                        .blur(radius: blurRadius)
                    Color.black.opacity(dim)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
            case .fillCrop:
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            }
        } else {
            GeometryReader { geo in
                Image(systemName: "s.circle.fill")
                    .font(.system(size: max(14, min(geo.size.width, geo.size.height) * 0.5), weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func load() async {
        let key = signature as NSString
        if let cached = iconImageCache.object(forKey: key) {
            image = cached
            return
        }
        image = nil
        let snapshot = game
        let data = await SteamIconResolver.iconData(for: snapshot)
        guard let data, let resolved = NSImage(data: data) else { return }
        iconImageCache.setObject(resolved, forKey: key)
        if key == (signature as NSString) {
            image = resolved
        }
    }
}

// MARK: - 大图预览（原图完整 fit + 全屏同图模糊压暗底，点任意处关闭）

struct GameCoverPreview: View {
    let game: GameEntry
    var onClose: () -> Void

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                // 全屏模糊压暗底（同图）
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(1.2)
                    .blur(radius: 44)
                    .overlay(Color.black.opacity(0.55))
                    .ignoresSafeArea()
                // 前景：原图比例完整显示，绝不裁切
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 460, maxHeight: 640)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .padding(28)
            } else {
                ProgressView()
            }

            VStack {
                Spacer()
                VStack(spacing: 4) {
                    Text(game.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text("点击任意处关闭")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.bottom, 20)
            }
        }
        .frame(minWidth: 520, minHeight: 640)
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
        .task(id: game.id) {
            if let cached = iconImageCache.object(forKey: "preview|\(game.id.uuidString)" as NSString) {
                image = cached
                return
            }
            let snapshot = game
            let data = await GameIconResolver.iconData(for: snapshot)
            guard let data, let resolved = NSImage(data: data) else { return }
            iconImageCache.setObject(resolved, forKey: "preview|\(game.id.uuidString)" as NSString)
            image = resolved
        }
    }
}
