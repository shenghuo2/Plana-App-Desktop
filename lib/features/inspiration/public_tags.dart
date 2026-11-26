import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_client.dart';
import 'artist_models.dart';
import 'public_tag_blocks.dart';
import 'tag_library.dart';
import 'tag_models.dart';

/// 公共库列表(角色=OC、画风=画师串),映射为统一 [TagEntry] 供页面渲染。
/// 依赖 bot 会话:未授权抛 [StateError]('need-bot'),UI 据此显示授权提示
/// (范式同 publicVibesProvider)。场景/其他/自定义类别无公共库。
final publicTagsProvider = FutureProvider.family<List<TagEntry>, TagCategory>((
  ref,
  cat,
) async {
  final session = await ref.watch(botSessionProvider.future);
  if (session == null) throw StateError('need-bot');
  final client = ref.read(backendClientProvider);

  switch (cat) {
    case TagCategory.character:
      final ocs = await client.listPublicOcs(session.sessionId);
      return [
        for (final o in ocs)
          TagEntry(
            id: 'pub_${o.enName}',
            category: TagCategory.character,
            name: o.displayName,
            positive: o.tagGroup,
            negative: o.negativePrompt,
            aliases: o.aliases,
            publicId: o.enName,
            previews: [if (o.previewUrl != null) o.previewUrl!],
            createdAt: o.createdAt * 1000,
            // 归属以服务端 owner_id 为准,存量数据回退 created_by(对齐 web)
            createdBy: o.ownerId ?? o.createdBy,
            mosaic: o.mosaic,
          ),
      ];
    case TagCategory.artist:
      final artists = await client.listPublicArtists(session.sessionId);
      return [
        for (final a in artists)
          TagEntry(
            id: 'pub_${a.id}',
            category: TagCategory.artist,
            name: a.name,
            positive: a.artistString,
            negative: a.negative,
            models: normalizeArtistModels(a.models),
            recipe: StyleRecipe.fromJson(a.recipe),
            publicId: a.id,
            previews: [if (a.previewUrl != null) a.previewUrl!],
            createdAt: a.createdTime * 1000,
            createdBy: a.ownerId ?? a.addedBy,
          ),
      ];
    default:
      return const [];
  }
});

/// Refilter the cached catalog synchronously on confirmation. Only the
/// blacklist editor needs to browse the unfiltered catalog.
final visiblePublicTagsProvider =
    Provider.family<AsyncValue<List<TagEntry>>, TagCategory>((ref, cat) {
      final catalog = ref.watch(publicTagsProvider(cat));
      final rule = ref.watch(
        publicTagBlocksProvider.select((blocks) => blocks[cat]),
      );
      return rule == null || !rule.active
          ? catalog
          : catalog.whenData(
              (entries) => [
                for (final e in entries)
                  if (!rule.hides(e)) e,
              ],
            );
    });

/// 灵感页「我的」的完整来源 = 本地条目 + 公共库里我发布的(本地没副本的补进来,
/// 标 created、去掉打码;对齐 web mineAll)。归属判定优先 owner_id,与服务端一致。
/// 纯函数:灵感页、它的筛选弹层、选角色面板都拿读来的值喂进来。
List<TagEntry> mergeMineTags(
  List<TagEntry> local,
  String? myId,
  List<TagEntry>? pub,
) {
  if (myId == null || pub == null) return local;
  final haveId = {for (final e in local) e.publicId};
  final haveName = {for (final e in local) e.name};
  return [
    ...local,
    for (final p in pub)
      if (p.createdBy == myId &&
          !haveId.contains(p.publicId) &&
          !haveName.contains(p.name))
        p.copyWith(origin: TagOrigin.created, mosaic: false),
  ];
}

/// 同一公共编号在「我的」、公共库和选角色面板使用同一张封面。
/// 自己保存的封面随本地库更新，收藏及缺失的本机文件沿用当前后端的地址。
final tagCoverPreviewsProvider = Provider.autoDispose
    .family<Map<String, String>, TagCategory>((ref, category) {
      final pub = ref.watch(visiblePublicTagsProvider(category)).value;
      final entries = ref.watch(
        tagLibraryProvider.select((s) => s.value?.entries),
      );
      return publicPreviewsOf(
        pub,
        local: entries?.where((e) => e.category == category) ?? const [],
      );
    });

Map<String, String> publicPreviewsOf(
  List<TagEntry>? pub, {
  Iterable<TagEntry> local = const [],
}) => {
  for (final p in pub ?? const <TagEntry>[])
    if (p.publicId != null && p.previewUrl != null) p.publicId!: p.previewUrl!,
  for (final e in local)
    if (e.publicId != null && e.origin != TagOrigin.favorited)
      if (e.previewUrl case final cover?
          when !cover.startsWith('http') && File(cover).existsSync())
        e.publicId!: cover,
};

