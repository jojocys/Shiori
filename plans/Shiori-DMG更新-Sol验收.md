# Shiori 统一 DMG 更新：Sol 独立验收

日期：2026-09-11，最后证据复核更新于 2026-09-12。验收范围为当前工作区实现和主 Agent 留存的隔离 A → B 证据；未执行发布，也未读取私钥。真实 UI 操作由主 Agent 执行，本文只复核其可追溯结果和系统日志。

> 本文保留为发布前独立验收快照，其中“当前”均指 2026-09-12 当时状态。`v0.2.1` 的最终发布和公网验收结果见《Shiori-DMG更新-实施记录.md》。

## 结论

首轮发现的两项 P1 来源追溯缺陷和一项 P2 发布状态缺陷已修正并通过针对性回归测试，未发现新的发布阻断代码缺陷。应用侧的安装保护设计基本符合方案：更新解压前即进入 pending 状态、所有主要游戏/Wine 启动入口受门禁约束、安装或普通退出前异步重查受管路径、探测或保存失败时拒绝退出，且不终止游戏进程。隔离测试已证明正常 A → B，以及“运行活动触发暂缓 → 暂缓期间普通退出仍被阻止 → 活动停止后继续 → 替换并自动重启 B”的本地核心路径；版本、配置、样例存档和 B 再查最新版均符合预期。因此静态、本地构建和本地核心 UI 矩阵通过。该结论不覆盖全部异常分支、跨 macOS/设备验证或生产公网更新；正式发布还须完成最终源码重建及发布门槛，当前 dirty 源码对应的候选不可发布。

## 首轮缺陷复验

### 已修正：发布来源摘要和干净工作区门禁未覆盖全部构建输入

`Shiori/scripts/release.py` 的 `source_digest()` 只覆盖 Package 文件、version.json 以及 Sources/scripts/config 下部分后缀；`publish()` 的干净工作区检查同样只覆盖这些目录。实际构建还读取 `Shiori/assets/Shiori.icns`、仓库根目录版本说明，并从工作机嵌入 Wine.app、XQuartz.pkg 和可选模拟器。`release.json` 没有记录这些外部构建输入的路径、版本或 hash。

修正后，来源摘要包含图标源文件和当前版本说明；publish 的 clean-scope 包含 assets 与版本说明。prepare 冻结 `release-notes.md`，并记录生成后 icns 的 hash。构建脚本生成 `build-inputs.json`，记录实际 Wine、XQuartz 和可选模拟器的解析路径、版本/build（适用时）及文件树 hash，并在装配完成后重算校验。publish 再核对冻结说明、源图标、App 内图标及最终产物 hash。针对文件和目录输入变更的回归测试已通过。

### 已修正：复用同版本草稿时没有验证草稿/tag 的来源与资产集合

`publish()` 找到同标签 Release 后直接复用，但未验证该草稿的 `target_commitish` 或标签最终解析的 commit 等于 `release.json.source_commit`。它也只核对目标 DMG 和 sha256 是否一致，没有拒绝同一草稿中残留的旧 ZIP、另一个 DMG 或其他候选安装包。

修正后，`validate_release_origin()` 同时解析 `target_commitish` 和既有 tag；任一实际 commit 与 prepared source commit 不同即停止。资产集合仅允许目标 DMG 与对应 sha256 文件，额外 ZIP/DMG 会阻断发布。错误 target、错误 tag 以及额外 ZIP 的回归负例均已通过。

### 已修正：远端中途失败没有写入可恢复的阶段状态

`publish()` 先公开 Release，再匿名下载验证并检查生产 feed 防降级；只有全部成功后才把 `release.json.phase` 改为 `assets-published-feed-ready`。如果 Release 已公开后下载、签名或生产 feed 检查失败，release.json 仍显示 `prepared`。虽然“Release 已公开但 feed 未更新”本身是方案允许的恢复状态，但当前记录会误导重试或人工处置。

