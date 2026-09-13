# Shiori 统一 DMG 应用内更新：实施记录

日期：2026-09-13。本文记录本轮实施、验收和生产发布状态。

本轮已完成统一 DMG 更新链路：Sparkle 2 的应用内检查和安装保护、完整 DMG 生成、Ed25519 签名清单、来源与外部构建输入摘要、发布阶段状态记录，以及 Release 资产先行和 feed 后提升的发布门禁。`release.py` 提供 `prepare`、`publish`、`verify-online`；`publish` 不自动提交、推送或部署 Pages。

验证结果：

- Python 发布测试 11 项全部通过。
- DMG 更新实现完成时 Swift 测试 33 项全部通过；其中 UpdateSafety 7 项通过，包含真实进程持有中文路径日志文件的检测。
- 2026-09-12 补充配置持久化修复后，Swift 测试增至 36 项并全部通过。新增 3 项验证：全新及显式空存储不会生成占位配置、用户手动新增的空白配置可跨启动保留、已有配置可跨启动保留并在主文件损坏时从本地备份恢复。
- Sol 独立静态验收通过；首轮发现的来源摘要/干净工作区范围、复用 Release 来源与资产集合、远端失败阶段状态三项缺陷均已复验修复，详见 [Sol 验收](Shiori-DMG更新-Sol验收.md)。
- 隔离 QA 目录为 `Shiori/dist/update-qa-20260911-r2`。正常 A-normal 中旧 PID 53787 于 21:40:54.364 退出，新 PID 56265 于 21:40:54.719 启动，LaunchServices 明确记录 `launchedByLS=1`。更严格的连续 A-observed 复测中，旧 PID 88147 到 02:42:19 由同一路径的新 PID 88588 接替；observer 早于 CUA 再次连接捕获新进程。安装和普通 Quit 均在测试 sleep PID 88224 期间暂缓，停止后从菜单继续，自动重启、配置 JSON 内容一致、样例存档 SHA-256 `a59dcc6457b23f8882edae7914137651ac0b3a8f97b75123eda8d17e7e2aea9a` 与 B 再次检查最新版均通过。较早 A-retest 的异常已标记为最终未复现；成功路径也出现 LS-10675 警告，不能据此认定根因。测试服务超时曾真实 UI 提示 `UpdateError`，取消后按钮恢复并成功重试；不据此宣称所有网络负例通过。

发布前候选与线上状态：

- 发布前生产 feed 为 404，正式版本基线为 `v0.2.0`；最终候选因此以首次 feed 模式生成。
- 最终候选位于 `Shiori/dist/release-0.2.1-final-r3/releases/0.2.1`，来源提交为 `3a4a850`，DMG SHA-256 为 `2eebb902d86ebd18e96d17c17539035247e779cbbba35a60bf324bfd13c4b302`。
- GitHub Release `v0.2.1/build 3` 已公开，仅包含统一 DMG 与 SHA-256 文件；公开 DMG 已完整匿名下载并通过 Ed25519。
- GitHub Pages workflow 已成功部署 `https://jojocys.github.io/Shiori/appcast.xml`；生产 feed 与 staged feed 字节一致，并再次通过公开资产验证。
- UI 验证确认标题栏默认只显示下载图标，中英文可即时切换；当前 4 个配置完整保留。

实际操作顺序（在 `Shiori/` 目录）：

```bash
RELEASE_OUTPUT="$PWD/dist/release-ready"  # 每次使用新的隔离目录
STAGE="$RELEASE_OUTPUT/releases/<version>"
DIST_DIR="$RELEASE_OUTPUT" ./scripts/release.sh prepare
./scripts/release.sh publish "$STAGE"
# 人工复核并提交、推送 docs/appcast.xml，等待 Pages workflow 成功
BUILD="<递增 build>"
./scripts/release.sh verify-online "$STAGE/appcast.xml" --public-feed --build "$BUILD"
```

`prepare` 负责构建 App、制作 DMG、生成 staged appcast 并冻结来源/资产摘要；`publish` 负责校验来源 commit、Release tag 与资产集合、匿名下载、签名和 feed 防降级，并把 feed 写入本地 `docs/appcast.xml`。上述命令只能从 clean commit 执行。`SHIORI_FIRST_FEED=1` 只用于本次首份 feed，后续版本必须保留生产 feed 的历史条目。

已知边界：当前生产构建仍为 ad-hoc 签名；Ed25519 只负责更新包完整性与来源连续性，不提供 Developer ID、公证或 Gatekeeper 放行。本机已安装 `0.2.0/build 2` 过渡版，等待维护者亲自点击更新，完成生产地址下的替换与自动重启验收。更新协调要求用户在提示后自行退出相关游戏或 Wine Steam，应用不会强制终止它们。其余未验证项包括实际 Wine/Steam/模拟器游戏冒烟、macOS 13 最低版本、另一台新机器、权限/磁盘异常及 Gatekeeper 场景；断电后的完整恢复不作保证。
