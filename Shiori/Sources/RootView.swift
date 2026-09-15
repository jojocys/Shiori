import AppKit
import Combine
import SwiftUI

// MARK: - UI model helpers

/// 外观偏好：跟随系统 / 浅色 / 深色。持久化于 @AppStorage。
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 界面语言偏好。默认使用中文，并随用户选择持久化。
enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

/// 侧栏顶层入口：Shiori 主页（配置选择）/ Wine Steam / 单个游戏。
enum SidebarItem: Hashable {
    case home
    case steam
    case game(UUID)
}

/// 游戏详情内的次级标签。运行环境通常只用一次，作为次级页签。
enum GameSection: String, CaseIterable, Identifiable {
    case setup    // P1 选择游戏（频繁）
    case runtime  // P2 运行环境（一次性）

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .setup: return "游戏设置"
        case .runtime: return "运行环境"
        }
    }

    var symbol: String {
        switch self {
        case .setup: return "folder"
        case .runtime: return "gearshape.2"
        }
    }
}

/// 测量侧栏宽度，用于图标随侧栏等比例缩放。
private struct SidebarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 264
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Keep AppKit's toolbar item at a constant size; only the capsule inside it expands.
private struct UpdateToolbarButton: View {
    let title: String
    let helpText: String
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            UpdateToolbarLabel(title: title, expansion: isHovered && isEnabled ? 1 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(Text(verbatim: title))
        .help(Text(verbatim: helpText))
        // Observe the actual button, before adding the reserved toolbar space.
        // The invisible space to its left must neither trigger hover nor accept clicks.
        .onHover { isHovered = $0 && isEnabled }
        .animation(
            reduceMotion ? nil : .timingCurve(0.22, 0.75, 0.25, 1, duration: 0.34),
            value: isHovered && isEnabled
        )
        .frame(width: UpdateToolbarLabel.reservedWidth, height: 28, alignment: .trailing)
        .onChange(of: isEnabled) { enabled in
            if !enabled { isHovered = false }
        }
        .onDisappear { isHovered = false }
    }
}

/// A single reversible timeline avoids delayed callbacks and competing hover animations.
private struct UpdateToolbarLabel: View, Animatable {
    let title: String
    var expansion: CGFloat

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let collapsedWidth: CGFloat = 30

    private static func expandedWidth(for title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width) + 40
    }

    // Reserve both supported languages so switching languages also leaves adjacent
    // toolbar controls in place. The capsule still fits its current localized title.
    static let reservedWidth = max(expandedWidth(for: "更新"), expandedWidth(for: "Update"))

    var body: some View {
        let progress = min(max(expansion, 0), 1)
        let widthProgress = min(progress / 0.74, 1)
        let textProgress = max((progress - 0.74) / 0.26, 0)
        let width = Self.collapsedWidth + (Self.expandedWidth(for: title) - Self.collapsedWidth) * widthProgress

        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.09 * progress))

            Image(systemName: "arrow.down.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .overlay {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .opacity(progress)
                }
                .frame(width: 16, height: 28)
                .padding(.leading, 7)
                .allowsHitTesting(false)

            Text(verbatim: title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
                // The full label fades in only after the capsule has room for it.
                // Reversing hover hides it before shrinking, so no glyph is sliced.
                .opacity(textProgress)
                .offset(x: 2 * (1 - textProgress))
                .padding(.leading, 28)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: 28, alignment: .leading)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .accessibilityHidden(true)
    }
}

struct RootView: View {
    @ObservedObject var store: AppStore
    let checkForUpdates: () -> Void
    var canCheckForUpdates: Bool = true

