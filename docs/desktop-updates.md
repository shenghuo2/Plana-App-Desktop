# 桌面版本入口与 macOS 更新

顶栏显示 `kAppVersion`。冷启动首帧后静默检查 GitHub Releases,24 小时内复用缓存;
返回前台时也按缓存期限检查,自动检查失败后至少间隔 5 分钟再重试。手动检查不受
节流限制。更新结果与「关于 → 检查更新」共享,发现新版后保留更新标记。
Windows / macOS 只提示包含当前平台产物的发布版,Mac 还会筛选 CPU 架构。

macOS 的流程参考 `shenghuo2/Aaalice_NAI_Launcher`:用户点击下载,完成大小和 SHA-256
校验后才可安装。安装助手挂载 DMG,检查 Bundle ID、可执行文件名、版本、架构和
代码签名,将新版暂存到当前应用旁边。准备成功后主程序等待工作台、图库、助手、
账本和设置落盘,再退出。助手保留旧 `.app`,切换新版并启动;新版首帧写回实际 PID,
确认启动成功后才删除备份。复制或启动失败时恢复旧版,日志在应用支持目录的
`updates/install/update.log`。

有生成、待生成队列、循环、助手任务或正在编辑图片时禁止安装。下载可在后台进行,
进度也显示在顶栏任务面板。从 DMG 或 App Translocation 运行、或者安装目录不可写时,
提示先把应用移到可写目录,例如 `~/Applications`。

## 发布要求

- 更新源为 `shenghuo2/Plana-App-Desktop`,不查询上游仓库或 Actions artifact。
- 发布标签与 `pubspec.yaml`、`lib/core/app_info.dart` 的公开版本一致,例如
  `v1.1.2-desktop`。安装时按 Flutter 的 macOS 版号规则核对 Bundle 版本。
- 发布 DMG 的架构必须写进文件名,例如 `Plana-App-Desktop-macOS-arm64.dmg` 或
  `Plana-App-Desktop-macOS-x64.dmg`。通用包可使用 `universal`。
- 将 DMG 与同名 `.sha256` 文件一同上传 GitHub Release。GitHub API 有 `sha256:`
  digest 时优先使用它;否则读取 `.sha256`。缺少校验信息时可到发布页手动下载。
- 现有 macOS CI 会产出 arm64 DMG 及校验文件。只有发布为 Release 的版本会被检测,
  CI 构建完成并不会自动成为新版本。

当前 CI 的签名为 ad-hoc;安装助手验证签名完整性,不把它描述为 Apple 公证。