修正后，publish 在读取远端 Release 后先把本地状态对齐为 `draft-found` 或 `release-published`，随后依次记录 `draft-assets-uploaded`、`release-published`、`assets-verified` 和 `assets-published-feed-ready`。因此匿名下载或 feed 防降级检查失败时，release.json 会保留最近一个已完成的远端阶段，重试入口也会重新依据远端 draft/public 状态校正记录。

## 已证明通过

- 当前 `Shiori/version.json` 为 1.1.1/build 3，生产下载链接和 feed 常量指向 `jojocys/Shiori`。
- `ShioriUpdater` 为 App 生命周期级 `StateObject`，菜单和侧栏共享同一实例；源码运行缺少正式 bundle 配置时不会启动 updater。
- `willExtractUpdate` 即设置 pending；`applicationShouldTerminate` 在 pending 时返回 `terminateLater`，重新探测并保存后才答复退出。探测失败、保存失败或发现相关活动均不许可退出，普通退出没有代码层面的直接绕过路径。
- pending/checking 会阻止普通游戏、Wine Steam、Steam 安装器及字体修复入口；异步 Wine Steam 启动在真正发出第二次 rungameid 请求时会再次经过门禁。
- 进程探测在后台任务中运行并有 8 秒超时，只读取当前用户 `lsof` 结果；路径按边界匹配并处理 `/private/var` 与 `/var` 等系统别名；不会向游戏或 Wine 进程发送信号。
- 安装重试保留 pending 状态；探测通过后保存 `games.json`，再调用 Sparkle continuation。错误/取消回调会清理 continuation 和门禁。
- 构建配置包含固定 bundle ID、公钥、生产 feed、每日自动检查、禁止自动安装以及提取前验证；主程序验证限定 arm64/macOS 13+。
- DMG、appcast 和独立 Ed25519 校验链路使用最终文件字节；损坏文件及错误公钥负例会失败。appcast 检查拒绝 link-only、delta、错误版本 URL、错误长度、重复 build、HTML/DTD/entity。
- Pages workflow 只上传 appcast.xml，在线校验所有历史 enclosure，并使用并发组及 main HEAD 检查减少旧任务覆盖新版 feed的风险。
- 读取 `/tmp/shiori-swift-test.log`：33 项 Swift 测试通过，其中 UpdateSafety 7 项通过，含真实进程持有中文路径日志文件的检测。
- 独立重新运行 `python3 -m py_compile` 和 `python3 -m unittest Shiori/scripts/test_release.py`：10 项通过。新增 2 项回归测试，覆盖错误 target/tag、额外 Release 资产，以及外部文件/目录输入篡改检测；除测试与本验收报告外没有改动实现源码。

## 真实 A → B 证据复核

### 正常升级：通过

主 Agent 在隔离的 `A-normal` 副本完成更新后，系统日志 `/tmp/shiori-normal-update-late.log` 给出连续时间线：旧进程 PID 53787 于 21:40:54.364 完成退出；Sparkle Updater PID 55490 尚在运行时，新 Shiori PID 56265 于 21:40:54.719 启动，21:40:54.737 的 Process Manager 记录明确标为 `launchedByLS=1`。主 Agent 随后用 `ps` 核对 PID 56265 的可执行文件确为 `A-normal/Shiori.app/Contents/MacOS/Shiori`，该 App 的 plist 版本为 0.0.2；CUA 中应用显示 0.0.2，再次检查更新显示 “You’re up to date”。结合此前记录的同路径替换和测试数据保留，此场景满足本地测试源下的 A → B 替换、自动重启、数据保留与 B 再检查要求。

同一成功时间线在 21:40:54.574 和 21:40:54.615 出现 LaunchServices `-10675`（`refusing to replace a trusted bundle with an untrusted one`），但新进程随即在 21:40:54.719 启动。因此该警告本身不能作为“未重启”的根因，也不能单独判定更新失败。

### 暂缓后继续：连续复测通过

