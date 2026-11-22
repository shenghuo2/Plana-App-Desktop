# 桌面开发与任务交付

## 任务交付与 Release 规范

- 每次完成任务，记录原来的问题、完成后的行为、实际验证结果和必要的限制。
- 有实际界面变化时，每个功能准备一张前后对比图。使用真实生产组件、相同示例数据、窗口尺寸和操作状态；图片标明修改前后及来源提交。保留项或没有变化的项目不配图，纯逻辑与文档任务使用文字总结。
- 任务记录持续积累，发版时纳入 Release log。正文保留简短变化列表，所有任务说明、验证、对比图和截图来源统一放入一个 `<details>`；有图片时以「多图预警」作为折叠标题，内部按功能分节。
- 开发预览、截图、拼图和 Release log 生成工具放在应用仓库外的 `../plana-desktop-dev/`，具体流程见该目录的 `RELEASE-LOG.md`。各任务记录放在 `reviews/<任务名>/task-log.json`，可合并导出到 `releases/<版本>/`。
- 正式 Release 图片存入独立的 `release-media` 分支，正文使用固定到具体提交的公开 raw 地址。Release 的 Assets 只保留安装包、统一的 `SHA256SUMS.txt` 和构建清单，不上传截图或各包独立的校验文件。局域网地址和本机文件路径仅用于开发预览。发布沿用当前会话的授权范围。
- GitHub 折叠区保留完整图文，应用内更新说明展示区外的简报。修改 Release 格式时检查这两处的显示效果。

## Git Commit Conventions

Follow these rules strictly for every commit (never bypass git hooks with `--no-verify`):

### 1. Commit Message Format
- **Format**: `<type>(<scope>): <中文简述>` (`scope` is optional; append `!` before `:` for breaking changes; `Merge ` and `Revert ` headers are exempt; `[skip ci]` control tags may follow the Chinese description when skipping duplicate push CI).
- **Allowed `type`**:
  - `feat`: new feature
  - `fix`: bug fix
  - `docs`: documentation only
  - `style`: formatting/whitespace with no logic change
  - `refactor`: code restructuring without changing behavior
  - `perf`: performance improvement
  - `test`: adding or updating tests
  - `build`: build system or external dependencies
  - `ci`: CI/CD configuration or scripts
  - `chore`: tooling, config, or maintenance tasks
- **Language**: Both subject and body MUST be written in **Chinese** (both must contain Chinese characters `[\u4e00-\u9fff]`; standard git trailers such as `Co-Authored-By:` and `(cherry picked from commit ...)` are exempt).
- **Scope & Granularity**:
  - Use a concise lowercase module/area name matching `[a-z0-9_/-]+` (e.g., `auth`, `gallery`, `desktop`, `remote-upload`, `ci`); omit `scope` for cross-cutting changes.
  - Keep **one logical change / one module per commit**; split unrelated changes into separate commits.
- **Examples**:
  - `feat(gallery): 新增回收站批量恢复与永久删除`
  - `fix(windows): 修复 MSVC 14.52 下 WinRT 头文件的协程编译报错`
  - `refactor(storage): 抽离存储写入失败拦截逻辑`
  - `docs: 补充本地调试与版本校验说明`

### 2. Staging & Hygiene Rules
- **Never stage**:
  - Runtime data, local secrets/credentials, or generated artifacts (`.env*` except `.env.example`/`.env.template`, `client_secret*.json`, `tool/local/google-drive-desktop.json`, `android/key.properties`, `*.jks`, `*.keystore`, `*.secure`, `flutter_secure_storage*.dat`, `bot_session*.json`, `settings.json`, `prefs.json`, `prompt_presets.json`, `desktop_output_roots.json`, `my_public_tags.json`, `tag_library*.json`, `output/`, `作品/`, `build/`, `dist/`, `logs/`, `backups/`, `validation/`, `coverage/`, `__pycache__/`, `.DS_Store`);
  - Temporary summary/report/handoff files (`*_SUMMARY.md`, `HANDOFF.md`, `NEXT-SESSION.md`, `WINDOWS-PLAN.md`, `WINDOWS-SOURCE.json`, `WINDOWS-VALIDATION.md`);
  - Unrelated unstaged edits in the working tree or unresolved conflict markers.