    @AppStorage("ui.appearance") private var appearanceRaw = AppearancePreference.system.rawValue
    @AppStorage("ui.language") private var languageRaw = AppLanguage.simplifiedChinese.rawValue
    @AppStorage("icon.onlineFetch") private var onlineFetchIcons = true
    @State private var sidebarSelection: SidebarItem?
    @State private var gameSection: GameSection = .setup
    @State private var showDeleteConfirm = false
    @State private var pendingWineSteamDelete: SteamLibraryGame?
    @State private var pendingMacSteamReimport: SteamLibraryGame?
    @State private var coverPreviewGame: GameEntry?
    @State private var sidebarWidth: CGFloat = 264
    private let steamRefreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .simplifiedChinese
    }

    /// 将运行时 String（状态、三元表达式和复用组件参数）按当前界面语言查表。
    /// SwiftUI 的字符串字面量由 locale 环境自动处理，这里补足无法自动推断为
    /// LocalizedStringKey 的文本。
    private func localized(_ key: String) -> String {
        guard language == .english,
              let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return key }
        return NSLocalizedString(key, bundle: bundle, value: key, comment: "")
    }

    /// 侧栏图标宽度随侧栏宽度等比例缩放（拖宽侧栏 → 图标变大）。1:1 正方 + 填充裁切。
    private var sidebarIconWidth: CGFloat {
        min(max(sidebarWidth * 0.15, 40), 56)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1120, minHeight: 720)
        .preferredColorScheme(appearance.colorScheme)
        .environment(\.locale, language.locale)
        .toolbar { toolbarContent }
        .confirmationDialog("删除当前配置？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) { store.removeSelectedGame() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除配置记录，不删除游戏文件。")
        }
        .confirmationDialog("删除 Wine Steam 游戏文件？", isPresented: wineSteamDeleteBinding, titleVisibility: .visible) {
            if let game = pendingWineSteamDelete {
                Button("删除文件", role: .destructive) {
                    store.deleteWineSteamGame(game)
                    pendingWineSteamDelete = nil
                }
            }
            Button("取消", role: .cancel) { pendingWineSteamDelete = nil }
        } message: {
            if let game = pendingWineSteamDelete {
                Text("将删除 \(game.name) 的 Wine Steam manifest、安装目录、下载缓存和对应创意工坊内容。Mac Steam 原文件不会被删除。")
            }
        }
        .confirmationDialog("删除 Wine 侧并重新预填充？", isPresented: macSteamReimportBinding, titleVisibility: .visible) {
            if let game = pendingMacSteamReimport {
                Button("删除并重新预填充", role: .destructive) {
                    store.resetWineSteamGameAndPrefill(game)
                    pendingMacSteamReimport = nil
                }
            }
            Button("取消", role: .cancel) { pendingMacSteamReimport = nil }
        } message: {
            if let game = pendingMacSteamReimport {
                Text("会先结束 Wine Steam，删除 \(game.name) 在 Wine Steam 里的 manifest、安装目录、下载缓存和相关缓存，然后只从 Mac Steam 本地复制可复用文件。Mac Steam 原文件不会被删除。")
            }
        }
        .sheet(item: $coverPreviewGame) { game in
            coverPreview(game)
        }
        .onAppear(perform: syncInitialSelection)
        .onChange(of: sidebarSelection) { selection in
            if selection == .home || selection == .steam {
                store.refreshSteamLibraries()
            }
        }
        .onChange(of: store.selectedGameID) { newID in
            // 列表变化（如删除）后保持侧栏与 store 同步，但不打断 Steam 视图。
            if case .game = sidebarSelection {
                sidebarSelection = newID.map(SidebarItem.game)
            } else if sidebarSelection == nil {
                sidebarSelection = newID.map(SidebarItem.game)
            }
        }
        .onReceive(steamRefreshTimer) { _ in
            if sidebarSelection == .home || sidebarSelection == .steam {
                store.refreshSteamLibraries()
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            UpdateToolbarButton(
                title: localized("更新"),
                helpText: localized("检查并安装 Shiori 更新"),
                isEnabled: canCheckForUpdates,
                action: checkForUpdates
            )

            Button {
                refreshAllUserData()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新")

            Menu {
                Picker("语言", selection: $languageRaw) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "globe")
            }
            .help("语言")

            Menu {
                Picker("外观", selection: $appearanceRaw) {
                    ForEach(AppearancePreference.allCases) { pref in
                        Label(pref.title, systemImage: pref.symbol).tag(pref.rawValue)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("在线获取游戏封面", isOn: $onlineFetchIcons)
            } label: {
                Image(systemName: appearance.symbol)
            }
            .help("浅色 / 深色主题 · 在线封面")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            brandHeader

            List(selection: sidebarBinding) {
                Section {
                    steamRow.tag(SidebarItem.steam)
                }

                Section("我的游戏") {
                    ForEach(store.games) { game in
                        gameRow(game).tag(SidebarItem.game(game.id))
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            sidebarFooter
        }
        .frame(minWidth: 264)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: SidebarWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(SidebarWidthKey.self) { sidebarWidth = $0 }
    }

    private var brandHeader: some View {
        Button {
            sidebarSelection = .home
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppInfo.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(AppInfo.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(sidebarSelection == .home ? Color.accentColor.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help("主页 · 配置选择")
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var steamRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "s.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Wine Steam")
                    .font(.headline)
                Text(localized(store.wineSteamGames.isEmpty
                     ? "独立客户端入口"
                     : "\(store.wineSteamGames.count) 个游戏 · 独立入口"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func gameRow(_ game: GameEntry) -> some View {
        HStack(spacing: 11) {
            GameIconView(game: game, size: sidebarIconWidth, cornerRadius: max(6, sidebarIconWidth * 0.2), style: .fillCrop)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(game.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            platformBadge(game.platform)
        }
        .padding(.vertical, 6)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            Button {
                createAndOpenGame()
            } label: {
                Label("新建配置", systemImage: "plus")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.large)

            HStack {
                Text(language == .english
                     ? "\(store.games.count) configurations · v\(AppInfo.version)"
                     : "共 \(store.games.count) 个配置 · v\(AppInfo.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("刷新") {
                    refreshAllUserData()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// 顶部与侧栏的全局刷新必须覆盖主页中展示的全部数据，包括 Wine Steam 新安装游戏。
    private func refreshAllUserData() {
        store.load()
        store.refreshRuntimeStatus()
        store.refreshSteamLibraries(userInitiated: true)
    }

    // MARK: Detail switch

    @ViewBuilder
    private var detail: some View {
        switch sidebarSelection {
        case .home:
            homeDetail
        case .steam:
            steamDetail
        case .game:
            gameDetail
        case .none:
            homeDetail
        }
    }

    // MARK: Home / 配置选择页

    private var homeDetail: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        homeSectionHeader(
                            "我的游戏",
                            count: store.games.count,
                            systemImage: "square.grid.2x2",
                            actionTitle: "新建配置"
                        ) {
                            createAndOpenGame()
                        }
                        if store.games.isEmpty {
                            emptyConfigInline
                        } else {
                            LazyVGrid(columns: homeGridColumns, spacing: 16) {
                                ForEach(store.games) { game in
                                    gameCard(game)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        homeWineSteamSectionHeader
                        if store.wineSteamGames.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "tray")
                                    .foregroundStyle(.secondary)
                                Text("尚未发现 Wine Steam 本地游戏")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                            )
                        } else {
                            LazyVGrid(columns: homeGridColumns, spacing: 16) {
                                ForEach(store.wineSteamGames) { game in
                                    steamGameCard(game)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }

            statusBar
        }
    }

    /// 固定一行 4 列、等宽 → 每张卡片一致，随窗口宽度整体等比缩放。
    private var homeGridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)
    }

    private var emptyConfigInline: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray")
                .foregroundStyle(.secondary)
            Text("还没有手动添加的游戏配置")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func homeSectionHeader(
        _ title: LocalizedStringKey,
        count: Int,
        systemImage: String,
        actionTitle: LocalizedStringKey = "管理",
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
            Text(title)
                .font(.title3.weight(.semibold))
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .foregroundStyle(.secondary)
            Spacer()
            if let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: "plus")
                        .font(.headline.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.large)
            }
        }
        .frame(minHeight: 42)
    }

    private var homeWineSteamSectionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "s.circle.fill")
                .foregroundStyle(.tint)
            Text("Wine Steam 游戏")
                .font(.title3.weight(.semibold))
            Text("\(store.wineSteamGames.count)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                openAndLaunchWineSteam()
            } label: {
                Label("启动 Steam 客户端", systemImage: "play.fill")
                    .font(.headline.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
        }
        .frame(minHeight: 58)
    }

    private func gameCard(_ game: GameEntry) -> some View {
        let configured = isConfigured(game)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                openGame(game.id)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    // 主卡片点击进入对应配置详情；启动键是独立操作，不会改变当前配置页。
                    Color.clear
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .overlay(GameIconView(game: game, cornerRadius: 0))
                        .overlay(alignment: .topTrailing) {
                            platformBadge(game.platform).padding(8)
                        }
                        .clipped()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(game.displaySubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack {
                            Text(localized(configured ? "已配置" : "未配置"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                store.startGame(game)
            } label: {
                Label(localized(configured ? "启动" : "请先完成配置"), systemImage: configured ? "play.fill" : "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(configured ? .green : .secondary)
            .controlSize(.small)
            .disabled(!configured)
            .help(configured ? "直接启动该游戏" : "点击卡片进入配置页并完成设置")
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 主页的 Wine Steam 游戏卡片：与配置卡片同构，但主操作是启动（或安装/验证）。
    private func steamGameCard(_ game: SteamLibraryGame) -> some View {
        let readyToLaunch = store.isWineSteamGameReadyToLaunch(game)
        let isLaunching = store.isLaunchingWineSteamGame(game)
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay(SteamGameIconView(game: game, cornerRadius: 0))
                .overlay(alignment: .topTrailing) {
                    steamPill(game.sourceLabel, color: game.isPreloadOnly ? .orange : .green).padding(8)
                }
                .clipped()
            VStack(alignment: .leading, spacing: 8) {
                Text(game.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(game.sizeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button {
                    store.launchWineSteamGame(game)
                } label: {
                    Label(
                        localized(isLaunching ? "启动中…" : (readyToLaunch ? "启动" : "安装/验证")),
                        systemImage: isLaunching ? "hourglass" : (readyToLaunch ? "play.fill" : "checkmark.arrow.trianglehead.counterclockwise")
                    )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(readyToLaunch ? .green : .orange)
                .controlSize(.small)
                .disabled(isLaunching)
                .help(readyToLaunch ? "通过 Wine Steam 启动该游戏" : "打开 Wine Steam 安装/验证，只复用校验通过的文件")
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 大图预览：点击配置内的图标弹出，原图完整显示 + 全屏模糊压暗底。
    private func coverPreview(_ game: GameEntry) -> some View {
        GameCoverPreview(game: game) { coverPreviewGame = nil }
    }

    // MARK: Game detail

    private var gameDetail: some View {
        VStack(spacing: 0) {
            gameHeader
            Divider()

            Picker("", selection: $gameSection) {
                ForEach(GameSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 18) {
                    switch gameSection {
                    case .setup:   setupContent
                    case .runtime: runtimeContent
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            statusBar
        }
    }

    /// 头部：常驻的「启动」重点区。开始游戏为最大主操作。
    private var gameHeader: some View {
        let game = store.selectedGame
        return HStack(alignment: .top, spacing: 16) {
            if let game {
                Button {
                    coverPreviewGame = game
                } label: {
                    GameIconView(game: game, size: 100, height: 132, cornerRadius: 14)
                }
                .buttonStyle(.plain)
                .help("点击查看大图")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(game?.name ?? localized("未选择"))
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    platformBadge(game?.platform ?? .windows)
                    enginePill(game?.engineHint ?? "未识别")
                    Text(mainFileDisplay(game))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                // 语言模式是 Wine locale，仅 Windows 适用；Switch 隐藏。
                if game?.platform != .switchEmu {
                    HStack(spacing: 10) {
                        Text("语言")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("启动语言", selection: launchLanguageBinding) {
                            ForEach(LaunchLanguageMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                        .disabled(game == nil)
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 10) {
                Button {
                    store.startGame()
                } label: {
                    Label("开始游戏", systemImage: "play.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(game == nil)

                HStack(spacing: 8) {
                    Button {
                        store.openLastLog()
                    } label: {
                        Label("日志", systemImage: "doc.text")
                    }
                    .controlSize(.small)
                    .disabled(store.lastLogPath.isEmpty)

                    Button {
                        store.openSelectedGameFolder()
                    } label: {
                        Label("目录", systemImage: "folder")
                    }
                    .controlSize(.small)
                    .disabled(game == nil)

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除配置", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .disabled(game == nil)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: P1 设置内容

    private var setupContent: some View {
        VStack(spacing: 18) {
            if let scan = store.scanResult, !scan.antiCheats.isEmpty {
                antiCheatBanner(scan.antiCheats)
            }

            card {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("选择游戏", subtitle: "选择整个游戏目录，自动扫描并推荐主程序。")

                    // 主操作：选择文件夹（大）
                    Button {
                        store.chooseAndScanGameFolder()
                    } label: {
                        Label("选择游戏文件夹", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("o", modifiers: [.command])

                    // 次级操作（中）
                    HStack(spacing: 10) {
                        Button {
                            store.rescanCurrentFolder()
                        } label: {
                            Label("重新扫描", systemImage: "arrow.clockwise")
                        }
                        if store.selectedGame?.platform == .switchEmu {
                            Button {
                                store.chooseSwitchROM()
                            } label: {
                                Label("手动选择 ROM", systemImage: "doc")
                            }
                        } else {
                            Button {
                                store.chooseEXEManually()
                            } label: {
                                Label("手动选择 EXE", systemImage: "doc")
                            }
                        }
                    }

                    labeledField("配置名称") {
                        TextField("例如：Senren Banka", text: nameBinding)
                            .textFieldStyle(.roundedBorder)
                    }

                    labeledField("当前目录") {
                        Text(store.selectedGame?.gameFolderPath.isEmpty == false
                             ? (store.selectedGame?.gameFolderPath ?? "")
                             : "尚未选择")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    labeledField("图标") {
                        HStack(spacing: 12) {
                            if let game = store.selectedGame {
                                Button {
                                    coverPreviewGame = game
                                } label: {
                                    GameIconView(game: game, size: 60, height: 84, cornerRadius: 12)
                                }
                                .buttonStyle(.plain)
                                .help("点击查看大图")
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(store.selectedGameHasCustomIcon
                                     ? "使用自定义图标"
                                     : "自动：在线封面(Steam/VNDB) → EXE 内嵌图标 → 目录图片 → 默认符号")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 8) {
                                    Button {
                                        store.chooseCustomIconForSelectedGame()
                                    } label: {
                                        Label("选择图标", systemImage: "photo")
                                    }
                                    .controlSize(.small)

                                    Button {
                                        store.refetchIconForSelectedGame()
                                    } label: {
                                        Label("重新获取封面", systemImage: "arrow.down.circle")
                                    }
                                    .controlSize(.small)
                                    .disabled(store.selectedGameHasCustomIcon)
                                    .help("清掉缓存，重新从 Steam/VNDB 抓取游戏封面")

                                    Button {
                                        store.clearCustomIconForSelectedGame()
                                    } label: {
                                        Label("恢复默认", systemImage: "arrow.uturn.backward")
                                    }
                                    .controlSize(.small)
                                    .disabled(!store.selectedGameHasCustomIcon)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            if let scan = store.scanResult {
                card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            sectionTitle("扫描结果", subtitle: nil)
                            Spacer()
                            statBadge("引擎", scan.engineHint)
                            if scan.platform != .switchEmu {
                                statBadge("XP3", "\(scan.xp3Count)")
                            }
                            statBadge(scan.platform == .switchEmu ? "ROM" : "候选", "\(scan.exeCandidates.count)")
                        }

                        ForEach(Array(scan.exeCandidates.prefix(5))) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }
            }

            card {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("路径", subtitle: nil)
                    if store.selectedGame?.platform == .switchEmu {
                        pathRow(title: "游戏 ROM", value: store.selectedGame?.romPath ?? "") {
                            Button("选择") { store.chooseSwitchROM() }
                                .controlSize(.small)
                        }
                        pathRow(title: "模拟器", value: store.selectedGame?.emulatorAppPath ?? "") {
                            Button("选择") { store.chooseEmulatorApp() }
                                .controlSize(.small)
                        }
                        if let script = store.selectedGame?.launchScriptPath, !script.isEmpty {
                            pathRow(title: "启动脚本", value: script) {
                                Text("优先")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        pathRow(title: "推荐 EXE", value: store.selectedGame?.exePath ?? "") {
                            Button("选择") { store.chooseEXEManually() }
                                .controlSize(.small)
                        }
                        pathRow(title: "Wine Prefix", value: store.selectedGame?.prefixDir ?? "") {
                            Button("选择") { store.choosePrefixFolder() }
                                .controlSize(.small)
                        }
                        pathRow(title: "Wine C 盘", value: store.selectedGameWineDriveStatus) {
                            Button {
                                store.copySelectedGameToWineDrive()
                            } label: {
                                Label("复制到 C 盘", systemImage: "internaldrive")
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                            .controlSize(.small)
                            .disabled(!store.canCopySelectedGameToWineDrive)
                            .help("复制为 Prefix 内的真实目录，减少 Z: 路径和符号链接问题")
                        }
                    }

                    Button {
                        store.saveCurrentFromP1()
                    } label: {
                        Label("保存到游戏列表", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func candidateRow(_ candidate: ScanCandidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.exeURL.lastPathComponent)
                    .font(.body.weight(.medium))
                Text(candidate.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(candidate.exeURL.path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text("\(candidate.score)")
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
            Button("选用") { store.applyRecommendedCandidate(candidate) }
                .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func antiCheatBanner(_ hits: [AntiCheatHit]) -> some View {
        let blocking = hits.contains { $0.severity == .blocking }
        let accent: Color = blocking ? .red : .orange
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(accent)
                Text(blocking ? "检测到内核级反作弊 · macOS 无法运行" : "检测到反作弊 · macOS 上几乎无法运行")
                    .font(.headline)
                Spacer()
            }

            ForEach(hits) { hit in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(hit.name)
                            .font(.callout.weight(.semibold))
                        Text(hit.severity.headline)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill((hit.severity == .blocking ? Color.red : Color.orange).opacity(0.18)))
                            .foregroundStyle(hit.severity == .blocking ? Color.red : Color.orange)
                    }
                    Text(hit.advice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !hit.evidence.isEmpty {
                        Text("特征文件：" + hit.evidence.joined(separator: "、"))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(accent.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accent.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: P2 运行环境内容

    private var runtimeContent: some View {
        Group {
            if store.selectedGame?.platform == .switchEmu {
                switchRuntimeContent
            } else {
                windowsRuntimeContent
            }
        }
    }

    private var windowsRuntimeContent: some View {
        VStack(spacing: 18) {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        sectionTitle("运行环境检测", subtitle: "检测内置 Wine / Rosetta / XQuartz / Gatekeeper。通常只需一次。")
                        Spacer()
                        Button {
                            store.refreshRuntimeStatus(userInitiated: true)
                        } label: {
                            Label("重新检测", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                    }

                    ForEach(store.runtimeReport.items) { item in
                        runtimeRow(item)
                    }
                }
            }

            card {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("修复与设置", subtitle: nil)
                    HStack(spacing: 10) {
                        Button {
                            store.installEmbeddedXQuartz()
                        } label: {
                            Label("安装内置 XQuartz", systemImage: "arrow.down.app")
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)

                        Button {
                            store.openPrivacySettings()
                        } label: {
                            Label("隐私与安全性", systemImage: "lock.shield")
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)

                        Button {
                            store.openRepairGuide()
                        } label: {
                            Label("一键修复引导", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    }
                }
            }

            card {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle(
                        "中日文字体兼容",
                        subtitle: "修复 Windows 原生菜单、对话框和设置窗口中的方块字；仅修改当前游戏的 Wine Prefix。"
                    )

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: store.selectedGameHasFontCompatibilityRepair
                              ? "checkmark.circle.fill"
                              : "textformat")
                            .foregroundStyle(store.selectedGameHasFontCompatibilityRepair ? Color.green : Color.secondary)
                            .padding(.top, 2)
                        Text(store.fontCompatibilityStatusText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if store.isManagingFontCompatibility {
                            ProgressView().controlSize(.small)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            store.repairSelectedGameFonts()
                        } label: {
                            Label("检测并修复中日字体", systemImage: "character.book.closed")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(store.isManagingFontCompatibility)

                        Button(role: .destructive) {
                            store.restoreSelectedGameFonts()
                        } label: {
                            Label("撤销字体修复", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isManagingFontCompatibility || !store.selectedGameHasFontCompatibilityRepair)
                    }

                    Text("Shiori 使用当前实际 Wine 写入字体别名，不下载或分发 Microsoft 字体；已有自定义映射不会被覆盖。修复后请完全退出并重新打开游戏。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Switch 运行环境（仅 Switch 游戏时出现）

    private var switchRuntimeContent: some View {
        let game = store.selectedGame
        let bundled = SwitchRuntime.resolveBundledEmulator()
        let emuReady = bundled != nil
            || !((game?.emulatorAppPath.isEmpty ?? true))
            || !((game?.launchScriptPath.isEmpty ?? true))
        let emuDetail: String
        if let b = bundled {
            emuDetail = "内置模拟器：\(b.deletingPathExtension().lastPathComponent)"
        } else if let s = game?.launchScriptPath, !s.isEmpty {
            emuDetail = "复刻启动脚本：" + (s as NSString).lastPathComponent
        } else if let e = game?.emulatorAppPath, !e.isEmpty {
            emuDetail = e
        } else {
            emuDetail = "未设置 · 需你自备（任意 Switch 模拟器均可）"
        }

        return VStack(spacing: 18) {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Switch 运行环境", subtitle: "Switch 游戏不经 Wine，由原生模拟器运行；以下三项齐备才能启动。")
                    switchReadyRow(title: "模拟器", ready: emuReady, detail: emuDetail, button: "选择") {
                        store.chooseEmulatorApp()
                    }
                    switchReadyRow(title: "prod.keys", ready: store.switchKeysReady,
                                   detail: store.preferredKeysPath.isEmpty ? "未导入 · 解密游戏所需 · 需你自备" : store.preferredKeysPath,
                                   button: "导入") {
                        store.chooseSwitchKeys()
                    }
                    switchReadyRow(title: "固件 firmware", ready: store.switchFirmwareReady,
                                   detail: store.preferredFirmwarePath.isEmpty ? "未设置 · 系统服务所需 · 需你自备" : store.preferredFirmwarePath,
                                   button: "选择") {
                        store.chooseSwitchFirmware()
                    }
                }
            }

            card {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Switch 游戏说明与限制", subtitle: nil)
                    explainLine("Shiori 通过原生 Switch 模拟器运行 .nsp / .xci，不使用 Wine；能否运行与性能取决于模拟器本身。")
                    explainLine("商业 Switch 游戏经过加密，必须有 prod.keys 才能解密，多数游戏还需系统固件 firmware 才能启动。")
                    explainLine("并非所有 Switch 游戏都能在 macOS 上良好运行，请以模拟器的兼容性为准。")
                }
            }

            card {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("关于 prod.keys 与固件（需你自备）", subtitle: nil)
                    explainLine("prod.keys 是你的 Switch 主机密钥，用于解密游戏。请从你本人持有的 Switch 主机导出后，点上方「导入」选择该文件。")
                    explainLine("固件 firmware 是一组 .nca 系统文件（字体 / 系统服务等）。同样从你本人的主机导出，选择其所在文件夹。")
                    explainLine("为什么 Shiori 不提供这两样：它们是任天堂的版权文件，随 App 分发属于侵权。Shiori 只负责导入你自己合法获取的文件，绝不附带或代为下载。")
                }
            }
        }
    }

    private func switchReadyRow(title: String, ready: Bool, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(ready ? Color.green : Color.orange)
                .frame(width: 12, height: 12)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(button, action: action).controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func explainLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runtimeRow(_ item: RuntimeCheckItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color(for: item.state))
                .frame(width: 12, height: 12)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.medium))
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(item.state.label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color(for: item.state))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: Steam detail（与「我的游戏」同级的主入口）

    private var steamDetail: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Wine Steam")
                        .font(.system(size: 28, weight: .bold))
                    Text("直接打开 Wine 版 Steam 客户端，不依赖当前游戏配置。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.launchWineSteamEntry()
                } label: {
                    Label(
                        localized(store.isWineSteamRunning ? "唤起 Steam 窗口" : "启动 Steam 客户端"),
                        systemImage: store.isWineSteamRunning ? "macwindow.on.rectangle" : "play.fill"
                    )
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(store.isWineSteamRunning ? .blue : .green)
                .controlSize(.large)
                .help(store.isWineSteamRunning
                      ? "Wine Steam 已在运行。Shiori 会在点击 Wine 程序坞图标时尝试唤起主窗口；如未生效，可用这里手动唤起。"
                      : "启动 Wine Steam 客户端")
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    card {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionTitle("客户端管理", subtitle: nil)
                            HStack(spacing: 10) {
                                Button {
                                    store.downloadAndOpenWineSteamInstaller()
                                } label: {
                                    Label("下载 Wine Steam", systemImage: "arrow.down.circle")
                                }
                                .buttonStyle(.bordered)
                                .tint(.blue)
                                .disabled(store.isDownloadingInstaller)

                                if store.isDownloadingInstaller {
                                    ProgressView().controlSize(.small)
                                }

                                Spacer()

                                Button(role: .destructive) {
                                    store.stopWineSteamProcesses()
                                } label: {
                                    Label("结束进程", systemImage: "power")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .controlSize(.small)
                            }

                            if !store.downloadStatusText.isEmpty {
                                Text(store.downloadStatusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Divider()

                            Label {
                                Text("Wine Steam 会在程序坞占两个图标（Steam 本体 + 内置浏览器进程），这是 Wine 的 macOS 驱动给每个有窗口的进程各建一个图标造成的。关掉 Steam 主窗口后，点击当前客户端的任一 Wine 图标时 Shiori 会尝试让 Steam 重建窗口；如果 macOS 没有产生新的激活事件，仍可使用上方的「唤起 Steam 窗口」。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    card {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top) {
                                sectionTitle("Wine Steam 游戏", subtitle: store.wineSteamLibraryPath)
                                Spacer()
                                Button {
                                    store.refreshSteamLibraries(userInitiated: true)
                                } label: {
                                    Label("刷新", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            if store.wineSteamGames.isEmpty {
                                emptySteamState("尚未发现 Wine Steam 本地游戏")
                            } else {
                                ForEach(store.wineSteamGames) { game in
                                    wineSteamGameRow(game)
                                }
                            }
                        }
                    }

                    card {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top) {
                                sectionTitle("从 Mac Steam 导入", subtitle: store.steamLibraryStatusText)
                                Spacer()
                                if store.isSteamPrefillImporting {
                                    ProgressView().controlSize(.small)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                explainLine("可导入的是本地资源/数据文件，例如 Unity Data、Ren'Py game/www、pak、assets、resource、音频、图片等。")
                                explainLine("不会导入 Mac 专用内容：.app、.dylib、.framework、Info.plist、Mac Steam appmanifest。")
                                explainLine("导入后仍需点“安装/验证”；Shiori 会写入 Wine 待验证 manifest 和 staging 目录，Steam 只复用通过 Windows manifest 校验的文件。")
                            }

                            if store.macSteamGames.isEmpty {
                                emptySteamState("未发现 Mac Steam 已安装游戏")
                            } else {
                                ForEach(store.macSteamGames) { game in
                                    macSteamGameRow(game)
                                }
                            }
                        }
                    }

                    card {
                        VStack(alignment: .leading, spacing: 10) {
                            sectionTitle("运行环境", subtitle: "Steam 在部分 Wine 场景需要 XQuartz；如遇黑屏 / 无法显示窗口可安装。")
                            HStack(spacing: 10) {
                                Button {
                                    store.installEmbeddedXQuartz()
                                } label: {
                                    Label("安装内置 XQuartz", systemImage: "arrow.down.app")
                                }
                                .buttonStyle(.bordered)
                                .tint(.blue)

                                Button {
                                    store.openPrivacySettings()
                                } label: {
                                    Label("隐私与安全性", systemImage: "lock.shield")
                                }
                                .buttonStyle(.bordered)
                                .tint(.orange)
                            }
                        }
                    }

                    card {
                        VStack(alignment: .leading, spacing: 10) {
                            sectionTitle("说明", subtitle: nil)
                            ForEach(Array(store.wineSteamTips.enumerated()), id: \.offset) { _, tip in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "info.circle")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                        .padding(.top, 2)
                                    Text(tip)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            statusBar
        }
    }

    private func macSteamGameRow(_ game: SteamLibraryGame) -> some View {
        let installStatus = store.wineSteamInstallStatus(for: game)
        let wineEntry = store.wineSteamGames.first { $0.appID == game.appID && $0.hasManifest }
        let readyInWine = wineEntry.map { store.isWineSteamGameReadyToLaunch($0) } ?? false
        let pendingValidation = installStatus?.prefillMetadata != nil && !readyInWine
        let prefilledInWine = pendingValidation || store.isMacSteamGamePrefilledInWine(game)
        let hasWineSideEntry = wineEntry != nil || prefilledInWine || installStatus != nil
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.blue)
                .frame(width: 18)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(game.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    steamPill(game.sizeLabel, color: .secondary)
                    if readyInWine {
                        steamPill("Wine 已安装", color: .green)
                    } else if pendingValidation {
                        steamPill("待验证", color: .orange)
                    } else if prefilledInWine {
                        steamPill("已预填充", color: .orange)
                    }
                }
                Text("AppID \(game.appID) · \(game.installDir)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(game.installPath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let installStatus {
                    steamInstallStatusBlock(installStatus, game: game)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                if prefilledInWine && !readyInWine {
                    Button {
                        store.launchWineSteamInstall(for: game)
                    } label: {
                        Label("安装/验证", systemImage: "checkmark.arrow.trianglehead.counterclockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                    .help("打开 Wine Steam 安装入口；Steam 只复用校验通过的文件，其余仍会下载")
                } else if !readyInWine {
                    Button {
                        store.prefillMacSteamGameToWine(game)
                    } label: {
                        Label("预填充", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                    .controlSize(.small)
                    .disabled(!store.canPrefillMacSteamGame(game))
                    .help("离线复制可能复用的资源/数据文件；跳过 Mac 专用文件和 appmanifest")
                }

                if hasWineSideEntry {
                    Button(role: .destructive) {
                        pendingMacSteamReimport = game
                    } label: {
                        Label("重新预填充", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .disabled(!store.canResetWineSteamGameAndPrefill(game))
                    .help("先删除 Wine Steam 侧该游戏文件，再从 Mac Steam 本地重新预填充")
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func wineSteamGameRow(_ game: SteamLibraryGame) -> some View {
        let installStatus = store.wineSteamInstallStatus(for: game)
        let readyToLaunch = store.isWineSteamGameReadyToLaunch(game)
        let isLaunching = store.isLaunchingWineSteamGame(game)
        return HStack(alignment: .top, spacing: 12) {
            SteamGameIconView(game: game, size: 48, height: 66, cornerRadius: 10)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(game.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    steamPill(game.sourceLabel, color: game.isPreloadOnly ? .orange : .green)
                    steamPill(game.sizeLabel, color: .secondary)
                }
                Text(game.appID.isEmpty ? game.installDir : "AppID \(game.appID) · \(game.installDir)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(game.installPath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let installStatus {
                    steamInstallStatusBlock(installStatus, game: game)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    store.launchWineSteamGame(game)
                } label: {
                    Label(
                        localized(isLaunching ? "启动中…" : (readyToLaunch ? "启动" : "安装/验证")),
                        systemImage: isLaunching ? "hourglass" : (readyToLaunch ? "play.fill" : "checkmark.arrow.trianglehead.counterclockwise")
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(readyToLaunch ? .green : .orange)
                .controlSize(.small)
                .disabled(isLaunching)
                .help(readyToLaunch ? "通过 Wine Steam 启动该游戏" : "打开 Wine Steam 安装/验证，只复用校验通过的文件")

                HStack(spacing: 8) {
                    Button {
                        store.openWineSteamGameFolder(game)
                    } label: {
                        Label("目录", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        pendingWineSteamDelete = game
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func steamInstallStatusBlock(_ status: SteamInstallStatus, game: SteamLibraryGame) -> some View {
        // 预填充黄字提示：仅在“未（安装完成且成功运行过）”时显示；装好并运行过后隐藏。
        let hasRun = store.wineSteamGameHasRun(game.appID)
        let showEvidence = status.prefillEvidenceLabel != nil && !(status.isLaunchReady && hasRun)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(status.detailLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let progress = status.progressFraction {
                ProgressView(value: progress)
                    .controlSize(.small)
                    .frame(maxWidth: 340)
            }
            if showEvidence, let evidence = status.prefillEvidenceLabel {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text(evidence)
                        .font(.caption2)
                        .lineLimit(3)
                }
                .foregroundStyle(status.prefillEvidenceNeedsAttention ? Color.orange : Color.yellow)
            }
        }
        .padding(.top, 2)
    }

    private func emptySteamState(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .foregroundStyle(.secondary)
            Text(localized(text))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func steamPill(_ text: String, color: Color) -> some View {
        Text(localized(text))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    // MARK: Status bar（补上此前从未显示的 statusMessage）

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(localized(store.statusMessage))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Reusable building blocks

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }

    private func sectionTitle(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(localized(title))
                .font(.title3.weight(.semibold))
            if let subtitle {
                Text(localized(subtitle))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized(title))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func enginePill(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(.tint)
    }

    /// 平台徽标：用图标区分 Windows（电脑）/ Switch（手柄），hover 显示平台名。Switch 用绿色避免红色像报错。
    private func platformBadge(_ platform: GamePlatform) -> some View {
        let symbol = platform == .switchEmu ? "gamecontroller.fill" : "desktopcomputer"
        let color: Color = platform == .switchEmu ? .green : .blue
        return Image(systemName: symbol)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
            .help(platform.title)
    }

    private func statBadge(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func pathRow<Trailing: View>(title: String, value: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value.isEmpty ? "尚未设置" : value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func color(for state: RuntimeCheckItem.State) -> Color {
        switch state {
        case .ok: return .green
        case .bundled: return .blue
        case .warning: return .yellow
        case .missing: return .orange
        case .blocked: return .red
        }
    }

    private func exeDisplay(_ game: GameEntry?) -> String {
        guard let game, !game.exePath.isEmpty else { return "尚未选择主程序" }
        return game.exePath
    }

    /// 主文件显示：Windows 用 EXE，Switch 用 ROM（与“Wine 打开 exe”同构）。
    private func mainFileDisplay(_ game: GameEntry?) -> String {
        guard let game else { return "尚未选择" }
        switch game.platform {
        case .windows:
            return game.exePath.isEmpty ? "尚未选择主程序" : game.exePath
        case .switchEmu:
            if !game.romPath.isEmpty { return game.romPath }
            if !game.launchScriptPath.isEmpty { return (game.launchScriptPath as NSString).lastPathComponent }
            return "尚未选择 ROM"
        }
    }

    private func isConfigured(_ game: GameEntry) -> Bool {
        switch game.platform {
        case .windows: return !game.exePath.isEmpty
        case .switchEmu: return !game.romPath.isEmpty || !game.launchScriptPath.isEmpty
        }
    }

    // MARK: Bindings & selection sync

    private var wineSteamDeleteBinding: Binding<Bool> {
        Binding(
            get: { pendingWineSteamDelete != nil },
            set: { isPresented in
                if !isPresented {
                    pendingWineSteamDelete = nil
                }
            }
        )
    }

    private var macSteamReimportBinding: Binding<Bool> {
        Binding(
            get: { pendingMacSteamReimport != nil },
            set: { isPresented in
                if !isPresented {
                    pendingMacSteamReimport = nil
                }
            }
        )
    }

    private var sidebarBinding: Binding<SidebarItem?> {
        Binding(
            get: { sidebarSelection },
            set: { newValue in
                sidebarSelection = newValue
                if case .game(let id) = newValue {
                    store.selectGame(id)
                }
            }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { store.selectedGame?.name ?? "" },
            set: { store.renameSelectedGame($0) }
        )
    }

    private var launchLanguageBinding: Binding<LaunchLanguageMode> {
        Binding(
            get: { store.selectedGame?.launchLanguageMode ?? .auto },
            set: { store.setSelectedLaunchLanguage($0) }
        )
    }

    private func syncInitialSelection() {
        if sidebarSelection == nil {
            sidebarSelection = .home
        }
    }

    /// 打开某个游戏配置（从主页卡片或侧栏进入其详情）。
    private func openGame(_ id: UUID) {
        sidebarSelection = .game(id)
        gameSection = .setup
        store.selectGame(id)
    }

    /// 主页 Wine Steam 模块的客户端入口：先切到管理页，再启动/唤起客户端。
    private func openAndLaunchWineSteam() {
        sidebarSelection = .steam
        store.launchWineSteamEntry()
    }

    /// 新建配置并直接进入其详情。
    private func createAndOpenGame() {
        store.addEmptyGame()
        if let id = store.selectedGameID {
            sidebarSelection = .game(id)
            gameSection = .setup
        }
    }
}
