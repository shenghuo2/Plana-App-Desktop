# Plana App Desktop 版本构建

标准版的默认分支与日常开发主线为 `main`，远端上传版使用
`feature/remote-upload`。远端上传版只构建 macOS DMG；两版使用同一版本号
和构建号，应用名称均为 **Plana App Desktop**。

## 开发与发布分支

| 分支 | 用途 | 产物 |
|---|---|---|
| `main` | 标准版日常开发 | Windows x64、macOS ARM64 |
| `feature/remote-upload` | 远端上传版日常开发 | macOS ARM64 |
| `release/<版本号>` | 对应版本的标准版源码 | Windows x64、macOS ARM64 |
| `release/remote-upload/<版本号>` | 对应版本的远端上传版源码 | macOS ARM64 |

每次发版都保留两条对应版本的发布分支。完成发布后，后续开发继续写入开发
分支；重建已发布版本时读取对应发布分支。发布标签必须指向标准版发布分支
的提交。基于 Android 1.2.0 的桌面修订依次使用 `1.2.0-desktop.1`、
`1.2.0-desktop.2` 等版本号，构建号独立递增。

当前 `1.2.0-desktop.1` 的源码快照已保留：

- 标准版：`release/1.2.0-desktop.1`，提交 `ab1e831`。
- 远端上传版：`release/remote-upload/1.2.0-desktop.1`，提交 `ca37c7d`。

两条分支的提交取自该版本的实际构建计划。

## 发版与重建流程

1. 在 `main` 更新 `pubspec.yaml` 与 `lib/core/app_info.dart` 的版本号和构建号，
   并将版本提交及待发布修复合入 `feature/remote-upload`。
2. 从两条开发分支各创建对应版本的发布分支，并一起推送。例如下一版：

   ```bash
   git branch release/1.2.0-desktop.2 main
   git branch release/remote-upload/1.2.0-desktop.2 feature/remote-upload
   git push --atomic origin release/1.2.0-desktop.2 release/remote-upload/1.2.0-desktop.2
   ```

3. 手动运行 **Build desktop**，工作流分支选择 `main`，填写
   `release_version=1.2.0-desktop.2`，选择 `editions=both`，默认同时构建标准版
   Windows；只需要两份 DMG 时将 `build_windows` 设为 `false`。
4. 检查两版测试及平台构建结果，将标准版发布分支的提交标记为
   `v1.2.0-desktop.2`，上传安装包与校验文件，再公开 GitHub Release。

填写 `release_version` 后，源码始终来自该版本的两条发布分支。
`standard_ref` / `remote_ref` 用于开发构建。缺少发布分支、两版版本号或构建号
不一致、版本与分支名称不符，以及标签指向其他提交时，工作流会提前失败。
发布构建要求 `editions=both`。

推送 `release/<版本号>` 或 `v*-desktop*` 标签也可触发对应版本的双版构建；
带 `[skip ci]` 的提交使用上述手动入口构建。推送远端上传版的发布分支不重复
触发整组构建，标准版发布分支会读取对应的远端上传版发布分支。

两版各自固定提交 SHA，`desktop-build-plan.json` 记录版本号、分支和实际源码
提交。标准版与远端上传版使用独立流水线，每版的 macOS 构建只等待自己的
分析与测试；标准版 Windows 也只等待标准版测试。

开发构建将 `release_version` 留空，可选择 `editions=both`、`standard` 或
`remote-upload`。推送 `main` 构建标准版，推送 `feature/remote-upload` 只构建
远端上传版。

## 架构与产物

当前 macOS 仅生成 **ARM64** 包。`tool/build_macos_arm64.sh` 在编译期间排除
x86_64，裁剪预编译框架中的其他架构并重新签名；构建完成和 DMG 挂载后均
检查 Mach-O 文件的架构。实际体积、签名与启动验证结果见对应 Actions 记录。

- `Plana-App-Desktop-macOS-arm64.dmg` 及 `.sha256`：标准版。
- `Plana-App-Desktop-RemoteUpload-macOS-arm64.dmg` 及 `.sha256`：远端上传版。
- `build_windows=true` 时额外构建标准 Windows 版。

将两组 DMG 和校验文件放到同一 GitHub Release，先上传标准版 DMG，再上传
远端上传版 DMG，以兼容早期客户端按第一个 DMG 选择安装包的行为。
当前客户端会按自身版本类型选择更新包，更新缓存也校验版本类型。

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
