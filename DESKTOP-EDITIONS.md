# Plana App Desktop 版本构建

标准版使用 `desktop/merge-windows45`，远端上传版使用 `feature/remote-upload`。
远端上传版只构建 macOS DMG；两版使用同一版本号和构建号。
两版的应用名称均为 **Plana App Desktop**，远端上传版在关于页另标明版本类型。

发版前将标准分支的版本提交合入特性分支。然后手动运行 **Build desktop**，
选择 `editions=both`（默认值）。工作流会固定两个分支的提交 SHA，校验版本号及
构建号一致。标准版与远端上传版使用独立流水线，每版的 macOS 构建只等待
自己的分析与测试；另一版失败不会阻止本版构建。标准版的 Windows 构建
也只等待标准版测试。`desktop-build-plan` 产物记录实际源码提交及架构。

当前构建流程中，macOS 仅生成 **arm64** 包，暂停 Intel / x64 构建。
`tool/build_macos_arm64.sh` 参考 Aaalice 的单架构构建流程，在编译期间排除
x86_64，并裁剪预编译框架中的其他架构，然后重新签名；构建完成及 DMG
挂载后均检查所有 Mach-O 文件只有 arm64，发现其他架构会中止产物上传。
实际体积、签名与启动验证结果以对应版本的 GitHub Actions 构建记录为准。

产物为：

- `Plana-App-Desktop-macOS-arm64.dmg` 及对应 `.sha256`：标准版。
- `Plana-App-Desktop-RemoteUpload-macOS-arm64.dmg` 及对应 `.sha256`：远端上传版。
- `build_windows=true` 时额外构建标准 Windows 版；只要 DMG 时选 `false`。

发布时将两组 DMG 和校验文件放到同一 GitHub Release，先上传标准版 DMG，
再上传远端上传版 DMG，以兼容早期客户端按第一个 DMG 选择安装包的行为。
当前客户端会按自身版本类型选择更新包，更新缓存也校验版本类型。

推送 `v*-desktop*` 发布标签也会自动构建两版；标准版固定在该标签提交，
远端上传版固定在特性分支提交，标签必须与源码版本相符。

推送标准分支保留标准版构建；推送特性分支只验证和构建远端上传版，
不会构建其 Windows 版。发布构建始终选择 `both`，版本不一致时会提前失败。

## 名称与升级兼容

macOS 产物为 `Plana App Desktop.app`，Windows 程序为 `plana_app_for_windows.exe`，
窗口、关于页、开始菜单与安装器使用新显示名。Windows 内部执行文件名沿用旧值，
保持现有快捷方式与任务栏固定项可用；已发布的旧包不回改。

改名保留 macOS bundle ID、钥匙串 service、Windows `CompanyName` / `ProductName`
以及安装器 AppId。`path_provider` 与 Windows 加密存储使用版本资源中的公司名和
产品名定位存档，因此 `Runner.rc` 的内部 `ProductName` 仍为旧值。
自动保存作品目录也沿用已有位置。

macOS 内部可执行文件名保留为 `Plana App`，DMG 附带隐藏的旧名称链接。
旧版更新器仍可通过 `Plana App.app` 复制完整应用并校验原执行文件名；新版更新器
优先读取新名称，也接受旧包。打包冒烟会检查该链接及复制后的签名。

1.1.3 构建 67 修正了 `lipo` 架构检查参数，并参考
`Aaalice_NAI_Launcher/lib/core/services/macos_update_script.dart` 的显式身份、
版本拒绝和退出超时处理，避免 macOS Bash 3.2 忽略部分失败校验。
macOS CI 使用系统 `/bin/bash` 检查安装、拒绝错误包、退出超时与回滚，
并用真实 `lipo` 验证生成的命令。1.1.2 与 1.1.3 构建 66 用户需手动安装
构建 67，因为重新下载 DMG 不会替换旧客户端内置的安装脚本。