String? tagPreviewOf(TagEntry e, Map<String, String> pubPreviews) =>
    (e.publicId != null ? pubPreviews[e.publicId] : null) ?? e.previewUrl;

/// 公共库作者目录:归属 id(QQ 号)→ 昵称。灵感页拿它把条目上的 owner_id
/// 显示成人名,也是作者筛选那个输入补全的候选名单来源。
///
/// **取不到就当没有**:未授权、老后端(没这个端点)、网络抖动一律回空表 ——
/// 昵称只是显示增强,缺了照样能按 QQ 号搜和筛,不值得把整页拖进错误态。
final tagAuthorNamesProvider = FutureProvider<Map<String, String>>((ref) async {
  final session = await ref.watch(botSessionProvider.future);
  if (session == null) return const {};
  try {
    final authors = await ref
        .read(backendClientProvider)
        .listPublicAuthors(session.sessionId);
    return {
      for (final a in authors)
        if (a.nickname != null && a.nickname!.isNotEmpty) a.id: a.nickname!,
    };
  } catch (_) {
    return const {};
  }
});

/// 「我的」公共条目的**本地副本**:公共库里 `createdBy` 是自己的那些画风 / 角色。
///
/// 那本来就是用户自己的东西,只是存在服务端 —— 灵感页的「我的」页签就是
/// 「本地条目 + 这些」拼出来的(见 [mergeMineTags])。以前它们只活在一次网络请求的
/// 结果里:关掉应用就没了,离线看不见,图库归类也无从认起。这里落一份到盘上。
///
/// **只留自己的**,不镜像整个公共库:公共库是别人发布的东西,拿它参与归类会凭空
/// 冒出一堆用户从没选过的堆名 —— 归类判据是标签集包含,别人的串只要是你提示词的
/// 子集就会命中。
///
/// 只存归类要用的几样(id / name / positive / createdBy)。预览图、models、作者
/// 昵称一概不存 —— 那些是浏览公共库时才要的,现拉就好。
final myPublicTagsProvider =
    AsyncNotifierProvider<MyPublicTags, Map<TagCategory, List<TagEntry>>>(
      MyPublicTags.new,
    );

class MyPublicTags extends AsyncNotifier<Map<TagCategory, List<TagEntry>>> {
  /// 有公共库的两类(见 [TagCategoryDef.hasPublic])。场景/其他没有。
  static const _cats = [TagCategory.character, TagCategory.artist];

  late final File _file;

  @override
  Future<Map<TagCategory, List<TagEntry>>> build() async {
    final sup = await getApplicationSupportDirectory();
    _file = File('${sup.path}/my_public_tags.json');
    final cached = await _read();
    // 先把盘上的交出去,再后台刷一次:没网 / 没登录就一直用旧的,不报错也不清空。
    //
    // 用 Future(...) 推到事件循环、而不是直接起:公共库那两个 future 可能已经是
    // 完成态(灵感页刚看过),那样续体会排进微任务,有可能赶在 build 自己的 future
    // 完成之前就去写 state —— 构建途中赋值会抛。
    unawaited(Future(_refresh));
    return cached;
  }

  Future<Map<TagCategory, List<TagEntry>>> _read() async {
    try {
      if (!await _file.exists()) return const {};
      final j = jsonDecode(await _file.readAsString());
      if (j is! Map) return const {};
      return {
        for (final c in _cats)
          if (j[c.name] case final List raw)
            c: [
              for (final e in raw)
                if (e is Map<String, dynamic>)
                  if (TagEntry.fromJson({
                        ...e,
                        'category': tagCategoryDef(c).webId,
                      })
                      case final TagEntry t)
                    t,
            ],
      };
    } catch (_) {
      return const {}; // 坏了就当没有,下一次刷新会重建
    }
  }

  Future<void> _refresh() async {
    final me = ref.read(botSessionProvider).value?.botUserId;
    if (me == null || me.isEmpty) return; // 没登录,留着旧副本
    final next = <TagCategory, List<TagEntry>>{};
    for (final c in _cats) {
      try {
        next[c] = [
          for (final e in await ref.read(publicTagsProvider(c).future))
            if (e.createdBy == me) e,
        ];
      } catch (_) {
        return; // 任一类拉失败就整轮放弃,不拿半份覆盖掉好的
      }
    }
    if (!ref.mounted) return;
    state = AsyncData(next);
    try {
      await _file.writeAsString(
        jsonEncode({
          for (final e in next.entries)
            e.key.name: [
              for (final t in e.value)
                {
                  'id': t.id,
                  'name': t.name,
                  'positive': t.positive,
                  'createdBy': t.createdBy,
                },
            ],
        }),
      );
    } catch (_) {} // 写失败只影响下次冷启,不影响本次
  }
}
