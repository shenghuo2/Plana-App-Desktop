# 桌面版本构建

标准版使用 `desktop/merge-windows45`，远端上传版使用 `feature/remote-upload`。
远端上传版只构建 macOS DMG；两版使用同一版本号和构建号。

发版前将标准分支的版本提交合入特性分支。然后手动运行 **Build desktop**，
选择 `editions=both`（默认值）。工作流会固定两个分支的提交 SHA，校验版本号及
构建号一致，并对两版分别执行分析、测试、macOS 构建与打包冒烟。
`desktop-build-plan` 产物记录实际源码提交。

产物为：

- `Plana-macOS-arm64.dmg` 及对应 `.sha256`：标准版。
- `Plana-RemoteUpload-macOS-arm64.dmg` 及对应 `.sha256`：远端上传版。
- `build_windows=true` 时额外构建标准 Windows 版；只要 DMG 时选 `false`。

发布时将两组 DMG 和校验文件放到同一 GitHub Release，先上传标准版 DMG，
再上传远端上传版 DMG，以兼容早期客户端按第一个 DMG 选择安装包的行为。
当前客户端会按自身版本类型选择更新包，更新缓存也校验版本类型。

推送 `v*-desktop*` 发布标签也会自动构建两版；标准版固定在该标签提交，
远端上传版固定在特性分支提交，标签必须与源码版本相符。

推送标准分支保留标准版构建；推送特性分支只验证和构建远端上传版，
不会构建其 Windows 版。发布构建始终选择 `both`，版本不一致时会提前失败。
