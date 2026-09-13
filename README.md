# 栞 Shiori

**Shiori 是一个免费、轻量、面向 macOS 的 视觉文字小说 / Windows EXE / Wine Steam / Switch 等的文件启动器。**

它的目标很直接：把“在 Mac 上跑 Windows 视觉小说”这件事从一堆终端命令、Wine 路径、Prefix 配置、XQuartz、Rosetta 提示里拉出来，变成一个更接近普通 App 的三步流程：

1. 选择游戏文件夹
2. 检查运行环境
3. 点击开始游戏

Shiori 不提供游戏本体、不提供破解、不提供 ROM、不提供 `prod.keys` 或 Switch 固件。它只负责启动和管理你自己合法持有的游戏文件。

## 为什么用 Shiori

- **免费使用**：不需要 CrossOver 授权，不需要订阅，不需要为了试一个游戏先付费。
- **专为 macOS 做减法**：把 Wine、XQuartz、Rosetta、Gatekeeper 这些最容易劝退新用户的点集中到一个运行环境页。
- **面向 Galgame 的扫描逻辑**：选择整个游戏文件夹后，自动扫描 `.exe`、识别 XP3 / KiriKiri 线索，并推荐更像主程序的候选文件。
- **内置 Wine 打包方案**：正式打包时可把 Wine 放进 App 内，用户不必手动到处找 `wine64`。
- **独立 Prefix**：每个游戏可以拥有自己的 Wine Prefix，减少游戏之间运行库、字体、注册表配置互相污染。
- **日志可追踪**：每次启动都会写日志，失败时不用靠猜。
- **Wine Steam 入口**：可以单独管理 Wine 版 Steam 客户端，用来运行 Windows-only Steam 游戏。
- **Switch 模式**：Switch 游戏不走 Wine，可调用用户自备的原生模拟器，并导入用户自备的 keys / firmware。

## 适合哪些游戏

较适合：

- KiriKiri / KiriKiri2 / XP3 系视觉小说
- 老式 Windows Galgame
- 一部分 Ren'Py / Unity / RPG Maker 作品
- 部分没有强 DRM、没有内核级反作弊的 Windows Steam 游戏

不适合：

- 需要内核驱动的反作弊游戏，例如 Vanguard、GameGuard、ACE、XIGNCODE3
- 强 DRM 或复杂在线验证的游戏
- 必须依赖 Windows 内核服务、驱动或反作弊模块的程序
- 你没有合法持有的游戏、ROM、keys 或固件

## 快速使用教程

### 1. 安装 Shiori

