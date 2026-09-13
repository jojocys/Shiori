# Shiori 统一 DMG 应用内更新：Agent 实施指导

日期：2026-09-13。状态：`v0.2.1/build 3`、Pages feed 和统一 DMG 已上线并通过公网校验；本机 `v0.2.0/build 2` 更新测试基线已就绪，等待维护者完成最后一次真实点击升级。与同目录《Shiori-DMG更新-简要方案.md》配套。

## 1. 目标、授权与完成定义

用户已确认：统一 DMG；Sparkle 2；GitHub Releases 托管包、GitHub Pages 托管清单；目前没有 Apple Developer Program 付费账号或 Developer ID 证书；自动检查并提示，用户主动安装，相关游戏运行时暂缓替换。

本轮已按实施指令完成代码与发布脚本改动，并由 Sol 完成本地静态验收；提交、推送、Release 发布和 Pages 部署仍须在最终重建后由维护者执行。不要反复确认已经确定的 DMG、框架或账号选择。

验收核心：带更新能力的真实旧版 A，使用内置按钮，从 GitHub 下载最终 DMG B，验证、替换并重启 B，用户配置和样例存档可用，全程无需浏览器或 Finder 安装操作。必须区分“本地检查通过”“测试更新源通过”“生产公网验证通过”。

## 2. 实施前基线

仓库在 `/Users/gaoxiaoli/Desktop/gal for MacOS/gal-for-MacOS`，远端为 `https://github.com/jojocys/Shiori.git`。下文路径相对仓库根目录。不要假设远端旧名称 `gal-for-MacOS` 可永久重定向。

| 文件或位置 | 本轮已观察到的状态 |
| --- | --- |
| `Shiori/Package.swift`、`Package.resolved` | SwiftPM 原生 SwiftUI App，macOS 13 起；Sparkle 依赖下限 2.9.4，本地解析到 2.9.6 |
| `Shiori/Sources/ShioriUpdater.swift` | 包装 `SPUStandardUpdaterController`，两个 delegate 均为 nil |
| `Shiori/Sources/ShioriApp.swift`、`RootView.swift` | App 菜单和标题栏共用 Sparkle 检查入口；标题栏按钮悬停展开；支持中英文切换 |
| `Shiori/scripts/build_release_app.sh` | 嵌入 Sparkle、Wine、XQuartz 安装包；默认 ad-hoc 签名；记录并复核外部构建输入 |
| `Shiori/scripts/make_dmg.sh` | 生成版本化 DMG，内含 `Shiori.app` 和 `/Applications` 快捷链接 |
| `Shiori/scripts/release.py` / `release.sh` | 提供 `prepare`、`publish`、`verify-online` 及 DMG/feed/验证命令；publish 不自动提交、推送或部署 Pages |
| `Shiori/scripts/verify_update_setup.sh` | 多处硬编码 ZIP；取 XML 第一个版本；仅检查签名字符串非空，未独立验证签名 |
| `Shiori/config/sparkle_public_key.txt` | 已有公钥；私钥是否存在、是否可用于该公钥，本轮没有访问或验证 |
| `docs/appcast.xml` | 生产 feed 已部署并指向 `v0.2.1/build 3` 的统一 DMG |
| `.github/workflows/pages.yml` | main 上 `docs/**` 改动会触发部署，整个 docs 目录被发布 |
| `Shiori/version.json` | 当前生产版本 `0.2.1/build 3`；实际二进制 arm64，ad-hoc 签名 |
| `Shiori/Sources/AppStore.swift` | 用户数据以 `~/.shiori/` 为根；已有部分 Steam 进程检测代码 |

工作区包含大量既有未提交修改和未跟踪文件。先读适用的 AGENTS.md、查看状态及差异，不清理、不重置、不覆盖无关改动，不把所有现有变更都记为本任务成果。记录准备交付的源码状态与构建关联。

发布前确认的基线是 GitHub 正式最新版 `v0.2.0`，没有生产 feed；本轮因此以首次 feed 模式发布 `v0.2.1/build 3`。后续发布必须读取现有生产 feed 并保留历史条目，不再设置 `SHIORI_FIRST_FEED=1`。

本方案放在 `plans/`，避免因现有 Pages 流程将内部实施文档一起部署。

## 3. 固定架构与产品行为