- **Code & comment hygiene**:
  - Retain `plana-app-desktop`'s existing bilingual Chinese/English inline comment and log convention (`pre-commit` does not block Chinese comments or logs inside code).
  - Update relevant docs and tests whenever public behavior, config, or APIs change.

### 3. Pre-Commit Verification
Before running `git commit`:
1. Run `dart format` and `flutter analyze --no-pub` on all staged/modified files and resolve all errors.
2. Run relevant unit/integration tests covering the changed modules (`flutter test --no-pub ...` / `python3 tool/test_*.py`).
3. Inspect `git status` and `git diff --cached` to confirm only intended files are staged.

### 4. Mandatory Hook & CI Enforcement
- **Local Hook Setup** (required once per clone; shared across linked worktrees):
  ```bash
  git config core.hooksPath .githooks
  ```
- **Local enforcement (`.githooks/` -> `tool/git_hooks.py`)**:
  - `commit-msg`: validates header against `^(feat|fix|docs|style|refactor|perf|test|build|ci|chore)(\([a-z0-9_/-]+\))?!?: .+$` (exempting `Merge ` / `Revert `), and requires CJK characters in both subject and body prose.
  - `pre-commit`: blocks forbidden paths/reports, unresolved conflict markers, Python/YAML syntax errors, `pubspec.yaml`/`lib/core/app_info.dart` version or identity drift, `pubspec.lock` `gal != 2.3.3` drift, unformatted staged Dart blobs (`dart format`), partial Dart/config staging, and `flutter analyze --no-pub` errors.
- **CI enforcement (`.github/workflows/commit-guard.yml`)**: validates all pushes to `main`, `feature/remote-upload`, `release/*` and pull requests into `main` / `feature/remote-upload` for all commits after `v1.2.4-desktop` (`52af938` / `7d572a5`), alongside `python3 tool/test_git_hooks.py` in `build-desktop-edition.yml`.

## 上游合并与桌面保留清单

合并 `LingXia979/Plana-App-for-windows` 或 Android 上游 `mc5024/Plana-App` 时，必须保留以下桌面能力与兼容性红线：

### 1. 应用身份、数据与凭据兼容
- `lib/core/app_info.dart` 与 `pubspec.yaml` 保持 `kAppName = 'Plana App Desktop'`、`kGithubRepo = 'shenghuo2/Plana-App-Desktop'` 与 `*-desktop*` 版号规则，且两边版本号/构建号必须一致（由 `test/app_info_test.dart` 强校验）。
- 升级兼容红线（不可修改）：
  - **Windows**：`windows/runner/Runner.rc` 内部 `CompanyName` / `ProductName`、安装器 AppId、`plana_app_for_windows.exe` 执行文件名，以及 `<程序目录>/output` 作品目录。
  - **macOS**：Bundle ID、钥匙串 service（`com.sora214.plana.app.secure-storage`）、内部可执行文件名 `Plana App`、DMG 内隐藏的旧名 `Plana App.app` 兼容链接，以及 `~/Documents/Plana/output` 作品目录（存储统计仅扫描 Plana 目录）。
  - **诊断日志**：`lib/core/util/runtime_diagnostics.dart` 与 `windows/runner/runtime_diagnostics.cpp` 保持使用 `Plana App Desktop` 诊断目录与隐私脱敏规则。

### 2. macOS 平台与原生通道
- 保留整个 `macos/` 工程、`macos/Runner/ClipboardChannel.swift`（PNG + TIFF 剪贴板读写）、`macos/Runner/MainFlutterWindow.swift`（Finder 拖图按 Retina 比例传坐标）、`⌘+Enter` 生成与 `⌘V` 贴图。
- `lib/core/auth/secure_storage.dart` 必须保持 `usesDataProtectionKeychain: false`（ad-hoc 签名走传统登录钥匙串）和 `runMacOsKeychainSmokeTest()`。
- 合入 Windows 独有原生能力（如原生拖出、本机代理/截图识别等）时，Dart 层须做平台隔离或补齐 macOS 适配，避免破坏 macOS 编译与剪贴板行为。

### 3. 桌面更新器与顶栏状态
- 保留 `lib/features/update/` 整套更新实现（`desktop_update.dart`、`macos_update_*.dart`、`release_notes.dart`）：更新源固定为 `shenghuo2/Plana-App-Desktop` Releases，按平台、架构和 edition 选包，校验 `SHA256SUMS.txt` / GitHub `sha256:` digest，支持 macOS 下载校验、安全替换与失败回滚。
- 保留 `lib/features/shell/` 顶栏版本入口（`desktop_version_button.dart`）、任务进度面板（`desktop_task_status.dart`）和在途任务拦截（`desktop_work_state.dart`）。

