# 致谢与数据来源

Plana App Desktop 基于 [mc5024/Plana-App](https://github.com/mc5024/Plana-App) 与 [LingXia979 的 Windows 重构版](https://github.com/LingXia979/Plana-App-for-windows/tree/Plana-app-for-windows)。感谢上游作者，以及以下数据和开源组件的维护者。

## 数据与服务

| 来源 | 用途 |
|---|---|
| [Danbooru](https://danbooru.donmai.us/) | 标签体系与别名数据 |
| [Auto-NovelAI-Refactor](https://github.com/zhulinyv/Auto-NovelAI-Refactor) · zhulinyv | 离线补全词库(`assets/danbooru.tsv`,随包分发)的标签表、热度、类目与中文译名,取自其 `danbooru_tags_full_zh.csv`(GPL-3.0) |
| [DanbooruSearchOnline](https://github.com/SuzumiyaAkizuki/DanbooruSearchOnline) · SuzumiyaAkizuki | 增强补全的在线中文搜词、译名与一句话简介 |
| [quicktagcloud](https://novelai.quicktagcloud.com/) | 法典图鉴的全部数据(词条 / 画师串 / 合集 / 例图)。只读接入,数据不随包分发,本应用不修改也不发布法典内容,所有内容归原作者所有 |
| [@huggingface/tokenizers](https://github.com/huggingface/tokenizers) | T5 分词器移植的参照实现 |
| [nai5-prompting](https://github.com/Miint-Sunny/nai5-prompting) · Miint-Sunny | AI 助手预设的漫画部分(`assets/prompts/nai5.json`,随包分发)(GPL-3.0) |
| [anime_censor_detection](https://huggingface.co/deepghs/anime_censor_detection) · deepghs | 自动打码的检测模型(`assets/models/censor_n.ort`,随包分发),即其 `censor_detect_v1.0_n`,本项目只做了格式转换与量化(MIT) |
| [NovelAI](https://novelai.net/) · Anlatan | 图像生成服务本身 |

第三方内容的版权归其各自作者所有;其中随包分发的部分(标签库、T5 词表、打码模型、漫画预设)见
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md),其余仅作运行时索引与调用。

## 开源库

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
  [unorm_dart](https://pub.dev/packages/unorm_dart) ·
  [yaml](https://pub.dev/packages/yaml)
- **平台能力** — [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) ·
  [photo_manager](https://pub.dev/packages/photo_manager) ·
  [photo_manager_image_provider](https://pub.dev/packages/photo_manager_image_provider) ·
  [path_provider](https://pub.dev/packages/path_provider) ·
  [gal](https://pub.dev/packages/gal) ·
  [file_picker](https://pub.dev/packages/file_picker) ·
  [url_launcher](https://pub.dev/packages/url_launcher) ·
  [share_plus](https://pub.dev/packages/share_plus) ·
  [flutter_onnxruntime](https://pub.dev/packages/flutter_onnxruntime)
- **构建期** — [flutter_lints](https://pub.dev/packages/flutter_lints) ·
  [flutter_launcher_icons](https://pub.dev/packages/flutter_launcher_icons)

以上均为宽松许可(BSD / MIT / Apache-2.0),逐包清单见
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md);应用内「关于 → 开源许可」亦有完整入口。

返回 [README](../README.md)。
