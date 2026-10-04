# macOS 桌面版适配

基于 LingXia979/Plana-App-for-windows 的 `1e99e5b`（windows.43，构建 62），包含已发布的三栏工作台、桌面图库、助手、鼠标交互及导出功能。旧测试包基于 `062fbaf`，只有图库改进，没有该桌面 UI。

本次版本：1.1.1-desktop.43.1+62。

- 合并上游完整历史，保留 macOS 工程、传统登录钥匙串和 CI 验证。
- macOS 使用系统字体及苹方，窗口默认 1440×900。
- Finder 文件拖入通过 macOS 原生视图接入上游的图片拖放通道，按 Retina 比例传递坐标。
- macOS 作品保存在 `~/Documents/Plana/output`，接入上游旧作品迁移机制。设置及原图库继续沿用原 Application Support 目录。无法获取文稿目录时退回应用数据目录。
- 存储统计只扫描 Plana 作品目录，不扫描整个文稿目录。
- 应用名称为 Plana App，源码入口指向 shenghuo2/Plana-App-Desktop。

最低 macOS 14；GitHub Actions 构建 DMG，验证签名、钥匙串和挂载启动。测试包为 ad-hoc 签名，未经 Apple 公证。真实账号生成、Finder 拖图及系统权限弹窗仍需实机交互验收。

不包含另一个 fork 整合版的云存储推送、代理和 Android 应用内更新功能。

## 剪贴板图片（桌面端专有）

Flutter 自带的 `Clipboard` 只有文本，图片这半截走原生通道 `plana/clipboard`：macOS 是 `NSPasteboard`（`macos/Runner/ClipboardChannel.swift`），Windows 是剪贴板 API（`windows/runner/clipboard_channel.cpp`），Dart 门面在 `lib/core/platform/clipboard_image.dart`，落点复用既有的图片拖放区域（`ImageDropRegion.acceptPaste`）。

- **贴进来**：⌘/Ctrl+V 把剪贴板里的图交给**焦点所在的那块区域**（对话框附件、导入面板、图生图底图、Vibe／角色／风格参考）。对话输入框另有一颗粘贴按钮，走的是「明确要图」那条路。
- **不抢文本**：剪贴板里同时有能用的文本时不取图，原样交给系统那套文本粘贴；从访达／资源管理器「复制文件」时例外 —— 那时剪贴板里的文本只是文件名。
- **复制出去**：作品画布顶栏「复制图片」、看图浮层信息栏的复制按钮、图库缩略图右键「复制到剪贴板」、对话里那张图的右键菜单。macOS 同时写 PNG 与 TIFF，Windows 写 PNG 格式与 CF_DIB，兼顾新老程序。
- **对话里的图**：桌面端点开的是桌面看图浮层（放大／复制／保存／超分都在里面，并给出它在库里的位置），不再切去图库页；移动端维持原行为。

原生通道由 CI 的 clipboard smoke 验证（启动应用，真往系统剪贴板写一张 2×2 的图再读回来）—— Swift 文件漏进 Xcode 工程这类事，构建和启动都看不出问题，只有用户按 ⌘V 才会发现。Windows 那份 C++ 没有 CI 覆盖，首次在 Windows 上使用请以实机为准。
