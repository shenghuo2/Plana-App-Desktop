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
