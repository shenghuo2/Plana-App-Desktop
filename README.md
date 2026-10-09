> Plana App Desktop：基于 windows.45 桌面重构，合入 Android 1.2.0 功能的 Windows / macOS 桌面版。标准版与远端上传版的构建说明见 [桌面双版构建](https://github.com/shenghuo2/Plana-App-Desktop/blob/main/DESKTOP-EDITIONS.md)。

<div align="center">

<img src="assets/app_icon.png" width="96" alt="Plana App Desktop">

# Plana App Desktop

**面向 Windows 与 macOS 的 AI 绘图工作台**

提示词、画布、图库与 AI 助手，在一个桌面窗口中完成。

[![License](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![Windows](https://img.shields.io/badge/Windows-x64-3572A5)](#下载与安装)
[![macOS](https://img.shields.io/badge/macOS-14%2B%20arm64-555555)](#下载与安装)
[![Release](https://img.shields.io/github/v/release/shenghuo2/Plana-App-Desktop?include_prereleases&label=version&color=6A5ACD)](https://github.com/shenghuo2/Plana-App-Desktop/releases)
[![Status](https://img.shields.io/badge/状态-桌面版测试中-6A5ACD)](#项目状态)
[![Flutter](https://img.shields.io/badge/built%20with-Flutter-02569B?logo=flutter&logoColor=white)](https://flutter.dev)

[下载与安装](#下载与安装) · [本版更新](#本版更新) · [界面预览](#界面预览) · [桌面版亮点](#桌面版亮点) · [问题反馈](https://github.com/shenghuo2/Plana-App-Desktop/issues) · [原版项目](https://github.com/mc5024/Plana-App) · [Windows 重构版](https://github.com/LingXia979/Plana-App-for-windows/tree/Plana-app-for-windows)

</div>

## 项目状态

本项目基于 [Plana App](https://github.com/mc5024/Plana-App) 及其 [Windows 重构版](https://github.com/LingXia979/Plana-App-for-windows/tree/Plana-app-for-windows)，提供 Windows 与 macOS 桌面适配，应用统一命名为 **Plana App Desktop**。
最新预发布为 **1.2.0-desktop.1（构建 69，Pre-release）**，安装包与完整更新说明见 [发布页](https://github.com/shenghuo2/Plana-App-Desktop/releases/tag/v1.2.0-desktop.1)。`desktop.1`、`desktop.2` 等后缀表示基于上游 1.2.0 的桌面修订，构建号独立递增。Android 1.2.0 的合并范围与数据迁移说明见 [合并记录](https://github.com/shenghuo2/Plana-App-Desktop/blob/v1.2.0-desktop.1/docs/ANDROID-1.2.0-INTEGRATION.md)。

- [`main`](https://github.com/shenghuo2/Plana-App-Desktop/tree/main)：标准版的 Windows / macOS 桌面源码。
- [`feature/remote-upload`](https://github.com/shenghuo2/Plana-App-Desktop/tree/feature/remote-upload)：在标准版上增加远端上传与「收藏自动上传」，单独构建 macOS DMG；两版使用相同版本号。
- [`Plana-app-for-windows`](https://github.com/LingXia979/Plana-App-for-windows/tree/Plana-app-for-windows)：Windows 重构上游分支。
- Android 原版介绍与下载请前往[上游仓库](https://github.com/mc5024/Plana-App)。

`main` 为默认分支与日常开发主线。每次发版保留 `release/<版本号>` 和 `release/remote-upload/<版本号>` 两条发布分支，安装包从对应发布分支构建，发布标签指向标准版发布分支的提交。

当前 `1.2.0-desktop.1` 的构建源码保存在 [标准版发布分支](https://github.com/shenghuo2/Plana-App-Desktop/tree/release/1.2.0-desktop.1)和 [远端上传版发布分支](https://github.com/shenghuo2/Plana-App-Desktop/tree/release/remote-upload/1.2.0-desktop.1)。

## 本版更新

- **多画布切换**：支持滚轮、横向滚动和拖动滚动；完整画布下拉列表可选择超出可见宽度的画布，切换或调整窗口后自动显示当前画布。
- **灵感与法典**：压缩顶部布局，改进分类下拉与标签搜索；修正标签条溢出箭头反复显隐，以及窗口缩窄或字号变化后当前标签被隐藏的问题。
- **工具箱导航**：默认在导航栏显示工具箱，可在「我的 → 外观与体验 → 导航栏」调整；导航入口与「我的」中的入口按配置切换，工具页采用桌面布局。
- **字体与控件**：将旧版 105% 字号作为新的默认 100%，创作提示词编辑区保留原有密度；扩大宽松区域的控件，适配高字号下的角色位置 Auto 等按钮。
- **大图与导入窗口**：点击窗口外的空白区域可关闭，改进底部操作排列，图库操作标为「移动到」「复制到」。

本版标准版 **2258 项测试通过**、远端上传版 **2281 项测试通过**，各跳过 3 项；两版静态分析与 macOS 构建、冒烟检查，以及标准版 Windows 构建与原生单测通过，见 [GitHub Actions 构建记录](https://github.com/shenghuo2/Plana-App-Desktop/actions/runs/37911224061)。

## 下载与安装

### 最新预发布：1.2.0-desktop.1

从 [发布页](https://github.com/shenghuo2/Plana-App-Desktop/releases/tag/v1.2.0-desktop.1)或下表下载，无需登录 GitHub。

| 平台 | 版本 | 下载 |
|---|---|---|
| Windows x64 | 标准版 | [下载 ZIP](https://github.com/shenghuo2/Plana-App-Desktop/releases/download/v1.2.0-desktop.1/Plana-App-Desktop-Windows-1.2.0-desktop.1-x64.zip) |
| macOS Apple Silicon（ARM64） | 标准版 | [下载 DMG](https://github.com/shenghuo2/Plana-App-Desktop/releases/download/v1.2.0-desktop.1/Plana-App-Desktop-macOS-arm64.dmg) |
| macOS Apple Silicon（ARM64） | 远端上传版 | [下载 DMG](https://github.com/shenghuo2/Plana-App-Desktop/releases/download/v1.2.0-desktop.1/Plana-App-Desktop-RemoteUpload-macOS-arm64.dmg) |

Windows 完整解压 ZIP 后运行 `plana_app_for_windows.exe`。若提示缺少运行库，请安装 [Microsoft Visual C++ Redistributable x64](https://aka.ms/vc14/vc_redist.x64.exe)。

macOS 需要 **14 或更新版本**，目前发布 Apple Silicon（ARM64）安装包。首次安装或手动升级时先退出旧应用，将 DMG 中的 `Plana App Desktop.app` 拖入应用程序文件夹后运行。两版在关于页标明版本类型。

远端上传版在「我的 → 远端上传」配置服务地址与 Token，支持手动上传、收藏自动上传和失败任务重试；使用说明见 [远端上传配置](https://github.com/shenghuo2/Plana-App-Desktop/blob/feature/remote-upload/DESKTOP-EDITIONS.md#远端上传版使用)。

每个安装包均附带同名 `.sha256` 校验文件，见 [发布页全部资产](https://github.com/shenghuo2/Plana-App-Desktop/releases/tag/v1.2.0-desktop.1)。Windows 包未进行代码签名，macOS 包使用 ad-hoc 签名，尚未经过 Apple 公证。

### 更新与数据兼容

点击右上角版本号，选择「检查更新」即可获取新版本；macOS 支持应用内下载、校验和安装，并按当前版本类型选择对应 DMG。自动检查有 24 小时节流，手动检查可立即获取本版。已使用公开发布列表验证 `1.2.0-desktop` 与 `1.1.3-desktop` 的更新识别。

1.1.2 与 1.1.3 构建 66 内置的 macOS 更新助手有架构检查错误，请先退出旧应用并手动安装本版。安装脚本由旧客户端生成，仅重新下载 DMG 无法修正旧脚本。

改名后仍沿用已有的数据目录、系统钥匙串与 Windows 加密存储，账号配置、图库、历史和助手会话可以继续使用。macOS 手动升级时先退出旧版，安装新版并确认存档正常后，可移除旧的 `Plana App.app` 应用本体；无需删除应用数据。

由 1.1.x 首次升级的多画布存档迁移与回退说明见 [Android 1.2.0 合并记录](https://github.com/shenghuo2/Plana-App-Desktop/blob/v1.2.0-desktop.1/docs/ANDROID-1.2.0-INTEGRATION.md)。[历史发布版本](https://github.com/shenghuo2/Plana-App-Desktop/releases)继续保留旧包。

### 开发构建与 Actions 产物

在 [Build desktop 工作流](https://github.com/shenghuo2/Plana-App-Desktop/actions/workflows/build-macos.yml)中打开成功的构建，登录 GitHub 后下载页面底部的 Artifacts。手动运行时请选择 `main` 分支。发版或重建已发布版本时填写 `release_version`（例如 `1.2.0-desktop.1`）并选择 `editions=both`，工作流会从该版本的两条发布分支构建。`release_version` 留空用于开发分支构建。

| 版本 | Artifact | 安装包 |
|---|---|---|
| macOS 标准版 | `Plana-App-Desktop-macOS-ad-hoc` | `Plana-App-Desktop-macOS-arm64.dmg` |
| macOS 远端上传版 | `Plana-App-Desktop-RemoteUpload-macOS-ad-hoc` | `Plana-App-Desktop-RemoteUpload-macOS-arm64.dmg` |
| Windows 标准版 | `Plana-App-Desktop-Windows-x64` | 完整 Release 目录，运行 `plana_app_for_windows.exe` |

开发与打包说明见 [桌面双版构建](https://github.com/shenghuo2/Plana-App-Desktop/blob/main/DESKTOP-EDITIONS.md)、[Windows 使用说明](https://github.com/shenghuo2/Plana-App-Desktop/blob/main/WINDOWS-README.md)、[macOS 适配说明](https://github.com/shenghuo2/Plana-App-Desktop/blob/main/docs/desktop-comparison.md)与[应用内更新说明](https://github.com/shenghuo2/Plana-App-Desktop/blob/main/docs/desktop-updates.md)。

## 界面预览

以下为 Windows 测试版的实际界面，使用隔离的示例图库与演示对话，不含个人作品、API 密钥或真实授权信息。

### 创作工作台

左侧编辑提示词与生成参数，中间查看画布与历史，右侧随时使用 AI 助手或灵感库。

![Windows 创作工作台：提示词、画布与助手同屏](screenshots/windows/workspace.png)

### 图库与作品详情

按图库整理作品，结合日期、模型与收藏筛选；打开大图即可查看尺寸、种子和完整提示词。

![Windows 图库：大图预览与作品信息](screenshots/windows/gallery.png)

### AI 助手

在独立页面中整理绘图想法、管理会话，将生成的提示词导入创作页；支持多图附件、历史选图和粘贴图片。侧栏与独立页面的生成图均可单击放大查看，支持缩放、拖动和 Esc 关闭。

![Windows AI 助手：会话列表、演示对话与提示词提案](screenshots/windows/assistant.png)

## 桌面版亮点

以下为桌面版的主要功能。

- **桌面工作台**：可调整侧栏宽度，提示词、画布与助手同屏；支持鼠标、键盘、文件拖入和快捷粘贴图片，图片按鼠标所在区域导入。
- **提示词与预设**：多画布、提示词分区、文本／标签视图切换，正负提示词折叠联动；快捷小窗查看与切换每张画布的预设。
- **灵感与法典**：按分类与标签浏览、搜索和收藏词条，使用紧凑下拉菜单与可滚动标签栏。
- **图库管理**：自建图库、日期筛选、收藏、多选与批量导出；一次复制到多个图库，每份副本独立保存。
- **AI 助手**：一次附加多张图片，从历史选择图片，拖入或粘贴到助手区域即可加入附件；支持完整规则编辑、最多 200 轮上下文、会话管理、消息编辑及生成图原图预览。
- **图片剪贴板**：Windows / macOS 可粘贴图片，也可从画布、看图浮层、图库或助手复制图片到其他应用。
- **参考与画布**：Vibe／角色参考单击立即切换、双击放大；图生图放大与超分辨率提供独立入口。
- **本地作品**：Windows 自动保存到程序根目录的 `output` 文件夹；macOS 保存到文稿目录下的 `Plana/output`，升级不会替换作品目录。
- **版本与任务**：右上角显示版本与更新标记，任务运行时提供状态入口；macOS 支持下载并安装应用更新。
- **外观与工具**：全局字号、页面内容对齐与导航入口可配置；工具箱提供图片元数据和提示词权重转换等桌面工具。
- **远端上传版**：配置上传服务后可手动上传原图；开启「收藏自动上传」后，收藏新作品即触发上传，失败可在任务入口重试。

## 账号与使用

绘图需使用者自行配置 NovelAI 等相应服务；AI 助手需自行配置可用接口或相应服务授权。
测试包不附带开发者的 API 密钥、Web／Bot 授权、会话 Cookie 或个人图库。

## 反馈与上游

桌面版的问题与建议请提交到[本仓库 Issues](https://github.com/shenghuo2/Plana-App-Desktop/issues)，并注明平台、版本、复现步骤及相关截图。

本项目保留上游的开源许可与第三方声明。原版功能、Android 构建说明及原作者维护的版本见 [mc5024/Plana-App](https://github.com/mc5024/Plana-App)。

## 致谢与出处

本项目站在这些工作之上。

### 数据与上游

| 来源 | 用途 |
|---|---|
| [Danbooru](https://danbooru.donmai.us/) | 标签体系与别名数据 |
| [Auto-NovelAI-Refactor](https://github.com/zhulinyv/Auto-NovelAI-Refactor) · zhulinyv | 离线补全词库(`assets/danbooru.tsv`,随包分发)的标签表、热度、类目与中文译名,取自其 `danbooru_tags_full_zh.csv`(GPL-3.0) |
| [DanbooruSearchOnline](https://github.com/SuzumiyaAkizuki/DanbooruSearchOnline) · SuzumiyaAkizuki | 增强补全的在线中文搜词、译名与一句话简介 |
| [quicktagcloud](https://novelai.quicktagcloud.com/) | 法典图鉴的全部数据(词条 / 画师串 / 合集 / 例图)。只读接入,数据不随包分发,本应用不修改也不发布法典内容,所有内容归原作者所有 |
| [@huggingface/tokenizers](https://github.com/huggingface/tokenizers) | T5 分词器移植的参照实现 |
| [anime_censor_detection](https://huggingface.co/deepghs/anime_censor_detection) · deepghs | 自动打码的检测模型(`assets/models/censor_n.ort`,随包分发),即其 `censor_detect_v1.0_n`,本项目只做了格式转换与量化(MIT) |
| [NovelAI](https://novelai.net/) · Anlatan | 图像生成服务本身 |

第三方内容的版权归其各自作者所有;其中随包分发的部分(标签库、T5 词表、打码模型)见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md),其余仅作运行时索引与调用。

### 开源库

由 [Flutter](https://flutter.dev)(BSD-3-Clause,© The Flutter Authors)构建,并使用:

- **状态与界面** — [flutter_riverpod](https://pub.dev/packages/flutter_riverpod) ·
  [animations](https://pub.dev/packages/animations) ·
  [material_color_utilities](https://pub.dev/packages/material_color_utilities)
- **网络与编解码** — [http](https://pub.dev/packages/http) ·
  [archive](https://pub.dev/packages/archive) ·
  [msgpack_dart](https://pub.dev/packages/msgpack_dart) ·
  [image](https://pub.dev/packages/image) ·
  [crypto](https://pub.dev/packages/crypto) ·
  [cryptography](https://pub.dev/packages/cryptography)(Blake2b + Argon2id,账号密码登录靠它) ·
  [unorm_dart](https://pub.dev/packages/unorm_dart)
- **平台能力** — [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) ·
  [photo_manager](https://pub.dev/packages/photo_manager) ·
  [photo_manager_image_provider](https://pub.dev/packages/photo_manager_image_provider) ·
  [path_provider](https://pub.dev/packages/path_provider) ·
  [gal](https://pub.dev/packages/gal) ·
  [file_picker](https://pub.dev/packages/file_picker) ·
  [url_launcher](https://pub.dev/packages/url_launcher) ·
  [share_plus](https://pub.dev/packages/share_plus)
- **构建期** — [flutter_lints](https://pub.dev/packages/flutter_lints) ·
  [flutter_launcher_icons](https://pub.dev/packages/flutter_launcher_icons)

以上均为宽松许可(BSD / MIT / Apache-2.0),逐包清单见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md);应用内「关于 → 开源许可」亦有完整入口。

## 许可

Copyright (C) 2026 Sora_Light

本项目以 GPL-3.0 发布,全文见 [LICENSE](LICENSE)。分发修改版(含打包为安装包或便携包分发)
须同样以 GPL-3.0 开源;本程序不作任何担保。

第三方内容不在本许可范围内,版权归各自作者所有,详见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 免责声明

本项目为非官方的第三方客户端,与 NovelAI (Anlatan) 无关联。用户需自行遵守
NovelAI 的服务条款。因使用本应用导致的账号问题、内容问题及任何其他后果,
均由用户自行承担。
