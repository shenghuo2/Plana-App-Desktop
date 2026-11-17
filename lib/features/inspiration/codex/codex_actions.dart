import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../editor/editor_models.dart' show draftOf, outputOf, pickEditorText;
import '../../generate/generate_state.dart';
import '../../generate/models.dart'
    show GenProvider, GenerateState, providerOfModel;
import '../tag_models.dart'
    show TagCategory, TagEntry, appendTagPositivesFolded;
import 'codex_char_split.dart';
import 'codex_models.dart';

/// 把一条法典词条追加进创作页,返回角色卡的落地情况(供调用方措辞)。
///
/// 默认创建命名分区；显式导入主提示词时将完整内容作为命名块追加到末尾，
/// 保留主提示词已有的权重、禁用和折叠草稿。
///
/// 角色段有**两种**来源,都要认:
///  ① 数据源的 `characterPrompts` 字段([CodexEntry.characters])—— 这是主流,
///     全站 8091 条,`tags` 里一个字都不带,早先只读 tags 等于把主体丢了;
///  ② 极少数把 `charN：` / `[charN±]` 直接写在 tags 里(全站 6 条),
///     由 [splitCodexCharacters] 拆(见那个模块)。
///
/// 拆角色卡**只对 NAI 做**:Anima / Krea 没有角色分离这回事,给它们拆出来的卡
/// 会被模块剥离层当场收走,白忙一场还让人以为丢了东西 —— 那两家一律整段
/// (含各角色段)放入新分区。
///
/// 默认把公共部分完整放进以词条名称命名的新分区。
({int added, int dropped}) codexAddToPrompt(
  WidgetRef ref,
  CodexEntry e, {
  bool asSection = true,
}) {
  final gen = ref.read(generateProvider);
  final isNai = providerOfModel(gen.params.model) == GenProvider.nai;
  // An explicit main-prompt import contains all tags and never creates a section.
  if (!asSection) {
    final content = [
      e.tags,
      ...e.characters.map((c) => c.prompt),
    ].where((s) => s.trim().isNotEmpty).join(', ');
    return _codexFoldInto(ref, e, content, gen);
  }
  void put(String content) => _codexSectionInto(ref, e, content);

  // 非 NAI:整条(公共 + 角色段)一起进分区。
  if (!isNai) {
    put(e.fullText);
    return (added: 0, dropped: 0);
  }

  // 字段里带角色段 → 直接用;否则退回内联写法的拆分
  final fromField = [
    for (final c in e.characters)
      for (final slot in c.slots.isEmpty ? const [0] : c.slots)
        (index: slot, positive: c.prompt.trim(), negative: ''),
  ];
  final split = fromField.isEmpty ? splitCodexCharacters(e.tags) : null;
  final chars = fromField.isNotEmpty
      ? fromField
      : [
          for (final c in split!.characters)
            (index: c.index, positive: c.positive, negative: c.negative),
        ];
  final hasChars = chars.isNotEmpty;
  final base = fromField.isNotEmpty
      ? e.tags
      : (hasChars ? split!.base : e.tags);

  // 公共部分为空(全站 401 条 tags 就是空的)时不折叠 —— 否则插进去一个空组。
  put(base);

  if (!hasChars) return (added: 0, dropped: 0);
  final added = ref.read(generateProvider.notifier).addCharactersFilled([
    for (final c in chars)
      (
        name: c.index > 0 ? '角色 ${c.index}' : '角色',
        positive: c.positive,
        negative: c.negative,
      ),
  ]);
  return (added: added, dropped: chars.length - added);
}

/// 一段内容自成一格(不折叠),使用词条名称。空段跳过。
void _codexSectionInto(WidgetRef ref, CodexEntry e, String content) {
  if (content.trim().isEmpty) return;
  ref.read(generateProvider.notifier).addEntrySections([
    TagEntry(
      id: 'codex_${e.id}',
      category: TagCategory.other,
      name: e.title,
      positive: content,
    ),
  ]);
}

/// 把一段内容作为**命名折叠组**追加进主提示词(复用灵感页同一条链路:草稿带回
/// 既有禁用/折叠,定稿由 outputOf 导出,两者同写)。空段直接跳过。
({int added, int dropped}) _codexFoldInto(
  WidgetRef ref,
  CodexEntry e,
  String content,
  GenerateState gen,
) {
  if (content.trim().isEmpty) return (added: 0, dropped: 0);
  final entry = TagEntry(
    id: 'codex_${e.id}',
    category: TagCategory.other,
    name: e.title,
    positive: content,
  );
  final draft = appendTagPositivesFolded(
    pickEditorText(gen.promptRaw, gen.prompt),
    [entry],
  );
  final positive = outputOf(draft);
  ref
      .read(generateProvider.notifier)
      .setPrompts(positive: positive, positiveRaw: draftOf(draft, positive));
  return (added: 0, dropped: 0);
}