### 4. 双版本隔离、CI 与打包流程
- 保留 `lib/core/desktop_edition.dart`、双开发分支（`main` 标准版 / `feature/remote-upload` 远端上传版）与双发布分支（`release/<版本号>` / `release/remote-upload/<版本号>`），两版发版版本号与构建号一致，Release 先传标准版 DMG 再传远端上传版 DMG。
- 同步到 `feature/remote-upload` 时保留远端上传配置、收藏自动上传、任务状态接入与 edition 标识。
- 保留 `.github/workflows/` 与 `tool/` 下的多平台构建、打包计划、校验汇总及 macOS/Windows 冒烟脚本。

### 5. 跨端兼容与桌面交互不变量
- 保留移动端/Android 兼容文件（`lib/core/auth/credential_store.dart`、`lib/core/ui/nav_bar_guard.dart`、`lib/features/gallery/mobile_*.dart`、`albums/mobile_album_ui.dart`、`widgets/stack_card.dart`）；`CredentialStore` 的 Keystore 失败明文退路仅限 Android，桌面端忽略该标记并正常上报写入失败。
- 剪贴板贴图保持 `DesktopImageDropHost` 光标优先、焦点兜底，且剪贴板含普通文本时不抢文本粘贴。
- 多画布与存储安全：常驻编辑器绑定 `canvasId + 目标 ID`，切换画布/退出/更新前必须先 flush；助手/反推/生成/延迟底图导入在发起时捕获来源 `canvasId`，来源已删不回写草稿；写入失败保留待写内容并取消退出；工作区迁移/损坏备份（`.pre-v3.bak` / `.corrupt.bak`）的 blob 引用纳入清理保护，引用损坏时停止回收。
- 合并 `lib/core/theme/theme_settings.dart` 时保留桌面字号、工具箱导航、对齐偏好及 JSON 向后兼容；合并 `prompt_sections.dart` / `models.dart` 时保留正负草稿与 `foldLinks` 关联保护；保留外部图片超分统一走导入弹窗、循环生成停留创作页、助手生成图打开桌面大图浮层、助手已发消息附件图预览及点外侧关闭浮窗等桌面约定。

## 工程约束与验证

- **工具链与依赖**：CI 使用 Flutter 3.44.2 / Dart 3.12.2 与 `flutter pub get --enforce-lockfile`。默认不升级 `pubspec.lock`，特别注意保留 `gal 2.3.3`（避免 Windows MSVC `/await` 构建错误）；确需升级依赖时须说明原因与验证结果。
- **代码与合并习惯**：`analysis_options.yaml` 启用了 `unawaited_futures`，刻意不等待的 Future 须显式 `unawaited(...)`；合并上游/Windows 分支遇到 CRLF/LF 行末差异时使用 `-Xignore-space-at-eol`。
- **本地验证命令**（按改动范围执行）：
  ```bash
  flutter analyze --no-pub
  flutter test --no-pub --concurrency=2
  python3 tool/test_desktop_build_plan.py
  python3 tool/test_macos_arm64.py
  python3 tool/test_desktop_release_checksums.py
  python3 tool/test_git_hooks.py
  ```
- **验证边界与合规**：自动化测试仅使用模拟服务与合成数据，禁止消耗真实账号点数；交付报告需区分自动化测试与真机交互验收（剪贴板互通、拖放、原生安装包、实机出图）。项目遵循 GPL-3.0，合并上游或第三方资源时须保留原作者、贡献者署名及 `THIRD_PARTY_NOTICES.md`、`docs/ACKNOWLEDGEMENTS.md`。

## 参考文档

- 双版本构建、发布分支与改名兼容：`DESKTOP-EDITIONS.md`
- 本地开发、测试与 Actions 产物：`CONTRIBUTING.md`
- 桌面版本入口与 macOS 更新流程：`docs/desktop-updates.md`
- macOS 移植与剪贴板路由：`docs/desktop-comparison.md`
- 本地崩溃与运行诊断日志：`docs/diagnostics.md`
- 上游合并参考：`docs/ANDROID-1.2.1-INTEGRATION.md`、`docs/ANDROID-1.2.0-INTEGRATION.md`
