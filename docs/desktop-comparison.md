# Desktop 来源、差异与 macOS 测试

## 比较基准

- 源仓库 main：`2b205b4`，原版 1.1.1。
- 源仓库实际功能分支 `Plana-app-for-windows` / `plana-app-gallery-optimization`：均为 `062fbaf`。
- 现有工作区分支 `feature/in-app-updater`：`73c6eca`，基于旧版 1.0.8，不代表最新整合版。
- 现有最新整合版 `release/v1.1.1-patch-s.2`：`a566c2a`，同样基于原版 1.1.1。

## 功能差异

源功能分支相对原版有 3 个提交，47 个文件变更（6690 行新增、391 行删除）：

- 自定义图库：创建、分类、移动、导入目标与生成结果归档。
- 历史日期筛选、日期范围选择、拖动连续多选。
- 保存顺序按生成时间，图片名及 EXIF 保留时间；Android 新版本写入媒体库日期。
- 修复预览回跳、删除后的选图与生成结果切换。
- Android 独立测试包配置；photo_manager 升至 ^3.8.0，加入 flutter_localizations。
- 增加图库与保存相关单元、组件测试。

现有整合版另外提供云存储推送、NovelAI 代理、Android 应用内更新、桌面布局、Windows/macOS 构建与 macOS 钥匙串修复。源功能分支没有这些 fork 功能，也没有 macOS 工程。

本 Desktop 分支保留源功能分支完整历史，只移植现有整合版 macOS 工程、传统登录钥匙串配置及对应验证；不自动合并云存储、代理和 Android 更新功能。更新检查及源码入口改指向 shenghuo2/Plana-App-Desktop。

## macOS 构建与测试

通过 GitHub Actions 的 Build desktop 工作流在 macos-15 上构建，Flutter 3.44.2，最低 macOS 14。运行 flutter analyze、flutter test 后构建 DMG，检查 arm64 架构、ad-hoc 签名、钥匙串读写及挂载 DMG 后启动。

构建无 Apple Developer ID 签名及公证。测试包从 Actions 的 Plana-macOS-ad-hoc artifact 下载，解压后挂载 DMG，将 Plana App.app 拖到 Applications。若 macOS 拦截，可在系统设置的隐私与安全性中允许打开。

测试优先覆盖登录后重启、自定义图库创建/导入/生成归档、日期筛选与拖选、删除后预览位置、图片导出。自动构建和启动检查不替代真实账号及交互测试。