```text
维护者构建 App → 制作最终 DMG → Ed25519 签署 DMG → 生成并校验 appcast
                      ↓
             GitHub Release 上传 DMG
                      ↓ 验证匿名下载及字节一致
             GitHub Pages 部署 appcast
                      ↓
Shiori 检查清单 → 显示说明 → 用户安装 → 下载同一 DMG → 校验 → 替换 → 重启
```

生产 feed 保持 `https://jojocys.github.io/Shiori/appcast.xml`；生产资产形如 `https://github.com/jojocys/Shiori/releases/download/v<version>/Shiori-<version>.dmg`。必须实际可匿名下载，客户端不能内嵌 GitHub token。

每个新版本对外提供一个完整安装包 DMG，可附 `.dmg.sha256.txt`；GitHub 自动提供的源码 ZIP/TAR 不属于安装包，在 Release 说明中明确主下载项。第一阶段不生成或推广 `.app.zip` 和 `.delta`，不删除历史已发布资产。

采用 Sparkle 原生标准界面，应用内展示版本说明、下载进度、最新版状态和失败信息。正常更新不能调用 `NSWorkspace.open(releasesURL)` 代替安装，也不能生成仅跳网页的 informational update。手动下载只能作为显式的故障备用入口。

初版保留 macOS 13+、Apple Silicon 的已验证范围，不因为 Sparkle framework 是 universal 就宣称主程序支持 Intel。不增加运行库拆分、后台常驻进程、独立安装器、自定义下载器或全新发布平台。

## 4. 应用侧实施

### 4.1 生命周期及配置

继续使用应用级长期存活的更新控制器；确认 SwiftUI 视图或 App 重建不会启动多个 updater，delegate 生命周期可靠。App 菜单和标题栏共享实例，结合 `canCheckForUpdates` 验证启用状态，避免重复点击触发并行流程。开发态 `swift run` 没有完整 bundle 时，应明确更新不可用，不能因 updater 初始化破坏正常开发运行。

保持 bundle 名 `Shiori.app`、bundle ID `com.jojocys.shiori` 及固定公钥。生产打包属性至少包括：

| 属性 | 本阶段值 |
| --- | --- |
| `SUFeedURL` | 固定生产 HTTPS 地址 |
| `SUPublicEDKey` | 已确认对应私钥的固定公钥 |
| `SUEnableAutomaticChecks` | true |
| `SUScheduledCheckInterval` | 86400 |
| `SUAutomaticallyUpdate` | false |
| `SUAllowsAutomaticUpdates` | false，禁止标准界面引导用户开启静默安装 |
| `SUVerifyUpdateBeforeExtraction` | true |
| `SURequireSignedFeed` | 本阶段不新增强制要求；HTTPS + DMG 签名为交付基线 |