从 [GitHub Releases](https://github.com/jojocys/Shiori/releases/latest) 下载 `Shiori-<版本>.dmg`，打开后把 `Shiori.app` 拖到 `Applications`。App 在系统里会显示为 `栞 Shiori`。

首次打开如果 macOS 提示“无法打开，因为无法验证开发者”，可以：

- 右键点击 `Shiori.app`，选择“打开”
- 或进入 `系统设置 -> 隐私与安全性`，在底部点击“仍要打开”

### 2. 先检查运行环境

打开 Shiori 后，进入游戏配置里的 **运行环境** 页，点击“重新检测”。

你会看到 Wine、Rosetta 2、XQuartz、Gatekeeper 的状态：

- Wine 显示“已内置”或“就绪”即可
- Apple Silicon 机型建议安装 Rosetta 2
- 如果 XQuartz 未安装，建议点击“安装内置 XQuartz”
- 如果 Gatekeeper 拦截 Wine 或 Shiori，进入“隐私与安全性”允许一次

### 3. 添加 Windows 游戏

1. 点击左下角或工具栏的“新建配置”
2. 点击“选择游戏文件夹”
3. 选择包含 `.exe` 的整个游戏目录
4. 在“扫描结果”里确认推荐主程序
5. 如推荐不对，点击“手动选择 EXE”
6. 点击“保存到游戏列表”
7. 点击右上角“开始游戏”

如果第一次启动很慢，这是正常的。Wine 会初始化该游戏的 Prefix，相当于给这个游戏准备一个独立的 Windows 运行环境。

### 4. 语言与乱码

Windows 游戏常见乱码问题通常和 locale / 字体有关。Shiori 在游戏详情顶部提供语言模式：

- `自动`：根据路径和名称猜测
- `日文`：使用 `ja_JP.UTF-8`
- `简中`：使用 `zh_CN.UTF-8`

如果游戏能启动但文字乱码，先尝试切换语言模式，再重新启动。

### 5. Wine Steam

侧栏里的 **Wine Steam** 是独立入口，不依赖当前选中的游戏配置。

推荐流程：

1. 点击“下载 Wine Steam”
2. 在 Wine Prefix 里完成 Windows 版 Steam 安装
3. 回到 Shiori，点击“启动 Steam 客户端”
4. 在 Windows Steam 中安装和启动游戏

注意：macOS 原生 Steam 只能运行 macOS 版本游戏；Windows-only 游戏需要 Windows Steam + Wine。

### 6. Switch 游戏

Shiori 检测到 `.nsp` / `.xci` 后会切到 Switch 模式。Switch 模式不使用 Wine，而是调用原生 Switch 模拟器。Shiori 只负责保存路径和启动模拟器，`prod.keys`、firmware 固件、ROM 都需要你自己准备并在 App 中手动导入或选择。

你需要自己准备：

- Switch 模拟器 App
- 你自己主机导出的 `prod.keys`
- 你自己主机导出的 firmware 固件目录
- 你合法持有的 `.nsp` / `.xci`

Shiori 不会也不能打包、下载或代管这些版权文件。

## Wine、XQuartz、Rosetta 到底是什么

| 名词 | 作用 | 必要性 |
| --- | --- | --- |
| Wine | 让 macOS 运行 Windows `.exe` 的兼容层。它把 Windows API 调用转换成 macOS / Unix 能理解的调用。 | **Windows 游戏必需**。没有 Wine，Shiori 无法启动 `.exe`。正式打包版可以内置 Wine。 |
| Wine Prefix | Wine 的独立 Windows 环境目录，里面有模拟的 `C:` 盘、注册表、运行库和配置。 | **强烈建议每个游戏独立一个 Prefix**，避免不同游戏互相污染。 |
| XQuartz | macOS 上的 X11 图形服务器。部分 Wine 图形窗口、老游戏渲染、Steam 窗口或启动器可能需要它。 | 不一定每个游戏都需要，但遇到黑屏、无窗口、显示异常时非常关键。建议安装。 |
| Rosetta 2 | Apple Silicon 上运行 Intel / x86_64 程序的翻译层。 | M1 / M2 / M3 / M4 Mac 强烈建议安装。很多 Wine 组件和老游戏依赖 x86_64。Intel Mac 不需要。 |
| Gatekeeper | macOS 的安全拦截机制，会拦截未公证 App 或带 quarantine 标记的程序。 | 首次运行可能需要手动允许一次。不是 Shiori 独有问题。 |

常用安装命令：

```bash
# Apple Silicon 安装 Rosetta 2
/usr/sbin/softwareupdate --install-rosetta --agree-to-license

# 安装 XQuartz
brew install --cask xquartz
```

正式打包版 Shiori 可以内置 Wine，并附带 XQuartz 安装包入口；源码开发运行时，如果没有内置 Wine，需要你手动安装或指定 Wine 路径。

## 和 CrossOver 的区别

CrossOver 是成熟的商业兼容层产品，Shiori 是免费、轻量、面向 Galgame 场景的启动器。两者不是同一种定位。

| 对比项 | Shiori | CrossOver |
| --- | --- | --- |
| 费用 | 免费使用，不需要 CrossOver 授权或订阅 | 商业付费产品 |
| 目标 | Galgame、Windows EXE、Wine Steam、轻量管理 | 通用 Windows 软件 / 游戏兼容层 |
| 技术路线 | Wine + 独立 Prefix + macOS 原生 SwiftUI 管理界面 | 基于 Wine 的商业化封装、兼容配置和支持 |
| 优势 | 免费、透明、轻量、日志直出、可自己改 | 更成熟，有商业支持，兼容配置更系统 |
| 适合用户 | 想低成本在 Mac 上跑 Galgame，并愿意按日志排查 | 想要商业支持、愿意付费、需要更广泛应用兼容 |

一句话：**如果你主要玩 Galgame，Shiori 的免费和轻量就是最大优势；如果你需要商业支持和更广泛的 Windows 软件兼容，CrossOver 仍然有它的价值。**

## 数据保存位置

Shiori 会把配置和日志放在用户目录下。首次启动会尝试从旧版 `~/.vnlauncher/` 复制配置到新目录，方便从 GAL FOR MacOS / VNLauncher 时代迁移。

```text
~/.shiori/
├── games.json        # 游戏配置
├── games.backup.json # 游戏配置的本地恢复副本
├── logs/             # 启动日志
├── prefixes/         # Windows 游戏 Prefix
├── steam-prefix/     # Wine Steam 专用 Prefix
└── switch-data/      # Switch 模式受管数据目录
```

删除 Shiori App 不会自动删除这些数据。如果你要完全清理，可以手动删除 `~/.shiori/`。

## 从源码运行

要求：

- macOS 13+
- Xcode / Swift 5.9+
- 如果不使用打包内置 Wine，需要系统中已有 Wine

```bash
cd Shiori
swift run Shiori
```

也可以用 Xcode 打开：

```text
Shiori/Package.swift
```

## 打包 App

打包脚本会生成 `Shiori.app`，并把 Wine 与 XQuartz 安装包放进 App 资源目录。

```bash
cd Shiori
./scripts/build_release_app.sh
```

脚本默认会查找：

- `/Applications/Wine Stable.app`
- `/Applications/Wine.app`
- `~/Applications/Wine Stable.app`
- `~/Applications/Wine.app`
- `~/Downloads/XQuartz.pkg`
- `~/Downloads/XQuartz-2.8.5.pkg`
- `~/Desktop/XQuartz.pkg`
- `~/Desktop/XQuartz-2.8.5.pkg`

也可以显式指定：

```bash
cd Shiori
EMBED_WINE_APP_PATH="/Applications/Wine Stable.app" \
EMBED_XQUARTZ_PKG_PATH="$HOME/Downloads/XQuartz.pkg" \
./scripts/build_release_app.sh
```

可选内置 Switch 模拟器：

```bash
cd Shiori
EMBED_EMULATOR_APP_PATH="/Applications/Ryujinx.app" \
./scripts/build_release_app.sh
```

注意：只能内置模拟器 App 本体，不能打包 ROM、`prod.keys`、固件等版权文件。

## 打包 DMG

先完成 App 打包，再执行：

```bash
cd Shiori
VERSION="$(/usr/bin/plutil -extract version raw version.json)"
DIST="dist"                             # 与上一步默认构建输出一致；自定义构建时替换
./scripts/make_dmg.sh --app "$DIST/Shiori.app" --output "$DIST/Shiori-$VERSION.dmg"
```

产物位于：

```text
Shiori/dist/Shiori.app
Shiori/dist/Shiori-<版本>.dmg
Shiori/dist/Shiori-<版本>.dmg.sha256.txt
```

## 应用内更新（Sparkle 2）

Shiori 使用 Sparkle 2 完成应用内检查、下载、签名验证、替换和重启：

- GitHub Pages 固定提供 `https://jojocys.github.io/Shiori/appcast.xml`。
- GitHub Releases 托管版本化 `Shiori-<版本>.dmg` 及对应 `.sha256.txt`；本阶段不发布 ZIP 或 delta 更新。
- 更新包使用 Sparkle Ed25519 签名；私钥只保存在维护者钥匙串或 CI Secret，仓库仅保存公钥。
- 首次安装仍使用 DMG；安装过带 Sparkle 的版本后，可从 App 菜单或标题栏的下载图标检查更新。
- 标题栏的语言菜单可在简体中文和 English 之间实时切换，并保存用户选择。

发布新版本时，使用 `release.py` 的分阶段入口。`prepare` 只在本地构建并生成隔离 staging；`publish` 才会创建/更新 GitHub Release、上传并匿名验证资产，并把验证后的 feed 写入本地 `docs/appcast.xml`。`publish` 不会自动提交、推送或部署 Pages。

1. 更新 `Shiori/version.json` 的 `version` 与递增的 `build`。
2. 编写仓库根目录的 `Shiori-<版本>-变更说明.md`。
3. 从预期的干净源码提交运行 `prepare`，它会构建 App、制作 DMG、生成签名 staged feed，并写入 `Shiori/dist/releases/<版本>/release.json`。
4. 复核 staging 后运行 `publish`；它按“Release 资产先验证、feed 后提升”的顺序工作。
5. 提交并推送 `docs/appcast.xml`，等待 Pages workflow 完成，再用公网地址执行 `verify-online`。

```bash
cd Shiori
STAGE="dist/releases/0.2.1"  # 替换为本次实际 staging 路径
BUILD="3"                    # 替换为本次实际 build
# 默认流程：已有生产 feed 时不设置 SHIORI_FIRST_FEED
./scripts/release.sh prepare
./scripts/release.sh publish "$STAGE"
# publish 只更新本地 docs/appcast.xml；人工复核后提交并推送该文件，等待 Pages workflow 成功
# Pages 部署完成后再执行公网验证：
./scripts/release.sh verify-online "$STAGE/appcast.xml" --public-feed --build "$BUILD"
```

首次 feed 模式单独执行：仅在确认生产 feed 尚不存在时，将上面的 `prepare` 替换为 `SHIORI_FIRST_FEED=1 ./scripts/release.sh prepare`。

已有生产 feed 时不要设置 `SHIORI_FIRST_FEED=1`；`prepare` 会读取并保留历史条目。示例中的 `STAGE` 和 `BUILD` 必须替换为实际值，不能把尖括号占位符直接复制到命令行。`publish` 后需要人工检查差异、提交 `docs/appcast.xml` 并推送，Pages 部署成功后再次执行 `verify-online`。发布脚本会拒绝未提交的实现/脚本/配置等范围变更、来源提交不一致、额外 Release 安装包及字节不一致的远端资产。

`generate_appcast.sh` 默认从登录钥匙串读取账户 `shiori-jojocys` 的 Sparkle 私钥。CI 中可通过 `SPARKLE_PRIVATE_KEY_FILE` 指定临时私钥文件；不要把私钥提交到 Git。

当前发布脚本默认使用 ad-hoc 签名；这不等同于 Developer ID、公证或 Gatekeeper 放行。正式 Developer ID 发布时设置签名身份：

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
./scripts/build_release_app.sh
```

仓库已包含 GitHub Pages workflow。首次使用前，需要在 GitHub 仓库 Settings → Pages 中将 Source 设为 **GitHub Actions**。

## 项目结构

```text
Shiori/
├── Sources/
│   ├── RootView.swift          # SwiftUI 主界面
│   ├── AppStore.swift          # 状态、配置、导入、更新逻辑
│   ├── GameScanner.swift       # 游戏扫描、EXE/ROM 推荐、反作弊检测
│   ├── GameLauncher.swift      # Windows / Switch 启动入口
│   ├── RuntimeManager.swift    # Wine / XQuartz / Rosetta / Gatekeeper 检测
│   ├── RuntimeInstaller.swift  # 安装包下载辅助
│   ├── SwitchRuntime.swift     # Switch 模拟器数据目录准备
│   ├── UpdateChecker.swift     # App 品牌与运行版本信息
│   └── ShioriUpdater.swift     # Sparkle 应用内更新控制器
├── assets/                     # App 图标资源
├── scripts/
│   ├── build_release_app.sh    # 构建 Shiori.app
│   ├── make_dmg.sh             # 构建版本化 Shiori-<版本>.dmg
│   ├── generate_appcast.sh     # 签署更新并生成无 delta 的 appcast
│   ├── release.py              # prepare/publish/online 发布门禁
│   ├── release.sh              # release.py 命令包装器
│   ├── verify_update_setup.sh  # 验证发布包内的 Sparkle 配置
│   └── generate_app_icon.sh    # 生成 icns
├── config/
│   └── sparkle_public_key.txt  # 可公开的更新验证公钥
└── version.json                # 发布版本号、构建号与兼容旧版的更新清单
```

## 常见问题

### Shiori 是免费的吗

是。Shiori 的核心卖点就是免费、轻量、可本地管理，不需要 CrossOver 授权，不需要额外订阅。

### 为什么运行前还要管 Wine

macOS 不能直接运行 Windows `.exe`。Wine 是真正负责运行 `.exe` 的兼容层，Shiori 是负责选择游戏、管理 Prefix、检测环境、启动进程和记录日志的图形化启动器。

### 为什么需要 XQuartz

Wine 的部分图形窗口会用到 X11。XQuartz 就是 macOS 上的 X11 服务。不是所有游戏都依赖它，但遇到黑屏、窗口不显示、Steam 界面异常时，它经常是必须补上的组件。

### 为什么 Apple Silicon 需要 Rosetta 2

很多 Windows 游戏、旧运行库、Wine 组件仍然是 x86_64 生态。Rosetta 2 让 M 系列 Mac 能运行这些 Intel 架构组件。没有 Rosetta，部分游戏可能根本无法启动。

### 为什么有些游戏完全跑不了

Wine 不是虚拟机，也不是完整 Windows。它不能加载 Windows 内核驱动，所以内核级反作弊、强 DRM、底层驱动类程序通常无法运行。Shiori 会尽量检测部分已知反作弊特征，并提前提示。

### 启动失败怎么办

先点“日志”，查看最近一次启动日志。排查顺序建议：

1. 确认 Wine 已检测到
2. 确认 Rosetta 2 已安装
3. 安装 XQuartz 后重新登录 macOS
4. 检查 EXE 是否选错
5. 换一个独立 Prefix
6. 切换语言模式

## 免责声明

Shiori 只提供本地启动与环境管理能力。请只运行你合法持有的软件和游戏。Switch 相关 keys、固件、ROM 均需要用户自行从本人设备与合法来源取得，项目不会提供、下载、分发或代管这些文件。
