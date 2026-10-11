# 开发与贡献

本文件面向修改源码和构建应用的开发者。安装与日常使用见 [README](README.md)。

## 开发环境

CI 使用 **Flutter 3.44.2 / Dart 3.12.2**。本地先运行 `flutter doctor`，确认目标
平台的工具链已就绪：Windows 需要 Visual Studio 的「使用 C++ 的桌面开发」；
macOS 需要 Xcode、命令行工具及 CocoaPods。

```bash
git clone --branch main https://github.com/shenghuo2/Plana-App-Desktop.git
cd Plana-App-Desktop
flutter pub get --enforce-lockfile
```

在对应系统上启动桌面应用：

```bash
# Windows
flutter run -d windows

# macOS
flutter run -d macos
```

保留 `pubspec.lock` 中的依赖版本；为修复构建或功能问题升级依赖时，说明原因与
验证结果。应用版本由 `pubspec.yaml` 和 `lib/core/app_info.dart` 共同维护。

## 分支与发布源码

| 分支 | 用途 |
|---|---|
| `main` | 标准版日常开发 |
| `feature/remote-upload` | 远端上传版日常开发 |
| `release/<版本号>` | 对应版本的标准版构建源码 |
| `release/remote-upload/<版本号>` | 对应版本的远端上传版构建源码 |

当前预发布版本为 `1.2.1-desktop+70`。标准版源码保留在
[`release/1.2.1-desktop`](https://github.com/shenghuo2/Plana-App-Desktop/tree/release/1.2.1-desktop)，
远端上传版保留在
[`release/remote-upload/1.2.1-desktop`](https://github.com/shenghuo2/Plana-App-Desktop/tree/release/remote-upload/1.2.1-desktop)。

发布标签指向标准版发布分支的提交。两版保持相同版本号与构建号，各自保存实际
构建提交；详细创建、校验与重建步骤见 [双版本构建流程](DESKTOP-EDITIONS.md)。

## 修改与验证

先阅读仓库的 [任务交付约定](AGENTS.md)。修复需保留桌面布局与移动布局各自的
行为，并检查远端上传版的 edition、上传配置与任务入口是否受影响。

```bash
flutter analyze --no-pub
flutter test --no-pub --concurrency=2
python3 tool/test_desktop_build_plan.py
python3 tool/test_macos_arm64.py
```

根据改动范围运行相关检查。文档修改检查链接、截图路径和版本描述；原生剪贴板、
macOS 更新或平台打包修改还需对应系统的构建与检查。测试通过与真实复制粘贴、
文件选择、账号生成等实机体验分别记录。

每项任务记录原问题、完成后的行为和实际验证；有界面变化时使用同一份示例数据
准备真实组件的前后对比图。开发工具、日志与任务存档使用仓库外的
`../plana-desktop-dev/`，任务记录在发版时汇入 Release log。

## Actions 构建与产物

打开 [Build desktop](https://github.com/shenghuo2/Plana-App-Desktop/actions/workflows/build-macos.yml)，
工作流分支选择 `main`：开发构建将 `release_version` 留空，可选择单版或双版；
发布和重建旧版本填写 `release_version` 并选择 `editions=both`，源码来自保存的
发布分支。`build_windows=false` 时只构建两份 macOS DMG。

| 版本 | Artifact | 内容 |
|---|---|---|
| macOS 标准版 | `Plana-App-Desktop-macOS-ad-hoc` | `Plana-App-Desktop-macOS-arm64.dmg` 与校验文件 |
| macOS 远端上传版 | `Plana-App-Desktop-RemoteUpload-macOS-ad-hoc` | `Plana-App-Desktop-RemoteUpload-macOS-arm64.dmg` 与校验文件 |
| Windows 标准版 | `Plana-App-Desktop-Windows-x64` | 中文 EXE 安装包、便携 ZIP 及各自的 SHA-256 校验文件 |
| 构建计划 | `desktop-build-plan` | 两版实际分支、提交 SHA、版本与架构 |

登录 GitHub 后可下载成功构建底部的 Artifacts。Actions 产物需要另行发布为
GitHub Release，才会成为应用更新源。发布流程与兼容规则见
[DESKTOP-EDITIONS.md](DESKTOP-EDITIONS.md) 和 [桌面更新说明](docs/desktop-updates.md)。

Windows 上游操作与打包资料见 [WINDOWS-README.md](WINDOWS-README.md)，
macOS 移植背景见 [适配记录](docs/desktop-comparison.md)。

## 提交反馈与修改

Issue 中说明平台、版本和复现步骤。提交修改时说明解决的问题、用户可见结果与
实际验证；涉及两个版本或存档迁移时注明影响范围。第三方来源与许可证按
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 保留。