`SUAutomaticallyUpdate=false` 只是默认值，不能单独当成“永不静默安装”的保证；验证既有偏好和 `SUAllowsAutomaticUpdates` 的实际交互。用户仍可在 App 内主动下载、安装，禁止自动安装并不意味着要求用户手动拖拽。[配置说明](https://sparkle-project.org/documentation/customization/)

### 4.2 游戏运行与安装协调

提取可测试的只读运行状态探测和安装准入逻辑，尽量复用现有能力。考虑 Shiori 启动的普通 Wine 游戏、Wine Steam 主进程及相关子进程、从 App 内运行的可选模拟器，以及占用当前 App 内运行库的进程。区分外部独立运行库，避免拦截不相关应用。

不能只检查最初 `Process` 的存活，也不能把所有名称包含 wine 的进程视为本应用游戏。结合启动记录、可执行路径、规范化路径边界、Prefix 及现有文件占用检测。`pgrep`/`lsof` 必须在后台执行并有超时；无匹配和工具出错须区分，探测失败不能等同于安全。路径含空格和中文必须支持。

允许检查版本；安装前必须重新探测，防止下载期间新启动游戏。发现相关运行活动时显示“请先保存并退出相关游戏或 Wine Steam，再继续更新”，列出可识别的项目。用户退出后重新检测并主动继续，不强制终止游戏，不调用现有清理代码里的 TERM/KILL 来完成升级。安装准备已开始时协调新的启动请求，防止检测通过后又启动内置 Wine。

**关键 API 边界：** 本轮核对 Sparkle 2.9.6 本地 `SPUUpdaterDelegate.h`，`shouldPostponeRelaunchForUpdate:untilInvokingBlock:` 并非所有退出路径都会调用；`willInstallUpdate:` 是通知，无返回值；`willInstallUpdateOnQuit:immediateInstallationBlock:` 无论返回什么，已安排的更新仍可能在 App 退出时安装。不能把任一回调误当成通用取消安装 API。

实现时以实际 SDK 导入签名和源码为准，结合 Sparkle delegate 与 AppKit 终止协调，覆盖安装并重启、用户普通退出、延迟安装后再退出。延迟期间的继续回调必须管理清楚，防重复执行及生命周期泄漏。如果标准界面无法安全保留下载后等待，应采用保守的提前阻止更新安装流程、待游戏退出后重试；不要为了“先下载”绕过安装保护。交付说明需如实写出最终行为与测试范围。[delegate 参考](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)

### 4.3 数据与故障

更新仅替换 App bundle，不删除或迁移 `~/.shiori/`、外部游戏目录、用户自定义 Prefix、Steam 库和系统 XQuartz/Rosetta。保存尚未落盘的应用配置后才允许退出。此次不要同时引入数据格式迁移，避免增加恢复风险。

网络/HTTP 失败、无新版本、签名失败、权限拒绝、空间不足及只读 DMG 中运行须有准确反馈；失败不能自动打开 GitHub或声称“已是最新版”。替换和授权交给 Sparkle；禁止自写先 `rm -rf` 旧 App 再复制的更新脚本，禁止把关闭 Gatekeeper 或删除 quarantine 作为更新成功前置步骤。

## 5. 构建与签名改造

### 5.1 构建 App

已修改 `build_release_app.sh`：保留完整 App 构建和资源装配，记录并复核外部 Wine/XQuartz/模拟器输入；DMG 是本阶段唯一完整发布包。不删除已有 ZIP 产物。

复用已解析的 Sparkle 并记录版本；实施时检查官方兼容性和安全修复后决定是否需要升级，不进行无目的依赖升级。保留符号链接、可执行权限和 framework rpath。核对 Sparkle helper/XPC、Wine、可选模拟器等嵌套代码的签名，以由内到外的明确顺序装配和签署。

现有脚本对部分内嵌签名使用 `|| true`，且广泛依赖 `codesign --deep`；必须逐项审查，任何影响实际可运行性或验证的失败都应阻断发布。`codesign --verify --deep --strict` 是完整性检查，不等于 Developer ID、公证或 Gatekeeper 放行。保持 ad-hoc 路线，不盲目加入 hardened runtime/library validation，避免破坏 Wine 或 Sparkle 加载。

### 5.2 制作最终 DMG

继续由 `make_dmg.sh` 生成只读、无密码的 `Shiori-<version>.dmg`。顶层只有主 App、Applications 链接及必要安装说明，不增加第二个候选主 App 或 PKG 安装流程。XQuartz.pkg 仍是 App 资源，不代表更新时执行它。

从打包 App 的 Info.plist 读取版本并与 manifest 校验；处理缺失版本、空间不足、临时目录清理、挂载失败及退出时卸载。保留当前已验证的 DMG 格式优先，压缩优化可另评估。

顺序为：完成所有 bundle 改动和 ad-hoc 签名 → 制作 DMG → 验证挂载后 App → 对最终 DMG 生成 SHA-256 和 Ed25519 签名 → 冻结字节。之后不得重制或编辑 DMG；任何字节变化均须重新签署、生成清单并重新验证。

### 5.3 密钥

优先沿用 `SPARKLE_ACCOUNT=shiori-jojocys` 对应的已有钥匙串密钥。只核对公钥以及是否能够签署并验证，不把私钥打印到终端、聊天、日志或命令行参数。不要在没有调查既有分发状态时自动重新生成密钥。

如私钥不存在或不匹配：停止依赖该密钥的签署，报告原因；若任何用户已安装该公钥的 App，直接换钥会切断更新链。只有确认尚未分发或制定过渡安排后才能更换。首次交付要求维护者将私钥保存在安全备份中，本轮文档任务没有读取任何私钥。

Apple 付费账号不作为本阶段阻塞条件；但不承诺系统零提示。今后引入 Developer ID 和公证需作为单独改造验证，不能假设只改一个环境变量即可适配所有内置组件。

## 6. 更新清单及本地验证

已修改 `generate_appcast.sh`，并由 `release.py feed` 统一调用：

- 输入为最终 `Shiori-<version>.dmg`，说明文件按工具约定改为 `Shiori-<version>.md`，说明在 App 内嵌显示。
- 使用独立 DMG staging 目录，禁止直接扫描混有旧 ZIP、测试构建和 delta 的 `dist/updates`。
- 本轮本地工具帮助已确认 `--maximum-deltas`、`--versions`、`--embed-release-notes`；使用 `--maximum-deltas 0`，仍需检查最终 XML 没有遗留 delta 条目。
- 输出先写待发布 staging，不直接覆盖会触发 Pages 的 `docs/appcast.xml`。只有正式资产验收后才提升为生产清单。
- 清单必须有真实 DMG enclosure、有效签名和字节长度；build 严格递增，系统/架构限制来自真实 bundle。
- 若保留历史版本，应保留每条原始 Release URL，不能用本次 `v<version>/` 前缀重写所有旧资产链接。使用生成工具、结构化 XML 处理和逐项校验，避免正则替换。
- 初次迁移先调查旧 feed 是否已公开。如果旧 ZIP 更新已对外生效，保留必要历史兼容条目与资产；仅新版本统一 DMG。不能擅自删除历史更新路径。

已修改 `verify_update_setup.sh`：允许显式传入 App、DMG、staged appcast、预期版本及 feed，测试环境不硬编码生产 feed；按目标 build 选中唯一 item，不能取第一个节点。

本地发布门禁至少覆盖：

| 检查 | 必须确认 |
| --- | --- |
| 元数据 | bundle ID/name、显示版本/build、macOS/CPU、feed、公钥一致 |
| App | Sparkle 链接和 rpath、helper 存在、嵌套代码及外层签名验证 |
| DMG | 可只读挂载、主 App 唯一、Applications 链接正确、挂载内 App 验证与元数据一致 |
| 清单 | XML 合法；目标 build 唯一；版本化 DMG HTTPS URL、文件长度正确；无新 ZIP/delta 条目 |
| 加密验证 | 使用客户端内嵌公钥，对最终 DMG 的实际字节与清单签名独立验证；损坏包及错误公钥必须失败 |
| 版本选择 | 更新更高 build；同 build/较低 build 不提示升级；不投递不兼容架构/系统版本 |
| 发布材料 | 唯一 DMG、便于下载的说明、相对文件名的校验清单，不泄露本机路径或私钥 |

`sign_update --verify` 可用于辅助核对，本轮工具帮助说明它默认从钥匙串读取密钥，不能把“用发布机自己的密钥验证”替代“与 App 内嵌公钥一致”的验证。实现可用 Swift CryptoKit 的 Ed25519 公钥验证，按实际公钥、签名编码与原始文件字节执行，并设损坏负例；不得仅检查签名字符串非空或使用 SHA-256 冒充来源验证。

## 7. 发布流程与线上门禁

统一发布脚本已实现 `prepare`、`publish`、`verify-online` 三个阶段。首阶段在维护者 Mac 构建并签署，GitHub Actions 负责 Pages 的受控部署。`publish` 会把验证后的 feed 写入本地 `docs/appcast.xml`，但不会自动提交、推送或部署 Pages。

实际命令（均在 `Shiori/` 目录执行）：

```bash
# 默认流程：已有历史生产 feed 时不设置 SHIORI_FIRST_FEED
RELEASE_OUTPUT="$PWD/dist/release-ready-20260912"  # 若目录已存在，改用新的隔离目录
STAGE="$RELEASE_OUTPUT/releases/0.2.1" # 示例；每次替换为本次版本
BUILD="3"                                              # 替换为本次实际 build
DIST_DIR="$RELEASE_OUTPUT" SHIORI_FIRST_FEED=1 ./scripts/release.sh prepare

# 复核 "$STAGE/release.json" 后，上传并验证 Release 资产
./scripts/release.sh publish "$STAGE"

# publish 只更新本地 docs/appcast.xml；人工复核后提交并推送，等待 Pages workflow 成功
# Pages 部署成功后，以公网地址验证 feed、目标 build、DMG 长度和签名
./scripts/release.sh verify-online "$STAGE/appcast.xml" --public-feed --build "$BUILD"
```

首次 feed 模式单独执行：仅在确认生产 feed 尚不存在时，将上面的 `prepare` 替换为：

```bash
SHIORI_FIRST_FEED=1 ./scripts/release.sh prepare
```

`prepare` 会构建 App、制作 DMG、生成 staged appcast 并冻结来源/资产摘要；`publish` 会校验来源提交、Release tag/资产集合、匿名下载和生产 feed 防降级。publish 成功后仍需人工提交并推送 `docs/appcast.xml`，等待 Pages workflow 完成后再做公网验证。示例中的 `STAGE` 和 `BUILD` 必须替换为本次实际 staging 路径与 build；示例已使用 shell 变量，不能把尖括号占位符直接复制到命令行。

1. 重新确认实际已分发版本和 build；为新版本分配未使用且严格递增的 build。当前生产基线为 `0.2.1/build 3`；测试版本号不得污染生产版本序列。
2. 本地完成源码检查、必要测试、构建、DMG、签名和 staged feed；记录 commit/工作区状态、依赖、版本、DMG hash、验证结果。
3. 在已有发布授权下，创建或使用对应草稿 Release，上传精确命名的 DMG 和校验文件。发生名称冲突先核对，已发布同名资产字节不一致时应使用新版本，不能静默覆盖。
4. 发布 Release 后，从匿名客户端地址跟随 HTTPS 重定向实际下载 DMG，校验完整文件 hash/签名。HEAD 或看到资产列表只能辅助，不能替代真实文件验证。草稿资产不能被普通用户下载，不能提前写入生产 feed。
5. 所有资产验证通过后，将 staged feed 提升为 `docs/appcast.xml` 并部署 Pages。给现有 workflow 增加 XML/目标资产可达性及必要一致性门禁，失败不部署；保证只有部署内容准备就绪的清单进入生产。
6. 等待实际部署成功，匿名 GET 固定 feed URL，检查返回 XML 而非 HTML/404、版本和链接正确；缓存可能延迟，验证未完成时不得宣布上线。并发发布串行化，旧任务重试不得覆盖新版 feed。
7. 用已安装版本 A 完成一次生产 URL 的更新到 B，再次检查不重复提示升级。

生产发布中途失败时：已上传 DMG 但 feed 未更新，可以修复后继续；feed 校验失败保持原清单；Release 已公开但尚未进入更新清单，应明确状态。记录每阶段结果，重试时复核现有资产并复用，避免重复或降级部署。

GitHub Release 单文件需小于 2 GiB，目前候选 DMG 为 484558775 bytes（约 462.1 MiB），符合该限制；完整下载速度需实测，不作国内网络速度保证。[GitHub 说明](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)

## 8. 过渡与恢复

首次支持更新的版本称为“过渡版 A”，下一次正常版本称为 B，具体编号实施前确认。没有 Sparkle 的旧版只能通过一次手动替换进入 A。已有旧 `version.json` 检查路径继续保持兼容，指向正确下载位置并解释迁移步骤；检查仓库改名对旧 URL 的影响，不删除旧 manifest 字段。

迁移说明：保存游戏并退出相关程序 → 下载新 DMG → 将 App 拖入应用程序并选择替换 → 必要时按系统提示允许启动 → 后续使用内置更新。不要要求用户删除 `~/.shiori/` 或先卸载运行环境。

发现坏版本后，先撤回或修正更新清单，停止继续投递。清单撤回不会让已升级用户自动降级，也不能保证取消已下载的更新。向已升级用户发布更高 build 的修复版本；保留旧 DMG 供维护者指导手动恢复。若需修复 App 数据，应另行设计，不能假定换回 App 就回退数据。本阶段不承诺全系统断电恢复或自动健康回滚。

## 9. 测试矩阵和交付证据

只为实际新增的发布验证、版本选择与安装准入决策增加有意义的测试；运行现有 Swift 测试，记录已有失败和新增失败。不要因为文案或文件名改动堆积机械测试。

在可丢弃的测试用户、测试副本或虚拟机进行破坏性场景，不覆盖维护者日常 App、Prefix 或存档。测试 A/B 必须在打包前写入版本与 feed，然后签署；不能修改已签 App 的 Info.plist 伪造旧版。

| 场景 | 验收结果 |
| --- | --- |
| A → B 正常升级 | 同一公开 DMG；无浏览器/Finder；替换正确路径；B 重启成功 |
| B 再查更新、较低 build | 不重复升级，不降级 |
| 数据保留 | 测试配置、用户自定义路径、样例存档升级前后校验；Wine/Steam/可选模拟器核心启动冒烟 |
| 无网络、feed 404/HTML、DMG 404、下载中断 | 可理解的失败和重试；旧 App 能继续运行，无提前删除 |
| 包损坏、错误签名/公钥、错误长度 | 明确拒绝；不安装；旧版及数据完整 |
| 空间不足、权限拒绝 | 无半成品替换；正确提示；授权只走系统/Sparkle |
| 游戏已运行、下载期间启动游戏、子进程仍在 | 安装被暂缓；进程和游戏数据不被强制终止 |
| 暂缓后普通退出、稍后安装、重复点击继续 | 不绕过保护，不重复执行回调，无卡死或多实例 |
| DMG 中直接运行、用户 Applications、系统 Applications、中文/空格路径 | 验证支持的安装位置；不能更新的位置提示先安装到可更新目录 |
| 首次安装与更新后 Gatekeeper/权限 | 按默认系统策略实测并记录；不可用移除 quarantine 或关闭系统保护掩盖失败 |
| 发布失败和重试 | 不上线空链接、不覆盖不同字节的已发布资产、不把较旧 feed 覆盖新版 |

至少验证实际支持的最低 macOS 版本和一台当前常用版本；缺少设备就标记未测，不扩大兼容承诺。恢复模拟和权限测试在隔离环境开展。

本地测试 feed 可用于先验证功能，但生产 App 和生产 feed 不得含 localhost/临时地址；公共测试需独立 feed、明确测试版本，不把高 build 测试包放进稳定清单。隔离 QA 的正常 A → B 与连续 A-observed 复测均已完成，B 再检查通过；此前 A-retest 异常最终未复现，不能把其后来来源不明的进程作为自动重启证据。测试服务超时曾真实显示 `UpdateError`，取消后可成功重试，不代表所有网络负例均通过。没有真实公网 E2E 时，交付状态必须标为“实现及本地验证完成，公网验证待完成”。

实施 agent 最终交付：相关代码和发布脚本、更新后的用户安装/迁移说明、逐项测试报告、构建与资产指纹、实际发布状态及遗留项。报告禁止重复引用本地旧文档里的测试数量作为新证据。

## 10. 建议实施顺序

1. 固化基线、分发状态、公钥连续性和实际版本编号；当前生产基线为 `0.2.1/build 3`，生产 feed 已上线。
2. 完成 DMG 构建、清单生成及验证，并用 staging 完成封闭验证。
3. 完成安装协调与更新状态，覆盖游戏及终止路径。
4. 用隔离 A/B 完成关键更新和失败测试；旧版连续重测证据由主 Agent 汇总。
5. 完成统一发布入口及 Pages 门禁、用户迁移文案；正式 Release 与 Pages 部署待最终重建后执行。
6. 取得届时必要发布授权后，按“包先、feed 后”的顺序发布并做公网验收。

不承诺仅上传 DMG 就会自动更新，不承诺没有付费账号时系统永不提示，不以代码存在代替用户真实升级成功。

## 11. 依据

- [Sparkle 接入与 DMG 支持](https://sparkle-project.org/documentation/)：框架能力、包签名及密钥连续性。
- [Sparkle 发布说明](https://sparkle-project.org/documentation/publishing/)：DMG 的签署和 appcast 发布格式。
- [Sparkle 配置](https://sparkle-project.org/documentation/customization/)：自动检查与自动安装的区别。
- [Sparkle updater delegate](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)：结合本地 2.9.6 头文件核对生命周期与安装回调。
- [Apple Developer ID](https://developer.apple.com/developer-id/)：正式签名、公证与系统信任的边界。
- [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)：安装包托管限制。

本轮使用 Sparkle 2.9.6；Python 发布测试 11 项、Swift 测试 36 项全部通过，其中 3 项覆盖空存储、手动空白配置持久化及主配置损坏后的备份恢复。最终候选从提交 `3a4a850` 重新构建，完成本地挂载、深层签名、Ed25519 验证、Release 匿名完整下载以及生产 feed 字节一致性验证；Pages workflow 部署成功。签名工具使用钥匙串中的既有密钥，未导出或显示私钥。本机 `/Applications/Shiori.app` 已准备为 `0.2.0/build 2`，保留 4 个既有配置，等待维护者点击更新完成生产 UI 验收。macOS 13/新机器、真实游戏冒烟、Gatekeeper、磁盘权限和完整异常分支仍需后续验证。
