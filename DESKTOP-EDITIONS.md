# Plana App Desktop 版本构建

标准版使用 `desktop/merge-windows45`，远端上传版使用 `feature/remote-upload`。
远端上传版只构建 macOS DMG；两版使用同一版本号和构建号。
两版的应用名称均为 **Plana App Desktop**，远端上传版在关于页另标明版本类型。

发版前将标准分支的版本提交合入特性分支。然后手动运行 **Build desktop**，
选择 `editions=both`（默认值）。工作流会固定两个分支的提交 SHA，校验版本号及
构建号一致，并对两版分别执行分析、测试、macOS 构建与打包冒烟。
`desktop-build-plan` 产物记录实际源码提交。

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

## 远端上传版使用

在「我的 → 远端上传」保存 API 地址、来源名称及 Token。
API 与参考上传分支一致，支持服务根地址或完整 `/api/v1/assets`。
Token 只保存在系统加密存储；留空保存会保留原 Token。

「收藏自动上传」默认关闭，按钮栏提供手动「远端上传」。开启后改为
「收藏」按钮，图库其他收藏入口也会上传新收藏的原图。开关不补传已有收藏，
取消收藏不删除远端图片。上传失败保留本地收藏，可在右上角任务状态重试；
上传期间同一张图的重复操作共享一次请求。
