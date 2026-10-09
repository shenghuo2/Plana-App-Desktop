# Android 1.2.1 桌面合并记录

## 来源与版本

- 桌面起点：`main` 的 `c74bdea`，包含已完成的桌面 UI 修复和按发布分支构建的工作流。
- Android 上游：[v1.2.1](https://github.com/mc5024/Plana-App/releases/tag/v1.2.1)，提交 `9f87a667f7191699df736d3805d80d67673421dc`。
- 共同祖先：已集成的 Android 1.2.0，`e83636143fb5f930d61404818db5aaa6a0e4ab9a`。
- 集成分支：`integration/android-1.2.1`，真实 Git merge 保留 Android 父提交；行末差异使用 `-Xignore-space-at-eol` 处理。
- 源码版本：`1.2.1-desktop+70`。应用身份、数据目录和更新的 edition 选择保持桌面版规则。依赖和 lockfile 不变。
- 已发布的 `1.2.0-desktop.1` 下载链接、发布分支和构建策略保留。本次是本地源码合并，没有发布安装包。

## 功能与桌面适配

| 功能 | 最终行为 |
|---|---|
| NAI 5.0 Full Medium | 模型选择、元数据识别、直连/Bot 载荷和费用统一；固定 14 步、Euler Ancestral，不发送 CFG Rescale；桌面隐藏这些不可调控件 |
| 提示词分区多选 | 桌面卡头直接显示「多选」，使用鼠标勾选、批量启停、删除、合并；抓手仍可排序 |
| 分区合并与撤销 | 先提交常驻编辑器输入；保留正负草稿与折叠关联，处理重名和重复关联 ID；撤销还给来源画布，已删除画布不回写 |
| 主体启停与删除 | 主体正向可停用/删除，负面继续生效；主体停用时桌面仍能编辑负面；写入新的非空正向后重新启用主体 |
| 分区存到灵感库 | 分类、名字和正负向预填到现有桌面浮动编辑窗口；已有相同条目时提示编辑原条目 |
| 紧凑角色卡 | 外观设置可开启；桌面收起头像和内嵌编辑器，提示词一行预览，点击展开继续编辑；保留角色库、名称、开关、位置、排序、删除 |
| 免费 AI 模型 | 未授权时按服务端 `free` 标记筛选；桌面下拉可直接选择，付费偏好暂时回退免费渠道，恢复授权后保留原偏好；发送流程保留多图、重试及来源画布绑定 |
| 外部图片放大 | 桌面图库增加「放大其他图片」，面板中「导入图片」使用原生文件选择器；外部图只走 V5 超分，尺寸与费用取实际图片，JPEG 等格式发送前转 PNG，保存到所选图库，不继承当前图库图片的提示词或种子 |
| 标签池排序 | 四类标签池可拖动抓手调整顺序并保存；筛选栏使用同一顺序，保留已有加宽、横向拖动、滚轮、左右箭头和全部标签搜索 |
| 公共角色预览 | 接入服务端 `mosaic`，低分辨率像素预览带「点击显示原图」提示；首次点击揭示，后续点击选择；自己的条目保持原图 |
| 中转计费 | 展示中转张数与费用，金额保留小数；缺少 `total_fee` 的响应以图片费、Anlas 费及中转费合计，已有总额不重复加费 |
| 导入文案 | 桌面已经有「Vibe / 参考」操作，本次保持现有清晰文案和导入行为 |

## 冲突处理表

忽略行末差异后共 19 个冲突文件。自动合并成功的文件也经过桌面适配检查。

| 文件 | 冲突内容 | 最终处理 |
|---|---|---|
| `README.md` | Android 说明与桌面下载、构建说明 | 保留桌面说明和现有发布链接，合入第三方预设来源声明 |
| `lib/core/app_info.dart` | 应用身份、版本、构建号 | 保留桌面身份，使用 `1.2.1-desktop+70` |
| `lib/core/net/remote_image.dart` | 桌面 `decodeHeight` 和上游 `filterQuality` | 同时保留，原缩略图解码与打码绘制各自可用 |
| `lib/core/theme/theme_settings.dart` | 紧凑角色卡与字号、工具箱、对齐偏好 | 完整合并构造、复制、JSON、相等比较和 hash；旧设置默认关闭紧凑卡 |
| `lib/features/assistant/assistant_state.dart` | 免费模型与桌面发送事务、多图、重试 | 把免费模型检查放进现有准备流程，保留原对话、来源画布和异步状态校验 |
| `lib/features/gallery/widgets/result_canvas.dart` | 外部图片放大与桌面操作、放大设置、保存目标 | 保留原图直接超分与重绘设置，补充外部图片入口、独立尺寸/费用/元数据，保留不可用原因 |
| `lib/features/generate/generate_state.dart` | 主体重新启用与折叠关联回写 | 合并两套字段，补齐多选操作、主体启停和删除 |
| `lib/features/generate/models.dart` | 主体 `enabled` 与桌面 `foldLinks` | 合并构造，保留桌面草稿和关联数据 |
| `lib/features/generate/prompt_sections.dart` | 分区合并、停用与草稿组合 | 共用重名消歧和关联保护算法；停用主体只排除正向，去重清空的折叠不再保留无效关联 |
| `lib/features/generate/widgets/advanced_sheet.dart` | Medium 固定参数与桌面输入 | 隐藏不可调参数，保留其他模型参数输入和步数吸附 |
| `lib/features/generate/widgets/bottom_action_bar.dart` | 模型判断导入与桌面参数摘要 | 补全 Medium 判断，保留循环和导入按钮尺寸 |
| `lib/features/generate/widgets/character_card.dart` | 紧凑角色卡与桌面常驻编辑 | 移动端采用上游紧凑布局；桌面采用可展开的内嵌编辑，保留位置和排序操作 |
| `lib/features/generate/widgets/prompt_card.dart` | Stateful 多选与桌面分区卡 | 显式鼠标入口、选择状态、批量操作；撤销保留关联并绑定来源画布 |
| `lib/features/inspiration/inspiration_page.dart` | 公共打码状态与桌面网格卡 | 把打码接入桌面实际使用的本地卡片类，保留分类、标签栏和右侧筛选布局 |
| `lib/features/inspiration/tag_editor_page.dart` | 预填草稿与桌面浮动窗口 | `showTagEditor` 和浮动编辑器共同支持 `draft`，保留单窗口保护 |
| `lib/features/inspiration/widgets/tag_sheets.dart` | 标签排序与桌面浮层 | 显式抓手、鼠标排序提示、排序保存；保留关闭按钮和异步 mounted 检查 |
| `lib/features/profile/appearance_page.dart` | 新紧凑设置与桌面外观项 | 加入创作页设置，保留导航、字号、工具箱和对齐偏好 |
| `pubspec.yaml` | Android/桌面版本 | 使用桌面版 `1.2.1-desktop+70`，不升级依赖 |
| `test/theme_settings_test.dart` | 上游紧凑设置测试与桌面偏好测试 | 同时覆盖默认值、JSON 回环、字号与工具箱偏好 |

自动合并后额外适配了桌面的参数侧栏、免费模型菜单、主体编辑回写和中转费用缺省合计。

## 验证与截图

使用 Flutter 3.44.2 执行静态分析、完整 Flutter 测试和桌面集成回归：完整套件 2296 项通过，3 项按平台条件跳过；随后新增的两项鼠标排序/公共打码交互测试通过。Python 构建/打包计划测试 33 项通过。新增回归覆盖分区重名关联、停用主体草稿、鼠标多选前提交输入、切换画布后撤销、桌面保存窗口、免费模型菜单、外部 JPEG 尺寸/保存目标/元数据、取消导入、四类标签池鼠标排序和公共预览首次点击揭示。

比较基线固定为 `c74bdea`。同一份脚本、同一组示例提示词、图片、标签、模型列表和账单响应分别挂载两份源码的生产组件，实际截图再左右拼接。免费模型和账单使用模拟后端数据，没有消耗真实账号的点数。截图脚本与图片放在应用仓库外的开发工具目录：`/home/shenghuo2/dev/plana-desktop-dev/reviews/android-1.2.1/`。浏览器交互预览运行实际 Linux 桌面开发应用，继续由仓库外工具维护。

此轮本地验证不包含原生 Windows/macOS 安装包构建；这些平台的打包与启动检查仍由已有 CI 执行。远端上传版同步时另行检查 edition、上传设置、任务重试与自动上传行为，并在交付报告中记录结果。