最终连续复测使用独立 `A-observed` 副本。`Shiori/dist/update-qa-20260911-r2/evidence.json` 的 `observed_retest` 记录：旧版 0.0.1 PID 88147 于 02:40:55 运行；安装操作被测试 sleep PID 88224 阻挡并显示暂缓提示；暂缓期间执行普通 Quit 再次显示同类提示，旧 App 与阻挡进程保持运行；停止该测试进程后，从菜单检查更新并继续安装。独立只读 observer `/tmp/shiori-observed-processes.jsonl` 随后于 02:42:19 捕获同一 `A-observed/Shiori.app` 路径的新 PID 88588，bundle 版本已为 0.0.2，而且该捕获发生在 CUA 再次连接 App 之前，排除了后续工具重开造成新进程的解释。之后 CUA 显示 0.0.2，检查更新明确显示最新版。

样例存档升级前后的 SHA-256 都是 `a59dcc6457b23f8882edae7914137651ac0b3a8f97b75123eda8d17e7e2aea9a`，配置 JSON 语义保持一致。由此，本地核心场景中的安装暂缓、暂缓期间普通退出保护、停止活动后继续、同路径替换、自动重启、数据保留和 B 再检查均通过。

较早的 `A-retest` 证据仍如实保留：旧 PID 49210 于 21:25:18.122 获准退出，并于 21:25:18.137 完成退出，但当时观测窗口内没有对应新版启动记录。该异常在结构更完整、observer 连续运行的 `A-observed` 复测中未重现，现有证据不足以认定其根因。正常升级成功时也出现过 LaunchServices `-10675`，所以不得将该警告解释为 A-retest 未重启的根因。

## 未测或待外部验证

- 正常 A → B 与“暂缓后继续”本地核心路径均已在隔离副本通过；这不等于全部异常分支、跨系统或生产公网验收通过。
- 没有实测标准 Sparkle 界面中所有取消/延后分支。特别需要确认：解压后关闭窗口、选择稍后安装、暂缓后再次退出、授权取消后，门禁不会过早解除或永久锁死；且 Sparkle 安装进程没有绕过 `applicationShouldTerminate`。
- 未测网络中断、feed/DMG 404、错误长度/签名在真实 UI 中的文案和旧 App 保留；未测磁盘不足、只读 DMG 启动、无写权限安装位置和系统授权拒绝。
- 未在 macOS 13 最低版本或另一台常用 macOS 设备验证；未验证 Wine/Steam/模拟器在真实升级后的启动冒烟及 Gatekeeper 行为。
- `Shiori/dist/final-20260911/releases/1.1.1/release.json` 是已完成本地挂载、深签名和内嵌公钥 Ed25519 验证的最终候选，记录版本 1.1.1/build 3、DMG SHA-256 `cade8f73c6f4da2a54f314d905cd5f302edb20de079c36cbbeede66ec0dc5090`。但其 `source_status` 明确记录大量未提交改动，当前工作区也仍 dirty；它不能发布，必须从 clean commit 重新 prepare。旧 `Shiori/dist/releases/1.1.1` 产物同样不可发布。
- 未发布 Release、未部署 Pages，也未执行匿名公网完整 DMG 下载。当前已知公网状态为 latest v0.2.0、draft v0.2.1、Pages feed 404；这些只能作为发布前调查结果，不能算生产更新验证。
- 发布前还需确认历史 feed 是否真实存在过、历史资产可匿名获取且仍由同一内嵌公钥验证；若首次 feed 采用 `SHIORI_FIRST_FEED=1`，应留下明确的调查依据。

## 发布前复验门槛

从准备发布的干净 commit 重新运行 prepare，生成新的最终 DMG/feed/release.json；核对所有实际构建输入与 tag，并针对新产物重跑必要的本地核心验收；再公开 Release。公开后必须匿名 GET 完整 DMG并核对长度、SHA-256 与 Ed25519，随后才提升 appcast，等待 Pages 返回 XML 且字节与 staged feed 一致，最后用生产 URL 做一次 A → B 和 B 再检查。
