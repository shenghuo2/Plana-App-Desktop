import 'dart:io';
import 'external/oc_sources.dart';
import 'external/oc_browser.dart';
import '../../core/ui/fade_in_once.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_client.dart';
import '../../core/net/remote_image.dart';
import '../../core/platform/desktop.dart';
import '../../core/store/ui_prefs.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_settings.dart';
import '../../core/ui/pinch_columns.dart';
import '../../core/ui/scroll_memory.dart';
import '../../core/ui/selection_bar.dart';
import '../editor/editor_models.dart' show draftOf, outputOf;
import '../generate/canvas_state.dart';
import '../generate/gen_modules.dart';
import '../generate/generate_state.dart';
import '../generate/models.dart' show maxCharactersOf;
import '../generate/style_recipes.dart';
import '../generate/widgets/common.dart' show confirmDialog, hintSnack;
import '../shell/shell_state.dart';
import 'codex/codex_view.dart';
import 'artist_models.dart';
import 'public_tags.dart';
import 'public_tag_blocks.dart';
import '../gallery/widgets/gallery_drag_selection.dart';
import '../onboarding/bot_auth_page.dart';
import 'tag_editor_page.dart';
import 'tag_library.dart';
import 'widgets/category_sheets.dart';
import 'widgets/tag_card.dart' show TagTextPreview;
import 'tag_models.dart';
import 'widgets/desktop_category_strip.dart';
import 'widgets/desktop_inspiration_search.dart';
import 'widgets/desktop_tag_filter_bar.dart';
import 'widgets/scope_seg_tabs.dart';
import 'widgets/sidebar_inspiration.dart';
import 'widgets/inspiration_entry_card.dart';
import 'widgets/inspiration_selection_bar.dart';
import 'widgets/tag_filter_chips.dart';
import 'widgets/tag_filter_sheet.dart';
import 'widgets/tag_sheets.dart';
import '../../core/util/haptics.dart';
import '../../l10n/l10n.dart';

/// 顶部各行统一的左右边距;行尾若是 IconButton,用 [_kIconEdge]
/// (减去按钮 8px 内衬)让图标视觉边与其他行对齐。
const _kEdge = 14.0;
const _kIconEdge = 6.0;

/// 网格分组:一个区头 + 该组条目(我的/收藏的/公共)。
typedef _Group = ({Widget header, List<TagEntry> items});

/// 网格卡片间距(骨架与真实网格共用,保证切换时不跳位)。
const _gap = 10.0;

/// 网格默认列数。双指捏合可在 1 列到该分类的上限之间换档,每个分类记各的。
const _kCols = 2;

/// 灵感页:web Tag 管理器的移动端形态(底部 tab 常驻页,非弹窗)。
/// 布局随 Vibe 管理器(搜索 + 我的/公共库分段 + 网格 + 底部操作条),
/// 分类切换走左侧抽屉(角色/画风/场景/其他;自定义分类未开放,不做)。
class InspirationPage extends ConsumerStatefulWidget {
  const InspirationPage({super.key, this.embedded = false})
    : manageBlocks = false;
  const InspirationPage.blocklist({super.key})
    : embedded = false,
      manageBlocks = true;
  final bool manageBlocks;
  final bool embedded;

  @override
  ConsumerState<InspirationPage> createState() => _InspirationPageState();
}

class _InspirationPageState extends ConsumerState<InspirationPage>
    with
        AutomaticKeepAliveClientMixin,
        TickerProviderStateMixin,
        PinchColumnsMixin {
  TagCategory _cat = TagCategory.character;

  /// 选中「法典」分类:正文切换为只读的法典浏览器 [CodexView],其余分类照旧。
  /// 法典不属于 [TagCategory](无我的/公共库、无备份/新建),故独立成一个模式位,
  /// 不污染四类标签库的分支逻辑。
  bool _codex = false;
  static const _kCodexSel = '__codex__';

  /// 法典正文进过一次就一直挂着(切回标签库时只是藏起来),没进过不建、不拉数据。
  bool _codexBuilt = false;

  late final TabController _tab = TabController(length: 2, vsync: this);
  // 账本 key 跟着当前分类走;网格按分类 + 分段换 key 重建,新网格从各自的账上落位
  // (换分类、换分段、骨架换成内容都一样)。
  late final _mineScroll = MemoScrollController.keyed(
    () => _scrollKey(_cat, false),
  );
  late final _pubScroll = MemoScrollController.keyed(
    () => _scrollKey(_cat, true),
  );
  final _categoryScroll = ScrollController();
  final _scopeScroll = ScrollController();
  List<OcSource> _sources = const [];
  static const _allExternal = 'all-external';
  String? _sourceId, _lastRemote;
  List<OcSource> get _activeSources => _sourceId == _allExternal
      ? _sources
      : _sources.where((s) => s.id == _sourceId).toList();
  bool get _isExternal => _activeSources.isNotEmpty;
  List<String> _tagPool(TagLibraryState lib) => _isExternal
      ? ({
          for (final s in _activeSources) ...s.tagsWithEdits(lib.externalTags),
        }.toList()..sort())
      : lib.knownTags(_cat);
  int get _remoteIndex {
    if (_lastRemote == _allExternal && _sources.isNotEmpty) {
      return _sources.length + 2;
    }
    final index = _sources.indexWhere((s) => s.id == _lastRemote);
    return index < 0 ? 1 : index + 2;
  }

  Widget _libraryChip({
    required Key key,
    required String label,
    required IconData icon,
    required int index,
    required bool selected,
  }) {
    final compact = index >= 2 ? compactLibraryLabel(label) : label;
    return ChoiceChip(
      key: key,
      avatar: Icon(icon, size: 17),
      label: Text(compact, maxLines: 1, semanticsLabel: label),
      tooltip: compact == label ? null : label,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      showCheckmark: false,
      selected: selected,
      onSelected: (_) => _chooseScope(index),
    );
  }

  void _chooseScope(int index) {
    final id = index < 2
        ? null
        : index == _sources.length + 2
        ? _allExternal
        : _sources[index - 2].id;
    setState(() {
      if (_sourceId != id || (index < 2 && _tabIndex != index)) {
        _authorFilter = null;
      }
      _sourceId = id;
      if (index > 0) _lastRemote = id;
    });
    if (index < 2) _tab.animateTo(index);
  }

  List<OcBrowseItem> _externalItems(TagLibraryState lib) =>
      matchingOcCharacters(
        _activeSources,
        search: _search,
        author: _authorFilter,
        filter: _validFilter(lib),
        matchAny: ref.watch(
          themeSettingsProvider.select((s) => s.inspirationMatchAnyTag),
        ),
        favorites: ref.watch(ocFavoritesProvider),
        tagOverrides: lib.externalTags,
      );
  Widget _external(TagLibraryState lib) => ExternalOcBrowser(
    key: ValueKey(_sourceId),
    items: _externalItems(lib),
    tagOverrides: lib.externalTags,
    sources: _activeSources,
    query: _search,
    author: _authorFilter,
    scope: _sourceId == _allExternal
        ? context.l10n.allExternalLibraries
        : _activeSources.first.label,
    sort: _sortMode,
    filter: _validFilter(lib),
    matchAny: ref.watch(
      themeSettingsProvider.select((s) => s.inspirationMatchAnyTag),
    ),
    embedded: widget.embedded,
    limit: _selectionLimit,
    onPrompt: (items) => _confirmToPrompt(lib, items),
    onCharacters: _charModuleOn
        ? (items) => _confirmAsCharacters(lib, items)
        : null,
  );
  final _categoryKeys = <TagCategory, GlobalKey>{};
  final _codexCategoryKey = GlobalKey();

  /// 每分类已选 id(我的/公共库两 scope 共用一套,对齐 web selectionMap)。
  final Map<TagCategory, Set<String>> _selected = {};

  /// 公共库里点开过原图的打码条目(`分类/id`),本次运行内一直显示原图。
  final _revealed = <String>{};

  static String _revealKey(TagEntry e) => '${e.category.name}/${e.id}';

  String _search = '';
  final _searchController = TextEditingController();
  double _gridWidth = 0;
  bool get _desktopLibrary => ref.read(desktopModeProvider) && !widget.embedded;

  var _filter = const InspirationTagFilter();
  late final _blockDraft = {...ref.read(publicTagBlocksProvider)};
  PublicTagRule get _blockRule => _blockDraft[_cat] ?? const PublicTagRule();
  bool _savingBlocks = false;

  /// 画风的「适用模型」筛选:null=全部;[kGenericModelFilter]=只看通用;
  /// 其余是 [ArtistModelGroup] 的 name。与 [_filter] 是两个正交的维度,
  /// 可以同时生效(「收藏的 + 标了 NAI 5 的」)。
  String? _modelFilter;

  /// 作者筛选:null=全部;其余是条目的归属键(QQ 号,存量数据可能是个名字串)。
  /// 角色/画风(有公共库的两类)都吃这一维,与 [_modelFilter] 同样正交。
  String? _authorFilter;

  /// 作者目录(QQ 号 → 昵称)。build 时从 [tagAuthorNamesProvider] 取一份存下来,
  /// 好让 [_matches] 这些深处的过滤函数不必层层传参;取不到就是空表(显示 QQ 号)。
  Map<String, String> _authorNames = const {};

  /// 排序档,每个分类记各的。与搜索/筛选不同,**换分类不重置** —— 它是「我想
  /// 怎么看这一类」的偏好,回来还想看到上次那个排法。
  final Map<TagCategory, TagSort> _sortBy = {};

  TagSort get _sortMode => widget.manageBlocks
      ? TagSort.author
      : _sortBy[_cat] ?? defaultTagSort(_cat);

  /// 批量操作进行中(禁重入)。
  bool _busy = false;

  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    // 只在整数位变化时 setState(筛选行随 scope 显隐)。
    _tab.animation!.addListener(() {
      final i = _tab.animation!.value.round();
      if (i != _tabIndex && mounted) setState(() => _tabIndex = i);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tab.dispose();
    _mineScroll.dispose();
    _pubScroll.dispose();
    _categoryScroll.dispose();
    _scopeScroll.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  TagCategoryDef get _def => tagCategoryDef(_cat);

  Set<String> get _sel => _selected[_cat] ??= {};

  int get _selectionLimit => _cat == TagCategory.character
      ? maxCharactersOf(ref.read(generateProvider).params.model)
      : _def.maxSelectable;

  void _toggle(TagEntry e) {
    // 角色分类的单次可选数 = 角色卡槽位,跟当前模型走(NAI 5 是 20);
    // 其余分类仍用注册表里的静态上限。
    final cap = _selectionLimit;
    setState(() {
      if (_sel.contains(e.id)) {
        _sel.remove(e.id);
      } else if (_sel.length < cap) {
        _sel.add(e.id);
      } else {
        hintSnack(
          context,
          context.l10n.maxSelectN(cap),
          icon: Icons.block_outlined,
        );
      }
    });
  }

  /// 滚动记忆的账本 key:每个分类的两个 scope 各记各的。
  String _scrollKey(TagCategory c, bool pub) =>
      '${widget.manageBlocks ? 'inspiration.blocks' : 'inspiration'}.${c.name}.${pub ? 'public' : 'mine'}';

  void _switchCategory(TagCategory c) {
    if (c == _cat) return;
    // 滚动位置不用在这里搬:网格的 widget key 带分类,换完 _cat 就是一份新列表,
    // 挂上控制器时从新分类的账上落位(见 [MemoScrollController])。
    setState(() {
      _cat = c;
      _sourceId = null;
      _lastRemote = null;
      _search = '';
      _searchController.clear();
      _filter = const InspirationTagFilter();
      _modelFilter = null;
      _authorFilter = null;
      if (!tagCategoryDef(c).hasPublic) _tab.index = 0;
    });
    // 换完 _cat 再换:上限跟着新分类的卡片形状走
    jumpGridColumns(_savedCols(c));
    _revealCategory(c);
  }

  void _revealCategory(Object category) {
    if (!widget.embedded && !_desktopLibrary) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_categoryScroll.hasClients) return;
      final key = category == _kCodexSel
          ? _codexCategoryKey
          : _categoryKeys[category];
      final target = key?.currentContext?.findRenderObject();
      if (target == null) return;
      _categoryScroll.position.ensureVisible(
        target,
        alignment: 0.5,
        duration: Motion.fast,
        curve: Curves.easeOut,
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  // ---- 双指捏合改列数(见 PinchColumnsMixin) ----

  int _savedCols(TagCategory c) =>
      ref.read(uiPrefsProvider).inspirationColumns[c.name] ?? _kCols;

  @override
  int get initialGridColumns => _savedCols(_cat);

  @override
  int get minGridColumns => 1;

  /// 横幅卡(画风)封顶 3 列:再多一列,卡片矮到名字条和角上的按钮就把图盖满了。
  @override
  int get maxGridColumns => _def.previewAspect > 1 ? 3 : 4;

  @override
  ScrollController get pinchScrollController =>
      _def.hasPublic && _tabIndex == 1 ? _pubScroll : _mineScroll;

  @override
  void onGridColumnsChanged(int cols) {
    final key = _cat.name;
    ref
        .read(uiPrefsProvider.notifier)
        .patch(
          (p) => p.copyWith(
            inspirationColumns: {...p.inspirationColumns, key: cols},
          ),
        );
  }

  // ---- 数据 ----

  bool _matches(TagEntry e, String q) {
    if (q.isEmpty) return true;
    bool has(String s) => s.toLowerCase().contains(q);
    final author = e.createdBy?.trim();
    return has(e.name) ||
        has(e.positive) ||
        e.aliases.any(has) ||
        e.tags.any(has) ||
        // 作者:昵称和 QQ 号都算命中,搜索框里输哪个都能找到他发的东西。
        // ⚠ QQ 号要 5 位起才比 —— 画风名本身就是 A1..Z99 这种编号,再让「5」
        //   去撞每个作者的号码,一搜就是满屏不相干的串。
        (author != null &&
            author.isNotEmpty &&
            ((q.length >= 5 && has(author)) ||
                has(_authorNames[author] ?? '')));
  }

  /// 作者筛选。归属键为空的条目(纯本地 / 公共库里的无主老数据)不属于任何人,
  /// 筛作者时一律不出现。
  List<TagEntry> _byAuthor(List<TagEntry> list) => _authorFilter == null
      ? list
      : [
          for (final e in list)
            if (e.createdBy?.trim() == _authorFilter) e,
        ];

  /// 标签被删(标签池管理里删掉正在筛选的那个)后按「全部」处理,
  /// 不让列表空掉却没有任何选中态。
  InspirationTagFilter _validFilter(TagLibraryState lib) =>
      _filter.validFor(_tagPool(lib));

  /// 「我的」的完整来源 = 本地条目 + 公共库里我发布的(本地没副本的补进来,
  /// 标 created;对齐 web mineAll)。归属判定优先 owner_id,与服务端一致。
  List<TagEntry> _mineAll(TagLibraryState lib) => _def.hasPublic
      ? mergeMineTags(
          lib.of(_cat),
          ref.watch(botSessionProvider).value?.botUserId,
          ref.watch(visiblePublicTagsProvider(_cat)).value,
        )
      : lib.of(_cat);

  List<TagEntry> _mineList(TagLibraryState lib) {
    final q = _search.trim().toLowerCase();
    final filter = _validFilter(lib);
    final matchAny = ref.watch(
      themeSettingsProvider.select((s) => s.inspirationMatchAnyTag),
    );
    final list = _byAuthor(_mineCandidates(_mineAll(lib), q, filter, matchAny));
    _sort(list);
    return list;
  }

  List<TagEntry> _mineCandidates(
    List<TagEntry> all,
    String q,
    InspirationTagFilter filter,
    bool matchAny,
  ) => _byModel([
    for (final e in all)
      if (_matches(e, q) && filter.matches(e, matchAny: matchAny)) e,
  ]);

  /// 适用模型筛选(只对画风有意义;别的分类 [_modelFilter] 恒 null)。
  List<TagEntry> _byModel(List<TagEntry> list) => _modelFilter == null
      ? list
      : [
          for (final e in list)
            if (matchesArtistModelFilter(e.models, _modelFilter)) e,
        ];

  List<TagEntry> _publicList(List<TagEntry> all, TagLibraryState library) {
    final matchAny = ref.watch(
      themeSettingsProvider.select((s) => s.inspirationMatchAnyTag),
    );
    final out = _byAuthor(_publicCandidates(all, library, matchAny));
    _sort(out);
    return out;
  }

  List<TagEntry> _publicCandidates(
    List<TagEntry> all,
    TagLibraryState library,
    bool matchAny,
  ) {
    final q = _search.trim().toLowerCase();
    final desktop = ref.read(desktopModeProvider);
    final findCopy = desktop && !widget.manageBlocks
        ? library.publicCopyLookup(_cat)
        : null;
    final filter = desktop
        ? _validFilter(library)
        : const InspirationTagFilter();
    final list = <TagEntry>[];
    for (final remote in all) {
      final copy = findCopy?.call(remote);
      final entry = copy == null
          ? remote
          : remote.copyWith(tags: copy.tags, favorite: copy.isFavorite);
      if (!(_matches(entry, q) ||
              (widget.manageBlocks &&
                  (entry.publicId?.toLowerCase().contains(q) ?? false))) ||
          !filter.matches(entry, matchAny: matchAny)) {
        continue;
      }
      list.add(entry);
    }
    return _byModel(list);
  }

  void _sort(List<TagEntry> list) {
    switch (_sortMode) {
      case TagSort.number:
        list.sort((a, b) => naturalCompare(a.name, b.name));
      case TagSort.time:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      // 按作者是**切组**不是排序:组内还是该分类原本的顺序,不然点开一栏
      // 里面又是一团乱序。
      case TagSort.author:
        _sortNatural(list);
    }
  }

  /// 分类原本的排法:画风按编号自然序(A1<A2<A10),其余最新在前。
  void _sortNatural(List<TagEntry> list) => _cat == TagCategory.artist
      ? list.sort((a, b) => naturalCompare(a.name, b.name))
      : list.sort((a, b) => b.createdAt.compareTo(a.createdAt));

  // ---- 回填(语义对齐 web;app 编辑器无芯片协议,按约定插裸内容) ----

  List<TagEntry> _resolveSelected(TagLibraryState lib) {
    final byId = {for (final e in lib.of(_cat)) e.id: e};
    final pub = ref.read(visiblePublicTagsProvider(_cat)).value;
    if (pub != null) {
      for (final e in pub) {
        byId[e.id] = e;
      }
    }
    return [
      for (final id in _sel)
        if (byId[id] case final TagEntry e) e,
    ];
  }

  Future<void> _afterConfirm(List<TagEntry> used, String message) async {
    // 写进的是此刻的当前画布,提示条里的「套用」也按它回写
    final canvasId = ref.read(canvasWorkspaceProvider).activeId;
    final libraryIds = [
      for (final e in used)
        if (!e.id.startsWith('ext:')) e.id,
    ];
    if (libraryIds.isNotEmpty) {
      await ref.read(tagLibraryProvider.notifier).markUsed(_cat, libraryIds);
    }
    // 公共画师串使用计数上报(fire-and-forget)
    if (_cat == TagCategory.artist) {
      final session = ref.read(botSessionProvider).value;
      if (session != null) {
        final client = ref.read(backendClientProvider);
        for (final e in used) {
          if (e.id.startsWith('pub_') && e.publicId != null) {
            unawaited(client.reportArtistUse(session.sessionId, e.publicId!));
          }
        }
      }
    }
    if (!mounted) return;
    setState(() => _sel.clear());
    hintSnack(context, message, icon: Icons.check_circle_outline);
    ref.read(shellIndexProvider.notifier).select(kTabCreate);
    // 画风带推荐参数、且对得上当前模型的,弹窗问套不套
    if (_cat == TagCategory.artist) {
      await offerStyleRecipe(context, ref, used, canvasId: canvasId);
    }
  }

  /// 角色 → 加入角色卡(带名追加,上限按模型截断,见 maxCharactersOf)。
  Future<void> _confirmAsCharacters(
    TagLibraryState lib, [
    List<TagEntry>? external,
  ]) async {
    final entries = external ?? _resolveSelected(lib);
    if (entries.isEmpty) return;
    final cap = maxCharactersOf(ref.read(generateProvider).params.model);
    final pubPreview = ref.read(tagCoverPreviewsProvider(_cat));
    final drafts = [for (final e in entries) foldTagEntry(e)];
    final notifier = ref.read(generateProvider.notifier);
    final oldCount = ref.read(generateProvider).characters.length;
    final added = notifier.addNamedCharactersFrom([
      for (var i = 0; i < entries.length; i++)
        (
          name: entries[i].name,
          positive: outputOf(drafts[i].positiveDraft),
          negative: outputOf(drafts[i].negativeDraft),
          avatar: tagPreviewOf(entries[i], pubPreview),
          source: entries[i].id,
        ),
    ]);
    if (added == 0) {
      hintSnack(
        context,
        context.l10n.charsFullN(cap),
        icon: Icons.block_outlined,
      );
      return;
    }
    final addedCharacters = ref
        .read(generateProvider)
        .characters
        .skip(oldCount)
        .toList();
    for (var i = 0; i < added; i++) {
      final draft = drafts[i], character = addedCharacters[i];
      notifier.updateCharacter(
        character.id,
        positiveRaw: draftOf(draft.positiveDraft, character.positive),
        negativeRaw: draftOf(draft.negativeDraft, character.negative),
        foldLinks: draft.links,
      );
    }
    await _afterConfirm(
      entries,
      added < entries.length
          ? context.l10n.addedCharsTruncated(added, cap)
          : context.l10n.addedChars(added),
    );
  }

  /// 角色「主提示词」/ 画风/场景/其他「确认选择」:先为每个条目新建命名分区,
  /// 再完整写入正负向(同提示词卡头的「灵感库」)。
  Future<void> _confirmToPrompt(
    TagLibraryState lib, [
    List<TagEntry>? external,
  ]) async {
    final entries = external ?? _resolveSelected(lib);
    if (entries.isEmpty) return;
    ref.read(generateProvider.notifier).addEntrySections(entries);
    await _afterConfirm(entries, '已加入 ${entries.length} 个提示词分区');
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = context.scheme;
    final lib = ref.watch(tagLibraryProvider).value ?? const TagLibraryState();
    if (widget.manageBlocks) {
      _authorNames = ref.watch(tagAuthorNamesProvider).value ?? const {};
      return _blocklistPage(lib);
    }
    ref.listen(publicTagBlocksProvider, (_, rules) {
      for (final selection in _selected.entries) {
        final rule = rules[selection.key];
        if (rule == null || selection.value.isEmpty) continue;
        final catalog =
            ref.read(publicTagsProvider(selection.key)).value ??
            const <TagEntry>[];
        selection.value.removeAll(catalog.where(rule.hides).map((e) => e.id));
      }
      if (mounted) setState(() {});
    });
    if (!_codex && !lib.visibleTabKeys.contains(tagCategoryDef(_cat).webId)) {
      _cat = TagCategory.character;
      _tab.index = 0;
      _selected.clear();
      _searchController.clear();
      _search = '';
      _revealCategory(_cat);
    }
    final def = _def;
    _sources = _cat == TagCategory.character && ref.watch(desktopModeProvider)
        ? ref.watch(ocSourcesProvider).value ?? const []
        : const [];
    _authorNames = ref.watch(tagAuthorNamesProvider).value ?? const {};
    if (ref.watch(desktopModeProvider) && !widget.embedded) {
      return _desktopPage(scheme, lib);
    }

    // 标签库与法典两套正文都挂着、只显示其一:来回切换时两边的滚动位置、
    // 搜索框、分段都原样还在(原来是整块拆掉重建,切回来就回到顶上)。
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          _shown(!_codex, _tagBody(scheme, lib, def)),
          // 法典模式:只留分类胶囊的顶栏 + 只读浏览器,无搜索/分段/筛选/选择栏
          // (法典自带选择器与搜索)。
          if (_codexBuilt)
            _shown(
              _codex,
              Column(
                children: [
                  _topBarCodex(scheme, lib),
                  const Expanded(child: CodexView()),
                ],
              ),
            ),
        ],
      ),
      bottomNavigationBar: _codex || _isExternal
          ? null
          : _selectionBar(scheme, lib),
    );
  }

  /// 藏起来但不拆:不绘制、不接手势、不占焦点、动画停走,状态全留着。
  Widget _shown(bool on, Widget child) => Offstage(
    offstage: !on,
    child: TickerMode(
      enabled: on,
      child: ExcludeFocus(excluding: !on, child: child),
    ),
  );

  Widget _tagBody(ColorScheme scheme, TagLibraryState lib, TagCategoryDef def) {
    return Column(
      children: [
        _topBar(scheme, lib),
        Padding(
          padding: const EdgeInsets.fromLTRB(_kEdge, 8, _kEdge, 0),
          child: TextField(
            key: ValueKey('tag-search-${def.webId}'),
            controller: _searchController,
            onChanged: (v) => setState(() => _search = v),
            decoration: InputDecoration(
              isDense: true,
              hintText: !_isExternal
                  ? def.searchHint
                  : context.l10n.externalOcSearch,
              prefixIcon: const Icon(Icons.search, size: 20),
              filled: true,
              fillColor: scheme.surfaceContainerHigh,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              // 「作者 / 适用模型」筛选挂在搜索框里:它们和左边的标签筛选是正交
              // 维度,塞进同一条 chip 行既会让人以为是同一组单选,标签一多还会被
              // 挤到屏幕外。挂这儿两个 scope 都有,且不多占一行高度。
              // 只给有公共库的两类(角色/画风)—— 场景/其他的条目全是自己的,
              // 没有「别人」可筛。
              // 以按钮为锚点；独立语义边界保留漏斗与筛选药丸切换时的节点。
              suffixIcon: widget.embedded
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_tagPool(lib).isNotEmpty)
                          Builder(
                            builder: (anchor) {
                              final filter = _validFilter(lib);
                              return IconButton(
                                key: const ValueKey('sidebar-tag-filter'),
                                tooltip: l10nNow.desktopFilterByTag,
                                visualDensity: VisualDensity.compact,
                                icon: Badge.count(
                                  count: filter.tags.length,
                                  isLabelVisible: filter.tags.isNotEmpty,
                                  child: Icon(
                                    Icons.sell_outlined,
                                    size: 17,
                                    color: filter.tags.isEmpty
                                        ? scheme.onSurfaceVariant
                                        : scheme.primary,
                                  ),
                                ),
                                onPressed: () => showDesktopTagPicker(
                                  anchor,
                                  tags: _tagPool(lib),
                                  selectedTags: filter.tags,
                                  onChanged: _setFilterTags,
                                ),
                              );
                            },
                          ),
                        if (def.hasPublic)
                          Flexible(
                            child: Builder(
                              builder: (anchor) => Semantics(
                                container: true,
                                child: _filterButton(scheme, anchor),
                              ),
                            ),
                          ),
                      ],
                    )
                  : def.hasPublic
                  ? Builder(
                      builder: (anchor) => Semantics(
                        container: true,
                        child: _filterButton(scheme, anchor),
                      ),
                    )
                  : null,
              suffixIconConstraints: const BoxConstraints(
                minWidth: 0,
                maxWidth: 190,
              ),
            ),
          ),
        ),
        if (widget.embedded && _validFilter(lib).tags.isNotEmpty)
          SelectedInspirationTags(
            tags: _validFilter(lib).tags,
            onChanged: _setFilterTags,
          ),
        if (widget.embedded)
          SidebarLibraryScope(
            publicAvailable: def.hasPublic,
            publicSelected: !_isExternal && def.hasPublic && _tabIndex == 1,
            sources: [for (final s in _sources) s.label],
            sourceIndex: _isExternal ? _remoteIndex - 2 : -1,
            remoteIndex: _remoteIndex,
            favorites: _filter.favorites,
            onScope: _chooseScope,
            onFavorites: () =>
                setState(() => _filter = _filter.toggleFavorites()),
          )
        else if (def.hasPublic)
          Padding(
            // 「我的」下面紧跟筛选行,间距由它顶出,这里不再留底距;
            // 公共态没有筛选行,分段行会直接贴上网格首个分组头(顶衬仅 2),
            // 补一档底距回到与上方各行相同的 8 节奏。
            padding: EdgeInsets.fromLTRB(
              _kEdge,
              8,
              _kEdge,
              _tabIndex == 0 ? 0 : 8,
            ),
            child: ScopeSegTabs(
              controller: _tab,
              mineCount: lib.of(_cat).length,
            ),
          ),
        if (!widget.embedded && (_tabIndex == 0 || !def.hasPublic))
          _filterChips(lib),
        Expanded(
          // 禁 TabBarView 横滑:横滑手势留给 shell PageView 切底部 tab
          // (与场景/其他分类行为一致),scope 切换走分段控件点按。
          child: _isExternal
              ? _external(lib)
              : pinchLayer(
                  child: def.hasPublic
                      ? TabBarView(
                          controller: _tab,
                          physics: const NeverScrollableScrollPhysics(),
                          children: [_mineTab(lib), _publicTab(lib)],
                        )
                      : _mineTab(lib),
                ),
        ),
      ],
    );
  }

  Widget _blocklistPage(TagLibraryState lib) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.publicLibraryBlocklist)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<TagCategory>(
                  segments: [
                    for (final cat in [
                      TagCategory.character,
                      TagCategory.artist,
                    ])
                      ButtonSegment(
                        value: cat,
                        icon: Icon(tagCategoryDef(cat).icon),
                        label: Text(tagCategoryDef(cat).label),
                      ),
                  ],
                  selected: {_cat},
                  onSelectionChanged: (value) => _switchCategory(value.single),
                  showSelectedIcon: false,
                ),
                SizedBox(
                  width: 300,
                  child: buildDesktopInspirationSearch(
                    context,
                    key: const ValueKey('blocklist-search'),
                    controller: _searchController,
                    onChanged: (v) => setState(() => _search = v),
                    hint: l.searchPublicEntries,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _publicTab(lib)),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton(
                key: const ValueKey('blocklist-confirm'),
                onPressed: _savingBlocks
                    ? null
                    : () async {
                        setState(() => _savingBlocks = true);
                        await ref
                            .read(publicTagBlocksProvider.notifier)
                            .save(_blockDraft);
                        if (mounted &&
                            ModalRoute.of(context)?.isCurrent == true) {
                          Navigator.pop(context);
                        }
                      },
                child: Text(l.confirm),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                key: const ValueKey('blocklist-cancel'),
                onPressed: _savingBlocks ? null : () => Navigator.pop(context),
                child: Text(l.cancel),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _desktopPage(ColorScheme scheme, TagLibraryState lib) {
    final mine = _mineAll(lib);
    final inlineFilters = MediaQuery.sizeOf(context).width >= 1000;
    final snapRows = ref.watch(
      themeSettingsProvider.select((s) => s.inspirationRowSnap),
    );
    final external = _isExternal;
    final public = !external && _def.hasPublic && _tabIndex == 1;
    final visibleCount = external
        ? _externalItems(lib).length
        : public
        ? _publicList(
            ref.watch(visiblePublicTagsProvider(_cat)).value ?? [],
            lib,
          ).length
        : _mineList(lib).length;
    Widget header([Widget? codexSearch]) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final categories = _desktopCategories(lib, snapRows);
              final search =
                  codexSearch ??
                  buildDesktopInspirationSearch(
                    context,
                    key: ValueKey('tag-search-${_def.webId}'),
                    controller: _searchController,
                    onChanged: (value) => setState(() => _search = value),
                    hint: !external
                        ? l10nNow.desktopSearchNamesTagsOrPrompts
                        : context.l10n.externalOcSearch,
                  );
              final tools = Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: codexSearch == null ? 300 : 348,
                    child: search,
                  ),
                  if (codexSearch != null)
                    const CodexMainDrawButton()
                  else
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        IconButton(
                          tooltip: l10nNow.desktopDataBackup,
                          onPressed: () => showTagBackupSheet(context, ref),
                          icon: const Icon(Icons.cloud_outlined, size: 21),
                        ),
                        FilledButton.icon(
                          key: const ValueKey('inspiration-new'),
                          onPressed: () => showTagEditor(
                            context,
                            cat: _cat,
                            categories: _categories(lib),
                          ),
                          icon: const Icon(Icons.add, size: 18),
                          label: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 160),
                            child: Text(
                              '新建${_def.label}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              );
              final textScale = MediaQuery.textScalerOf(context).scale(15) / 15;
              if (constraints.maxWidth < 840 * textScale) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    categories,
                    const SizedBox(height: 12),
                    Align(alignment: Alignment.centerRight, child: tools),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: categories),
                  const SizedBox(width: 16),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth - 200 * textScale,
                    ),
                    child: tools,
                  ),
                ],
              );
            },
          ),
          if (!_codex) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (_def.hasPublic)
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth:
                          MediaQuery.sizeOf(context).width *
                          (inlineFilters ? .34 : .57),
                    ),
                    child: ScopeScrollStrip(
                      controller: _scopeScroll,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _libraryChip(
                            key: const ValueKey('inspiration-scope-mine'),
                            label: '我的 · ${mine.length}',
                            icon: Icons.bookmark_outline,
                            index: 0,
                            selected: !external && !public,
                          ),
                          const SizedBox(width: 8),
                          _libraryChip(
                            key: const ValueKey('inspiration-scope-public'),
                            label: l10nNow.publicLibrary,
                            icon: Icons.public,
                            index: 1,
                            selected: public,
                          ),
                          for (final (i, item) in _sources.indexed)
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: _libraryChip(
                                key: ValueKey('inspiration-source-${item.id}'),
                                label: item.label,
                                icon: Icons.collections_bookmark_outlined,
                                index: i + 2,
                                selected: _sourceId == item.id,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (inlineFilters) ...[
                  if (_def.hasPublic) const SizedBox(width: 18),
                  Expanded(child: _filterChips(lib)),
                  const SizedBox(width: 12),
                ] else
                  const Spacer(),
                Text(
                  !external ? '$visibleCount 个条目' : '$visibleCount 个角色',
                  style: context.texts.bodySmall!.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 10),
                if (_def.hasPublic) ...[
                  _sortButton(scheme),
                  Builder(builder: (anchor) => _filterButton(scheme, anchor)),
                ],
                if (public)
                  IconButton(
                    tooltip: l10nNow.desktopRefreshPublicLibrary,
                    onPressed: _reloadPublic,
                    icon: const Icon(Icons.refresh, size: 20),
                  ),
              ],
            ),
          ],
        ],
      ),
    );

    return Scaffold(
      key: const ValueKey('desktop-inspiration-page'),
      body: _codex
          ? CodexView(desktop: true, desktopHeaderBuilder: header)
          : Column(
              children: [
                header(),
                if (!inlineFilters)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: _filterChips(lib),
                  ),
                Expanded(
                  child: external
                      ? _external(lib)
                      : _def.hasPublic
                      ? TabBarView(
                          controller: _tab,
                          physics: const NeverScrollableScrollPhysics(),
                          children: [_mineTab(lib), _publicTab(lib)],
                        )
                      : _mineTab(lib),
                ),
              ],
            ),
      bottomNavigationBar: _codex || external || _sel.isEmpty
          ? null
          : _desktopSelectionBar(lib),
    );
  }

  List<TagCategory> _categories(TagLibraryState lib) => lib.visibleCategories;

  Widget _categoryManager() => IconButton(
    tooltip: l10nNow.desktopManageCategories,
    icon: const Icon(Icons.dashboard_customize_outlined, size: 20),
    onPressed: _manageCategories,
  );

  Future<void> _manageCategories() async {
    final before = _categories(
      ref.read(tagLibraryProvider).value ?? const TagLibraryState(),
    ).toSet();
    await showCategoryManagerSheet(context);
    if (!mounted) return;
    final categories = _categories(
      ref.read(tagLibraryProvider).value ?? const TagLibraryState(),
    );
    final added = categories.where((c) => !before.contains(c));
    _revealCategory(added.lastOrNull ?? (_codex ? _kCodexSel : _cat));
  }

  Widget _desktopCategories(TagLibraryState lib, bool snapRows) => Row(
    children: [
      Expanded(
        child: DesktopCategoryStrip(
          controller: _categoryScroll,
          snap: snapRows,
          onReflow: () => _revealCategory(_codex ? _kCodexSel : _cat),
          children: [
            for (final tab in lib.visibleTabKeys)
              if (tab == kCodexTabKey)
                _desktopCategory(_kCodexSel, codexTabLabel(), _codex)
              else if (tagCategoryByWebId(tab) case final category?)
                _desktopCategory(
                  category,
                  tagCategoryDef(category).label,
                  !_codex && category == _cat,
                ),
          ],
        ),
      ),
      const SizedBox(width: 4),
      _categoryManager(),
    ],
  );

  Widget _desktopCategory(Object category, String label, bool selected) {
    final scheme = context.scheme;
    final isCodex = category == _kCodexSel;
    final foreground = selected
        ? scheme.onPrimary
        : isCodex
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
    return Semantics(
      key: category is TagCategory
          ? _categoryKeys.putIfAbsent(category, () => GlobalKey())
          : _codexCategoryKey,
      selected: selected,
      child: TextButton.icon(
        key: ValueKey(
          'inspiration-category-${category is TagCategory ? category.name : 'codex'}',
        ),
        onPressed: () => _onPickCat(category),
        style: TextButton.styleFrom(
          minimumSize: const Size(104, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: selected
              ? scheme.primary
              : isCodex
              ? scheme.secondaryContainer
              : scheme.surfaceContainerLow,
          foregroundColor: foreground,
          textStyle: context.texts.labelLarge!.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        icon: Icon(
          category is TagCategory
              ? tagCategoryDef(category).icon
              : Icons.menu_book_outlined,
          size: 20,
        ),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (isCodex) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: foreground.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  l10nNow.desktopOnline,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _topBar(ColorScheme scheme, TagLibraryState lib) {
    if (widget.embedded) {
      final categories = _categories(lib);
      _categoryKeys.removeWhere((c, _) => !categories.contains(c));
      return Padding(
        padding: const EdgeInsets.fromLTRB(_kEdge, 6, _kEdge, 0),
        child: Column(
          children: [
            SidebarCategoryTabs(
              categories: categories,
              selected: _cat,
              labelOf: (category) => tagCategoryDef(category).label,
              onSelected: _switchCategory,
              controller: _categoryScroll,
              itemKeys: _categoryKeys,
            ),
            const SizedBox(height: 4),
            IconButtonTheme(
              data: const IconButtonThemeData(
                style: ButtonStyle(
                  minimumSize: WidgetStatePropertyAll(Size.square(30)),
                  padding: WidgetStatePropertyAll(EdgeInsets.all(4)),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              child: Row(
                key: const ValueKey('sidebar-inspiration-tools'),
                children: [
                  Expanded(
                    child: Text(
                      _isExternal
                          ? '${_externalItems(lib).length} 个角色'
                          : context.l10n.sidebarLocalEntries(
                              lib.of(_cat).length,
                            ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  _categoryManager(),
                  _sortButton(scheme),
                  IconButton(
                    tooltip: l10nNow.desktopDataBackup,
                    icon: const Icon(Icons.cloud_outlined, size: 18),
                    onPressed: () => showTagBackupSheet(context, ref),
                  ),
                  IconButton(
                    tooltip: l10nNow.newLabel,
                    icon: const Icon(Icons.add, size: 19),
                    onPressed: () => showTagEditor(
                      context,
                      cat: _cat,
                      categories: categories,
                    ),
                  ),
                  Builder(
                    builder: (anchor) => IconButton(
                      tooltip: l10nNow.manageTags,
                      icon: const Icon(Icons.settings_outlined, size: 18),
                      onPressed: () => showTagPoolSheet(anchor, ref, _cat),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      // 行尾是 IconButton:右边距减去它的内衬,图标视觉边与其他行对齐
      padding: const EdgeInsets.fromLTRB(_kEdge, 6, _kIconEdge, 0),
      child: Row(
        children: [
          _categoryPill(scheme, lib),
          const Spacer(),
          // 排序只给有公共库的两类:场景/其他的条目全是自己的,没有作者可分组
          if (_def.hasPublic) _sortButton(scheme),
          IconButton(
            tooltip: l10nNow.desktopDataBackup,
            icon: const Icon(Icons.cloud_outlined),
            onPressed: () => showTagBackupSheet(context, ref),
          ),
          IconButton(
            tooltip: l10nNow.newLabel,
            icon: const Icon(Icons.add),
            onPressed: () =>
                showTagEditor(context, cat: _cat, categories: _categories(lib)),
          ),
        ],
      ),
    );
  }

  /// 顶栏的排序按钮。不是默认档时图标点主色 —— 「列表怎么变了个顺序」
  /// 得能一眼找到是这儿改的。
  Widget _sortButton(ColorScheme scheme) {
    final mode = _sortMode;
    final on = mode != defaultTagSort(_cat);
    return PopupMenuButton<TagSort>(
      tooltip: '排序:${mode.label}',
      offset: widget.embedded ? Offset.zero : const Offset(0, 44),
      position: widget.embedded ? PopupMenuPosition.under : null,
      iconSize: widget.embedded ? 18 : null,
      padding: widget.embedded
          ? const EdgeInsets.all(4)
          : const EdgeInsets.all(8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: (v) => setState(() => _sortBy[_cat] = v),
      itemBuilder: (_) => [
        for (final s in tagSortOptions(_cat))
          PopupMenuItem(
            value: s,
            child: Row(
              children: [
                Text(s.label),
                const Spacer(),
                if (s == mode)
                  Icon(Icons.check, size: 18, color: scheme.primary),
              ],
            ),
          ),
      ],
      icon: Icon(
        Icons.sort,
        color: on ? scheme.primary : scheme.onSurfaceVariant,
      ),
    );
  }

  /// 法典模式顶栏:左分类胶囊 + 右侧「选择主法典」(占用原本的空位,
  /// CodexView 不再自带头部整行)。
  Widget _topBarCodex(ColorScheme scheme, TagLibraryState lib) => Padding(
    padding: const EdgeInsets.fromLTRB(_kEdge, 6, _kEdge, 0),
    // 定高 48 与标签页 _topBar 对齐(那边由 IconButton 撑到 48,胶囊居中留 2px
    // 呼吸位)。否则本行仅胶囊高 44,整行偏矮、胶囊贴顶,比标签页明显偏上。
    child: SizedBox(
      height: 48,
      child: Row(
        children: [
          _categoryPill(scheme, lib),
          const SizedBox(width: 10),
          // 靠右、按内容自适应宽度(不撑满);标题过长时才截断
          const Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: CodexPickerButton(),
            ),
          ),
        ],
      ),
    ),
  );

  /// 分类选择(四类标签库 + 法典)。法典是特殊项:切模式,不走 [_switchCategory]。
  void _onPickCat(Object v) {
    if (v == _kCodexSel) {
      setState(() => _codex = _codexBuilt = true);
      _revealCategory(v);
    } else if (v is TagCategory) {
      if (_codex) {
        setState(() => _codex = false);
        if (_cat == v) _revealCategory(v);
      }
      _switchCategory(v);
    }
  }

  /// 分类切换:整块 filled 胶囊(图标+名称+计数+▾),点开下拉选分类。
  Widget _categoryPill(ColorScheme scheme, TagLibraryState lib) {
    return PopupMenuButton<Object>(
      tooltip: l10nNow.desktopSwitchCategory,
      offset: const Offset(0, 50),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: (v) => v == 'manage-categories'
          ? showCategoryManagerSheet(context)
          : _onPickCat(v),
      itemBuilder: (_) => [
        for (final d in _categories(lib).map(tagCategoryDef))
          PopupMenuItem(
            value: d.key,
            child: _catMenuRow(
              scheme,
              d.icon,
              d.label,
              d.key == _cat && !_codex,
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _kCodexSel,
          child: _catMenuRow(
            scheme,
            Icons.menu_book_outlined,
            codexTabLabel(),
            _codex,
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'manage-categories',
          child: Text(l10nNow.desktopManageCategories),
        ),
      ],
      child: Container(
        height: 44,
        padding: const EdgeInsets.fromLTRB(14, 0, 10, 0),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: _codex
              ? [
                  Icon(Icons.menu_book, size: 19, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    l10nNow.sectionCodex,
                    style: context.texts.titleMedium!.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.keyboard_arrow_down,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ]
              : [
                  Icon(_def.icon, size: 19, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    _def.label,
                    style: context.texts.titleMedium!.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${lib.of(_cat).length}',
                      style: context.texts.labelSmall!.copyWith(
                        color: scheme.onPrimary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.keyboard_arrow_down,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
        ),
      ),
    );
  }

  /// 分类下拉的一行(图标 + 名称 + 选中勾)。
  Widget _catMenuRow(
    ColorScheme scheme,
    IconData icon,
    String label,
    bool sel,
  ) => Row(
    children: [
      Icon(
        icon,
        size: 19,
        color: sel ? scheme.primary : scheme.onSurfaceVariant,
      ),
      const SizedBox(width: 12),
      Text(
        label,
        style: TextStyle(fontWeight: sel ? FontWeight.w700 : FontWeight.w500),
      ),
      const Spacer(),
      if (sel) Icon(Icons.check, size: 16, color: scheme.primary),
    ],
  );

  /// 当前模型筛选的显示名;null = 全部。
  String? get _modelFilterLabel {
    final f = _modelFilter;
    if (f == null) return null;
    if (f == kGenericModelFilter) return kGenericModelLabel;
    for (final g in ArtistModelGroup.values) {
      if (g.name == f) return g.filterLabel;
    }
    return null;
  }

  /// 作者的显示名:查得到昵称就显示昵称,查不到就是那串 QQ 号。
  String _authorLabel(String id) => _isExternal ? id : _authorNames[id] ?? id;

  /// 漏斗里的两维有没有在筛(空列表的说法要跟着变:是"没匹配上"而不是"库是空的")。
  bool get _narrowed => _authorFilter != null || _modelFilter != null;

  /// 药丸上的字;null = 没在筛。两维都筛着就并排写 ——「有没有在筛、筛的哪一档」
  /// 得一眼看见,否则会出现"我的串怎么少了"。
  String? get _filterPillLabel {
    final parts = [
      if (_authorFilter != null) _authorLabel(_authorFilter!),
      ?_modelFilterLabel,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// 搜索框右侧的筛选入口:没筛时是个漏斗图标,筛着时变成带 × 的药丸。
  Widget _filterButton(ColorScheme scheme, BuildContext anchor) {
    final label = _filterPillLabel;
    if (label == null) {
      return IconButton(
        tooltip: l10nNow.filter,
        visualDensity: VisualDensity.compact,
        icon: Icon(
          Icons.filter_alt_outlined,
          size: 20,
          color: scheme.onSurfaceVariant,
        ),
        onPressed: () => _pickFilters(anchor),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 昵称可长可短,药丸宽度封顶在 suffixIconConstraints,超了就截断
            Flexible(
              child: InkWell(
                onTap: () => _pickFilters(anchor),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.labelMedium!.copyWith(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
            InkWell(
              onTap: () => setState(() {
                _authorFilter = null;
                _modelFilter = null;
              }),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(2, 5, 8, 5),
                child: Icon(Icons.close, size: 15, color: scheme.onPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFilters(BuildContext anchor) async {
    // 候选作者只从**当前 scope 里真有的条目**上点:公共 tab 数公共库、我的 tab
    // 数我的那些,免得补全里列出一串在这个列表里根本搜不到的人。
    final lib = ref.read(tagLibraryProvider).value ?? const TagLibraryState();
    final matchAny = ref.read(themeSettingsProvider).inspirationMatchAnyTag;
    final filter = _validFilter(lib);
    final search = _search;
    late final List<TagAuthor> authors;
    Future<int> Function(String author)? loadCount;
    if (_isExternal) {
      final favorites = ref.read(ocFavoritesProvider);
      final repository = ref.read(ocRepositoryProvider);
      final items = matchingOcCharacters(
        _activeSources,
        search: search,
        author: null,
        filter: filter,
        matchAny: matchAny,
        favorites: favorites,
        tagOverrides: lib.externalTags,
      );
      final groups = <String, List<OcBrowseItem>>{};
      for (final item in items) {
        final name = item.character.author;
        if (name.isNotEmpty) (groups[name] ??= []).add(item);
      }
      final names = groups.keys.toList()
        ..sort((a, b) => groups[b]!.length.compareTo(groups[a]!.length));
      authors = [for (final name in names) TagAuthor(id: name)];
      loadCount = (author) => countMatchingOcCards(
        groups[author]!,
        repository,
        search: search,
        filter: filter,
        matchAny: matchAny,
        favorites: favorites,
        tagOverrides: lib.externalTags,
      );
    } else {
      final pub = widget.manageBlocks
          ? ref.read(publicTagsProvider(_cat)).value
          : ref.read(visiblePublicTagsProvider(_cat)).value;
      final entries = _tabIndex == 1 && _def.hasPublic
          ? _publicCandidates(pub ?? const [], lib, matchAny)
          : _mineCandidates(
              _def.hasPublic
                  ? mergeMineTags(
                      lib.of(_cat),
                      ref.read(botSessionProvider).value?.botUserId,
                      pub,
                    )
                  : lib.of(_cat),
              search.trim().toLowerCase(),
              filter,
              matchAny,
            );
      authors = collectTagAuthors(entries, _authorNames);
    }
    final picked = await showTagFilterSheet(
      anchor,
      desktop: ref.read(desktopModeProvider),
      authors: authors,
      loadCount: loadCount,
      current: (author: _authorFilter, model: _modelFilter),
      // 适用模型只有画风有;角色那张表就少这一节。
      hasModels: _cat == TagCategory.artist,
    );
    if (!mounted || picked == null) return; // null = 点外面关掉,不改
    setState(() {
      _authorFilter = picked.author;
      _modelFilter = picked.model;
    });
  }

  void _setFilterTags(Set<String> tags) {
    if (mounted) setState(() => _filter = _filter.withTags(tags));
  }

  Widget _filterChips(TagLibraryState lib) {
    final tags = _tagPool(lib);
    final filter = _validFilter(lib);
    void apply(InspirationTagFilter value) => setState(() => _filter = value);
    if (!ref.watch(desktopModeProvider)) {
      return TagFilterChips(
        tags: tags,
        filter: filter,
        onChanged: apply,
        onManageTags: () => showTagPoolSheet(context, ref, _cat),
      );
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _desktopLibrary ? 0 : _kEdge),
      child: DesktopTagFilterBar(
        key: ValueKey('inspiration-tag-filters-${_cat.name}'),
        tags: tags,
        filter: filter,
        onChanged: apply,
        onManage: !_isExternal
            ? (anchor) => showTagPoolSheet(anchor, ref, _cat)
            : null,
      ),
    );
  }

  // ---- 我的 / 公共库 ----

  Widget _mineTab(TagLibraryState lib) {
    final list = _mineList(lib);
    if (list.isEmpty) {
      return _empty(
        _search.isNotEmpty || _validFilter(lib).active || _narrowed
            ? '没有匹配的${_def.label}'
            : '还没有${_def.label},点右上角 + 新建',
      );
    }
    // 按作者排序:整个 scope 改成一个作者一栏(我的这边同理 —— 自建的归自己
    // 那栏,收藏来的归原作者,「我收藏了谁的东西」一眼能看出来)
    if (_sortMode == TagSort.author) {
      final groups = _authorGroups(list);
      return _railWrap(groups, _mineScroll, _grid(groups, _mineScroll, false));
    }
    // 自建/我发布的在上,公共库收藏来的单独一组在下(对齐 web)
    final mine = [
      for (final e in list)
        if (e.origin != TagOrigin.favorited || !e.isFavorite) e,
    ];
    final fav = [
      for (final e in list)
        if (e.origin == TagOrigin.favorited && e.isFavorite) e,
    ];
    final groups = <_Group>[
      if (mine.isNotEmpty)
        (
          header: _sectionHeader(
            Icons.favorite,
            '我的${_def.label}',
            mine.length,
          ),
          items: mine,
        ),
      if (fav.isNotEmpty)
        (
          header: _sectionHeader(
            Icons.star_rounded,
            '收藏的${_def.label}',
            fav.length,
            muted: true,
          ),
          items: fav,
        ),
    ];
    return _railWrap(groups, _mineScroll, _grid(groups, _mineScroll, false));
  }

  Widget _publicTab(TagLibraryState lib) {
    final async = widget.manageBlocks
        ? ref.watch(publicTagsProvider(_cat))
        : ref.watch(visiblePublicTagsProvider(_cat));
    // 骨架 → 内容之间淡入淡出,不硬切
    return AnimatedSwitcher(
      duration: Motion.medium,
      child: KeyedSubtree(
        key: ValueKey(
          async.isLoading
              ? 'sk'
              : async.hasError
              ? 'err'
              : 'data',
        ),
        child: _publicContent(async, lib),
      ),
    );
  }

  Widget _publicContent(AsyncValue<List<TagEntry>> async, TagLibraryState lib) {
    return async.when(
      loading: () => pinchBuilder(
        (_) => ref.read(desktopModeProvider)
            ? LayoutBuilder(
                builder: (context, bounds) {
                  final library = _desktopLibrary;
                  final cols = library
                      ? _desktopColumns(bounds.maxWidth)
                      : gridColumns;
                  final edge = library ? _desktopEdge : _kEdge;
                  final gap = library ? _desktopGap : _gap;
                  final width =
                      (bounds.maxWidth - 2 * edge - gap * (cols - 1)) / cols;
                  return _SkeletonGrid(
                    aspect: _cardAspect,
                    cols: cols,
                    edge: edge,
                    gap: gap,
                    mainAxisExtent: InspirationEntryCard.extent(
                      _def,
                      width,
                      MediaQuery.textScalerOf(context),
                    ),
                  );
                },
              )
            : _SkeletonGrid(aspect: _cardAspect, cols: gridColumns),
      ),
      error: (e, _) {
        // 会话过期后端回 401/403,与无会话同样给「去授权」出口,
        // 别让人困在「重试永远失败」里。
        final needBot =
            (e is StateError && e.message == 'need-bot') ||
            (e is BackendException && (e.status == 401 || e.status == 403));
        if (needBot) {
          return _empty(
            '公共库需要 Bot 授权',
            action: (
              '去授权',
              () {
                if (widget.manageBlocks) {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute(builder: (_) => const BotAuthPage()),
                  );
                } else {
                  ref.read(shellIndexProvider.notifier).select(kTabProfile);
                }
              },
            ),
          );
        }
        return _empty('公共库加载失败', action: ('重试', _reloadPublic));
      },
      data: (all) {
        final list = _publicList(all, lib);
        if (list.isEmpty) {
          return RefreshIndicator(
            onRefresh: () async => _reloadPublic(),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(
                  height: 320,
                  child: _empty(
                    _search.isNotEmpty ||
                            _narrowed ||
                            (ref.read(desktopModeProvider) &&
                                _validFilter(lib).active)
                        ? '没有匹配的${_def.label}'
                        : '公共库暂无内容',
                  ),
                ),
              ],
            ),
          );
        }
        final groups = _sortMode == TagSort.author
            ? _authorGroups(list)
            : <_Group>[
                (
                  header: _sectionHeader(
                    Icons.public,
                    '公共${_def.label}',
                    list.length,
                  ),
                  items: list,
                ),
              ];
        return RefreshIndicator(
          onRefresh: () async => _reloadPublic(),
          child: _railWrap(groups, _pubScroll, _grid(groups, _pubScroll, true)),
        );
      },
    );
  }

  /// 下拉刷新 / 重试:公共库和作者目录一起重来 —— 只刷条目的话,新作者的
  /// 昵称要等下次冷启动才补得上,列表里会先冒出一串光秃秃的 QQ 号。
  void _reloadPublic() {
    ref.invalidate(publicTagsProvider(_cat));
    ref.invalidate(tagAuthorNamesProvider);
  }

  /// 按作者切组:一个作者一栏,条目多的在前;没署名的老数据兜底成「未认领」
  /// 收在最后(对齐 web 的分组画廊)。标题写成 `昵称(QQ 号)`。
  List<_Group> _authorGroups(List<TagEntry> list) {
    final byAuthor = <String, List<TagEntry>>{};
    final unclaimed = <TagEntry>[];
    for (final e in list) {
      final id = e.createdBy?.trim();
      if (id == null || id.isEmpty) {
        unclaimed.add(e);
      } else {
        (byAuthor[id] ??= []).add(e);
      }
    }
    final partiallyBlocked = <String?>{
      if (widget.manageBlocks)
        for (final entry
            in ref.read(publicTagsProvider(_cat)).value ?? const <TagEntry>[])
          if (_blockRule.hides(entry)) entry.createdBy?.trim(),
    };
    final ids = byAuthor.keys.toList()
      ..sort((a, b) {
        final c = byAuthor[b]!.length.compareTo(byAuthor[a]!.length);
        return c != 0 ? c : _authorLabel(a).compareTo(_authorLabel(b));
      });
    return [
      for (final id in ids)
        (
          header: _sectionHeader(
            Icons.account_circle_outlined,
            authorDisplay(id, _authorNames),
            byAuthor[id]!.length,
            action: widget.manageBlocks
                ? _blockAuthorButton(id, partiallyBlocked.contains(id))
                : null,
          ),
          items: byAuthor[id]!,
        ),
      if (unclaimed.isNotEmpty)
        (
          header: _sectionHeader(
            Icons.no_accounts_outlined,
            '未认领',
            unclaimed.length,
            muted: true,
          ),
          items: unclaimed,
        ),
    ];
  }

  Widget _blockAuthorButton(String author, bool hasBlockedItems) {
    final rule = _blockRule;
    final all = rule.authors[author]?.isEmpty == true;
    final partial =
        !all && (rule.authors.containsKey(author) || hasBlockedItems);
    return Semantics(
      checked: all,
      mixed: partial,
      child: IconButton(
        key: ValueKey('block-author-$author'),
        tooltip: context.l10n.blockPublicAuthor,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        onPressed: () {
          final catalog = ref.read(publicTagsProvider(_cat)).requireValue;
          setState(
            () => _blockDraft[_cat] = _blockRule.selectAuthor(
              author,
              catalog,
              !all,
            ),
          );
        },
        icon: Icon(
          all
              ? Icons.check_circle
              : partial
              ? Icons.remove_circle_outline
              : Icons.radio_button_unchecked,
          size: 21,
        ),
      ),
    );
  }

  Widget _sectionHeader(
    IconData icon,
    String label,
    int count, {
    bool muted = false,
    Widget? action,
  }) {
    final scheme = context.scheme;
    final color = muted ? scheme.onSurfaceVariant : scheme.primary;
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          // 作者栏的标题是 `昵称(QQ 号)`,可以很长:截断,别把分隔线顶出行外
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.labelLarge!.copyWith(
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: context.texts.labelMedium!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          ?action,
          const SizedBox(width: 10),
          Expanded(child: Divider(color: scheme.outlineVariant, height: 1)),
        ],
      ),
    );
  }

  Widget _empty(String text, {(String, VoidCallback)? action}) {
    final scheme = context.scheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_def.icon, size: 44, color: scheme.outlineVariant),
          const SizedBox(height: 10),
          Text(
            text,
            style: context.texts.bodyMedium!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: 10),
            FilledButton.tonal(onPressed: action.$2, child: Text(action.$1)),
          ],
        ],
      ),
    );
  }

  // ---- 网格 + 字母导航 ----

  static const _headerH = 32.0;
  static const _desktopEdge = 24.0;
  static const _desktopGap = 16.0;
  int _desktopColumns(double width) =>
      ((width - _desktopEdge * 2 + _desktopGap) / 230).floor().clamp(1, 10);

  /// 卡片 = 预览图比例:cover 下整图完整铺满、不裁切。
  double get _cardAspect => _def.hasPreview ? _def.previewAspect : 1.5;

  Widget _grid(List<_Group> groups, ScrollController ctrl, bool isPublic) {
    final pubPreview = ref.watch(tagCoverPreviewsProvider(_cat));
    // 分组、预览表在外面算好;捏合与过渡只重建下面这一块(见 pinchBuilder)
    return pinchBuilder(
      (_) => LayoutBuilder(
        builder: (context, constraints) {
          // 远端预览按**落定**列数下的格宽解码(gridColumns 在换档过渡中是起点那一档)。
          // 不给的话 RemoteImage 按实时格宽解码,过渡那几百毫秒里每一帧都是一路新解码。
          final desktop = ref.watch(desktopModeProvider);
          final library = desktop && !widget.embedded;
          _gridWidth = constraints.maxWidth;
          final cols = library
              ? _desktopColumns(constraints.maxWidth)
              : gridColumns;
          final edge = library ? _desktopEdge : _kEdge;
          final gap = library ? _desktopGap : _gap;
          final decodeW =
              (constraints.maxWidth - edge * 2 - gap * (cols - 1)) / cols;
          final grid = CustomScrollView(
            key: ValueKey(_scrollKey(_cat, isPublic)),
            controller: ctrl,
            physics: pinchPhysics(const AlwaysScrollableScrollPhysics()),
            slivers: [
              for (final g in groups) ...[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(edge, 2, edge, 0),
                  sliver: SliverToBoxAdapter(child: g.header),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(edge, 8, edge, 16),
                  sliver: SliverGrid(
                    gridDelegate: desktop
                        ? SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: cols,
                            mainAxisSpacing: gap,
                            crossAxisSpacing: gap,
                            mainAxisExtent: InspirationEntryCard.extent(
                              _def,
                              decodeW,
                              MediaQuery.textScalerOf(context),
                            ),
                            childAspectRatio: _cardAspect,
                          )
                        : zoomGridDelegate(
                            (n) => SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: n,
                              mainAxisSpacing: _gap,
                              crossAxisSpacing: _gap,
                              childAspectRatio: _cardAspect,
                            ),
                          ),
                    delegate: SliverChildBuilderDelegate((context, i) {
                      final e = g.items[i];
                      final preview = tagPreviewOf(e, pubPreview);
                      final masked =
                          isPublic &&
                          e.mosaic &&
                          !_revealed.contains(_revealKey(e));
                      void select() {
                        if (widget.manageBlocks) {
                          setState(
                            () => _blockDraft[_cat] = _blockRule.selectItems([
                              e,
                            ], !_blockRule.hides(e)),
                          );
                        } else if (masked) {
                          setState(() => _revealed.add(_revealKey(e)));
                        } else {
                          _toggle(e);
                        }
                      }

                      if (desktop) {
                        return MetaData(
                          key: ValueKey('drag-entry-${e.id}'),
                          metaData: e.id,
                          behavior: HitTestBehavior.translucent,
                          child: InspirationEntryCard(
                            key: ValueKey(e.id),
                            entry: e,
                            preview: preview,
                            width: decodeW,
                            masked: masked,
                            selected: widget.manageBlocks
                                ? _blockRule.hides(e)
                                : _sel.contains(e.id),
                            onSelect: select,
                            onReveal: () =>
                                setState(() => _revealed.add(_revealKey(e))),
                            onSecondaryTapDown: library && !widget.manageBlocks
                                ? (details) => _showSelectionMenu(
                                    details.globalPosition,
                                    e,
                                  )
                                : null,
                            onFavorite: widget.manageBlocks
                                ? null
                                : () => _toggleFavorite(e, isPublic),
                            onMenu: widget.manageBlocks
                                ? null
                                : (action) => _entryMenu(
                                    action,
                                    e,
                                    isPublic,
                                    groups,
                                    pubPreview,
                                  ),
                          ),
                        );
                      }
                      return _TagCard(
                        key: ValueKey(e.id),
                        entry: e,
                        mosaic: masked,
                        previewUrl: preview,
                        decodeWidth: decodeW,
                        selected: _sel.contains(e.id),
                        isPublic: isPublic,
                        collected:
                            isPublic &&
                            ref
                                .read(tagLibraryProvider.notifier)
                                .isCollected(
                                  _cat,
                                  publicId: e.publicId,
                                  name: e.name,
                                ),
                        onTap: select,
                        onLongPress: () => showTagDetailSheet(context, e),
                        onCollect: isPublic ? () => _collect(e) : null,
                        onMenu: isPublic ? null : (v) => _cardMenu(v, e),
                      );
                    }, childCount: g.items.length),
                  ),
                ),
              ],
            ],
          );
          if (!desktop) return grid;
          final entries = [for (final group in groups) ...group.items];
          return GalleryDragSelection(
            key: ValueKey('drag-${_scrollKey(_cat, isPublic)}'),
            enabled: true,
            mouseOnly: true,
            scrollController: ctrl,
            order: [for (final e in entries) e.id],
            maxSelected: widget.manageBlocks ? null : _selectionLimit,
            selected: widget.manageBlocks
                ? {
                    for (final e in entries)
                      if (_blockRule.hides(e)) e.id,
                  }
                : _sel,
            onChanged: (next) => setState(() {
              if (widget.manageBlocks) {
                final rule = _blockRule;
                final changed = entries
                    .where((e) => rule.hides(e) != next.contains(e.id))
                    .toList();
                _blockDraft[_cat] = rule
                    .selectItems(
                      changed.where((e) => next.contains(e.id)),
                      true,
                    )
                    .selectItems(
                      changed.where((e) => !next.contains(e.id)),
                      false,
                    );
              } else {
                _selected[_cat] = next;
              }
            }),
            child: grid,
          );
        },
      ),
    );
  }

  /// 画风分类包一层右缘字母导航。**只在按编号排时**有:换成时间/作者以后
  /// 列表不再是字母序,字母条跳过去就是错位。
  Widget _railWrap(List<_Group> groups, ScrollController ctrl, Widget child) {
    final total = groups.fold(0, (n, g) => n + g.items.length);
    if (!_def.alphabetRail || _sortMode != TagSort.number || total < 12) {
      return child;
    }
    // 用 Set 去重:'#' 桶(数字开头排最前、CJK 排最后)可能不相邻,
    // 只留首次出现,跳转恒到首个。
    final seen = <String>{};
    final letters = <String>[
      for (final g in groups)
        for (final e in g.items)
          if (seen.add(letterOfName(e.name))) letterOfName(e.name),
    ];
    return Stack(
      children: [
        child,
        Positioned(
          right: 4,
          top: 0,
          bottom: 0,
          child: _LetterRail(
            letters: letters,
            onSelect: (l) => _jumpToLetter(groups, ctrl, l),
          ),
        ),
      ],
    );
  }

  void _jumpToLetter(List<_Group> groups, ScrollController ctrl, String l) {
    if (!ctrl.hasClients) return;
    final library = _desktopLibrary;
    final cols = library ? _desktopColumns(_gridWidth) : gridColumns;
    final edge = library ? _desktopEdge : _kEdge;
    final rowGap = library ? _desktopGap : _gap;
    final itemW = (_gridWidth - edge * 2 - rowGap * (cols - 1)) / cols;
    final rowExtent =
        rowGap +
        (ref.read(desktopModeProvider)
            ? InspirationEntryCard.extent(
                _def,
                itemW,
                MediaQuery.textScalerOf(context),
              )
            : itemW / _cardAspect);
    // 逐组累加(组头 + 该组行高),命中组内再按行偏移
    var offset = 0.0;
    for (final g in groups) {
      final i = g.items.indexWhere((e) => letterOfName(e.name) == l);
      final rows = (g.items.length + cols - 1) ~/ cols;
      if (i >= 0) {
        offset += 2 + _headerH + 8 + (i ~/ cols) * rowExtent;
        ctrl.jumpTo(offset.clamp(0.0, ctrl.position.maxScrollExtent));
        return;
      }
      offset +=
          2 + _headerH + 8 + rows * rowExtent - (rows > 0 ? rowGap : 0) + 16;
    }
  }

  TagEntry _editableEntry(TagEntry entry, bool publicScope) {
    final library = ref.read(tagLibraryProvider).requireValue;
    if (!publicScope) {
      return library.entries.where((e) => e.id == entry.id).firstOrNull ??
          entry;
    }
    final copy = library.publicCopyLookup(entry.category)(entry);
    if (copy != null) {
      return copy.publicId == null
          ? copy.copyWith(publicId: entry.publicId)
          : copy;
    }
    final owner = ref.read(botSessionProvider).value?.botUserId;
    final owned = owner != null && entry.createdBy == owner;
    return entry.copyWith(
      id: owned ? entry.id : TagLibrary.newId(entry.category),
      origin: owned ? TagOrigin.created : TagOrigin.favorited,
      favorite: false,
      mosaic: false,
    );
  }

  Future<void> _toggleFavorite(TagEntry entry, bool publicScope) async {
    if (!ref.read(tagLibraryProvider).hasValue) {
      await ref.read(tagLibraryProvider.future);
      if (!mounted) return;
    }
    final local = _editableEntry(entry, publicScope);
    await ref
        .read(tagLibraryProvider.notifier)
        .upsert(local.copyWith(favorite: !local.isFavorite));
  }

  Future<void> _entryMenu(
    InspirationEntryAction action,
    TagEntry entry,
    bool publicScope,
    List<_Group> groups,
    Map<String, String> previews,
  ) async {
    switch (action) {
      case InspirationEntryAction.edit:
        if (!ref.read(tagLibraryProvider).hasValue) {
          await ref.read(tagLibraryProvider.future);
          if (!mounted) return;
        }
        await showTagEditor(
          context,
          cat: entry.category,
          edit: _editableEntry(entry, publicScope),
        );
      case InspirationEntryAction.copy:
        await _cardMenu('copy', entry);
      case InspirationEntryAction.view:
        final chosen = await showDialog<TagEntry>(
          context: context,
          requestFocus: true,
          builder: (_) => InspirationPromptDialog(
            entries: [for (final group in groups) ...group.items],
            initialEntry: entry,
            selected: _sel,
            categoryLabel: tagCategoryDef(entry.category).label,
            scope: publicScope ? l10nNow.publicLibrary : l10nNow.scopeMine,
            previewOf: (e) => tagPreviewOf(e, previews),
            isMasked: (e) =>
                publicScope && e.mosaic && !_revealed.contains(_revealKey(e)),
            reveal: (e) => setState(() => _revealed.add(_revealKey(e))),
          ),
        );
        if (mounted && chosen != null) _toggle(chosen);
    }
  }

  Future<void> _collect(TagEntry e) async {
    final ok = await ref.read(tagLibraryProvider.notifier).collect(e);
    if (!mounted) return;
    hintSnack(
      context,
      ok ? '已收藏到「我的」' : '已经收藏过了',
      icon: ok ? Icons.favorite : Icons.info_outline,
    );
  }

  // ---- 批量操作(底栏第一层) ----

  Future<void> _runBatch(Future<void> Function() op) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await op();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 批量贴标签:选一个标签(可现场新建)并入所有选中条目。
  Future<void> _batchTag(TagLibraryState lib) async {
    final entries = _resolveSelected(lib);
    if (entries.isEmpty) return;
    final tag = await pickTagSheet(context, ref, _cat);
    if (tag == null || !mounted) return;
    await _runBatch(() async {
      final notifier = ref.read(tagLibraryProvider.notifier);
      await notifier.addPoolTag(_cat, tag);
      var n = 0;
      for (final e in entries) {
        if (e.tags.contains(tag)) continue;
        await notifier.upsert(e.copyWith(tags: [...e.tags, tag]..sort()));
        n++;
      }
      if (mounted) {
        hintSnack(context, '已给 $n 项加上「$tag」', icon: Icons.sell_outlined);
      }
    });
  }

  Future<void> _batchDelete(TagLibraryState lib) =>
      _deleteEntries(_resolveSelected(lib));

  /// 删除条目:已发布的(created + publicId)连同公共库条目一并删。
  ///
  /// 卡片菜单和多选底栏走同一条 —— 早先卡片菜单只删本地、文案还恒写「仅删除
  /// 本地条目」,已发布的条目从库里消失、公共库那份却还挂着,之后连管理入口
  /// 都没有了。
  Future<void> _deleteEntries(List<TagEntry> entries) async {
    if (entries.isEmpty) return;
    // 三种来源三种后果(对齐 web 桌面端管理器的单卡菜单):
    //   created  发布过的 → 公共库条目 + 本地副本一起删
    //   favorited 收藏来的 → 只丢自己这份副本,公共库原作不动
    //   local     纯本地的 → 就是删本地
    final published = [
      for (final e in entries)
        if (e.origin == TagOrigin.created && e.publicId != null) e,
    ];
    final favorited = [
      for (final e in entries)
        if (e.origin == TagOrigin.favorited) e,
    ];
    final localOnly = entries.length - published.length - favorited.length;
    final one = entries.length == 1 ? entries.first : null;

    final String title, message;
    if (one != null) {
      if (published.isNotEmpty) {
        title = '删除「${one.name}」?';
        message = '将彻底删除公共库条目与本地副本,不可恢复。';
      } else if (favorited.isNotEmpty) {
        title = '删除收藏?';
        message = '将从本地移除「${one.name}」,公共库原作不受影响。';
      } else {
        title = '删除「${one.name}」?';
        message = '仅删除本地条目,不可恢复。';
      }
    } else {
      title = '删除 ${entries.length} 项?';
      final lines = [
        if (published.isNotEmpty) '· 你发布的 ${published.length} 项:连同公共库条目一起删',
        if (favorited.isNotEmpty) '· 收藏的 ${favorited.length} 项:只移除本地副本,原作不动',
        if (localOnly > 0) '· 本地的 $localOnly 项:仅删除本地',
      ];
      message = '${lines.join('\n')}\n\n不可恢复。';
    }
    final ok = await confirmDialog(
      context,
      title: title,
      message: message,
      confirmLabel: '删除',
    );
    if (!ok || !mounted) return;
    await _runBatch(() async {
      final notifier = ref.read(tagLibraryProvider.notifier);
      final client = ref.read(backendClientProvider);
      final session = ref.read(botSessionProvider).value;
      var done = 0, failed = 0;
      for (final e in entries) {
        try {
          if (e.origin == TagOrigin.created &&
              e.publicId != null &&
              session != null) {
            try {
              if (_cat == TagCategory.character) {
                await client.deletePublicOc(session.sessionId, e.publicId!);
              } else {
                await client.deletePublicArtist(session.sessionId, e.publicId!);
              }
            } on BackendException catch (e) {
              if (e.status != 404) rethrow;
            }
          }
          await notifier.remove(e.id);
          done++;
        } catch (_) {
          failed++;
        }
      }
      if (published.isNotEmpty) ref.invalidate(publicTagsProvider(_cat));
      if (!mounted) return;
      setState(() => _sel.clear());
      hintSnack(
        context,
        failed > 0
            ? '已删除 $done 项,$failed 项失败'
            : (one != null ? '已删除' : '已删除 $done 项'),
        icon: Icons.delete_outline,
      );
    });
  }

  /// 批量收藏(公共库 scope)。
  Future<void> _batchCollect(TagLibraryState lib) async {
    final entries = _resolveSelected(lib);
    if (entries.isEmpty) return;
    await _runBatch(() async {
      final notifier = ref.read(tagLibraryProvider.notifier);
      var added = 0;
      for (final e in entries) {
        if (await notifier.collect(e)) added++;
      }
      if (!mounted) return;
      setState(() => _sel.clear());
      hintSnack(
        context,
        added == entries.length ? '已收藏 $added 项' : '已收藏 $added 项(其余已在库中)',
        icon: Icons.favorite,
      );
    });
  }

  Future<void> _cardMenu(String action, TagEntry e) async {
    switch (action) {
      case 'edit':
        unawaited(showTagEditor(context, cat: _cat, edit: e));
      case 'copy':
        await Clipboard.setData(ClipboardData(text: e.positive));
        if (mounted) hintSnack(context, l10nNow.promptCopied, icon: Icons.copy);
      case 'delete':
        await _deleteEntries([e]);
    }
  }

  // ---- 底部操作条 ----

  List<PopupMenuEntry<String>> _desktopSelectionItems() {
    final model = ref.read(generateProvider).params.model;
    final modules =
        ref.read(genModulesProvider).value ?? const GenModuleSettings();
    final public = _def.hasPublic && _tabIndex == 1;
    return [
      PopupMenuItem(enabled: false, child: Text('已选择 ${_sel.length} 项')),
      const PopupMenuDivider(),
      const PopupMenuItem(
        value: 'prompt',
        child: _MenuRow(Icons.bolt_outlined, '主提示词'),
      ),
      if (_cat == TagCategory.character &&
          modules.isVisibleFor(GenModule.character, model))
        const PopupMenuItem(
          value: 'characters',
          child: _MenuRow(Icons.person_add_alt, '加入角色'),
        ),
      if (public)
        const PopupMenuItem(
          value: 'collect',
          child: _MenuRow(Icons.favorite_border, '收藏'),
        )
      else ...[
        const PopupMenuItem(
          value: 'tags',
          child: _MenuRow(Icons.sell_outlined, '标签'),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: _MenuRow(Icons.delete_outline, '删除', danger: true),
        ),
      ],
      const PopupMenuDivider(),
      const PopupMenuItem(
        value: 'clear',
        child: _MenuRow(Icons.deselect, '取消选择'),
      ),
    ];
  }

  Future<void> _desktopSelectionAction(String action) async {
    if (_busy) return;
    final lib = ref.read(tagLibraryProvider).value;
    if (lib == null) return;
    switch (action) {
      case 'prompt':
        await _confirmToPrompt(lib);
      case 'characters':
        await _confirmAsCharacters(lib);
      case 'collect':
        await _batchCollect(lib);
      case 'tags':
        await _batchTag(lib);
      case 'delete':
        await _batchDelete(lib);
      case 'clear':
        setState(() => _sel.clear());
    }
  }

  Future<void> _showSelectionMenu(Offset position, TagEntry entry) async {
    if (_busy) return;
    // Right-clicking a selected card keeps the whole selection. A different
    // card becomes the new selection, matching desktop file browsers.
    if (!_sel.contains(entry.id)) {
      setState(() {
        _sel
          ..clear()
          ..add(entry.id);
      });
    }
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(position);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(point.dx, point.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: _desktopSelectionItems(),
    );
    if (mounted && action != null) await _desktopSelectionAction(action);
  }

  Widget _desktopSelectionBar(TagLibraryState lib) =>
      DesktopInspirationSelectionBar(
        count: _sel.length,
        busy: _busy,
        onPrompt: () => _confirmToPrompt(lib),
        onCharacters: _cat == TagCategory.character && _charModuleOn
            ? () => _confirmAsCharacters(lib)
            : null,
        onClear: () => setState(_sel.clear),
        menu: PopupMenuButton<String>(
          key: const ValueKey('inspiration-selection-menu'),
          tooltip: l10nNow.desktopBatchActionsOrRightClickACard,
          enabled: !_busy,
          onSelected: _desktopSelectionAction,
          itemBuilder: (_) => _desktopSelectionItems(),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10nNow.desktopMoreActions),
                SizedBox(width: 4),
                Icon(Icons.expand_more, size: 18),
              ],
            ),
          ),
        ),
      );

  /// 角色模块对当前模型是否可见 —— 决定「加入角色」这个去处存不存在。
  /// anima 下 NAI 四件套整组收走(角色卡都不渲染),此时加进去的角色既不进
  /// 载荷也看不见,只会把提示词计数顶大,是个纯幽灵动作,故收起按钮。
  bool get _charModuleOn {
    final model = ref.watch(generateProvider.select((s) => s.params.model));
    final ms = ref.watch(genModulesProvider).value ?? const GenModuleSettings();
    return ms.isVisibleFor(GenModule.character, model);
  }

  Widget _selectionBar(ColorScheme scheme, TagLibraryState lib) {
    final n = _sel.length;
    final publicScope = _def.hasPublic && _tabIndex == 1;
    return SelectionBar(
      visible: n > 0,
      // shell 里的 tab 页,底部安全区由导航栏兜着
      safeArea: false,
      onClear: () => setState(() => _sel.clear()),
      actions: [
        if (publicScope && !widget.embedded)
          SelectionPill(
            icon: Icons.favorite_border,
            label: l10nNow.favorites,
            onTap: _busy ? null : () => _batchCollect(lib),
          ),
        if (!publicScope)
          SelectionPill(
            icon: Icons.sell_outlined,
            label: l10nNow.tagLabel,
            onTap: _busy ? null : () => _batchTag(lib),
          ),
      ],
      destructive: publicScope
          ? null
          : SelectionPill(
              icon: Icons.delete_outline,
              label: l10nNow.delete,
              color: scheme.error,
              onTap: _busy ? null : () => _batchDelete(lib),
            ),
      // 角色分类有两个去处,主动作是一体式分段按钮;角色模块不可见时
      // (anima 等)只剩「主提示词」一个去处,退回普通整条按钮
      primary: InspirationApplyActions(
        count: n,
        busy: _busy,
        onPrompt: () => _confirmToPrompt(lib),
        onCharacters: _cat == TagCategory.character && _charModuleOn
            ? () => _confirmAsCharacters(lib)
            : null,
      ),
    );
  }
}

// ---- 卡片 ----

/// 公共库加载态:骨架网格(卡片形状 + 呼吸微光),比干等一个转圈更有"内容在来"。
class _SkeletonGrid extends StatefulWidget {
  const _SkeletonGrid({
    required this.aspect,
    required this.cols,
    this.mainAxisExtent,
    this.edge = _kEdge,
    this.gap = _gap,
  });

  final double aspect;
  final int cols;
  final double? mainAxisExtent;
  final double edge, gap;

  @override
  State<_SkeletonGrid> createState() => _SkeletonGridState();
}

class _SkeletonGridState extends State<_SkeletonGrid>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return GridView(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: widget.cols,
        mainAxisSpacing: widget.gap,
        crossAxisSpacing: widget.gap,
        childAspectRatio: widget.aspect,
        mainAxisExtent: widget.mainAxisExtent,
      ),
      padding: EdgeInsets.fromLTRB(widget.edge, 42, widget.edge, 16),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var i = 0; i < widget.cols * 3; i++)
          FadeTransition(
            opacity: Tween(
              begin: .35,
              end: .7,
            ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
      ],
    );
  }
}

/// 卡片预览图:无图 = 名称定色相的斜纹占位;http 走磁盘缓存;本机路径直读。
/// 加载完淡入,让预览逐张柔和显现而非硬蹦(只淡第一次,见 [FadeInOnce])。
class _CardPreview extends StatelessWidget {
  const _CardPreview({
    required this.url,
    required this.name,
    this.decodeWidth,
    this.mosaic = false,
  });

  final String? url;
  final String name;
  final bool mosaic;

  /// 远端图的解码宽(逻辑像素);null = 按布局宽。
  final double? decodeWidth;

  Widget _stripes(BuildContext context, Object error, StackTrace? stack) =>
      _HueStripes(name: name);

  @override
  Widget build(BuildContext context) => switch (url) {
    null => _HueStripes(name: name),
    final u => FadeInOnce(
      source: u,
      builder: (_, frame) => u.startsWith('http')
          ? RemoteImage(
              u,
              fit: BoxFit.cover,
              decodeWidth: mosaic
                  ? 12 / MediaQuery.devicePixelRatioOf(context)
                  : decodeWidth,
              filterQuality: mosaic ? FilterQuality.none : FilterQuality.medium,
              gaplessPlayback: true,
              frameBuilder: frame,
              errorBuilder: _stripes,
            )
          : Image.file(
              File(u),
              cacheWidth: mosaic ? 12 : null,
              filterQuality: mosaic ? FilterQuality.none : FilterQuality.medium,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              frameBuilder: frame,
              errorBuilder: _stripes,
            ),
    ),
  };
}

/// 网格卡:预览图(无图=名称定色相的斜纹占位)+ 底部名称条 + 来源角标;
/// 左上选择圈,右上 ⋮(我的)/ ❤ 收藏(公共)。点卡选择,长按看详情。
class _TagCard extends StatelessWidget {
  const _TagCard({
    super.key,
    required this.entry,
    this.previewUrl,
    required this.selected,
    required this.isPublic,
    this.collected = false,
    required this.onTap,
    required this.onLongPress,
    this.onCollect,
    this.onMenu,
    this.decodeWidth,
    this.mosaic = false,
  });

  final TagEntry entry;
  final bool mosaic;

  /// 实际渲染的预览(可能是按 publicId 从公共库补的 http,覆盖 entry 自身)。
  final String? previewUrl;
  final bool selected;
  final bool isPublic;
  final bool collected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onCollect;
  final ValueChanged<String>? onMenu;

  /// 远端预览的解码宽(逻辑像素)。
  final double? decodeWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    // 捏到三四列以后卡片很小,角上两颗按钮和名字条照原尺寸画会把图盖满:收小
    // 一档,型号角标也收掉。按实测尺寸判,换档过渡途中越过门槛就换。
    builder: (context, c) =>
        _card(context, compact: c.maxWidth < 100 || c.maxHeight < 100),
  );

  Widget _mosaicHint(BuildContext context) => Center(
    child: Tooltip(
      message: l10nNow.desktopClickToShowOriginal,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: context.scheme.surface.withValues(alpha: .92),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.visibility_off_outlined, size: 20),
      ),
    ),
  );

  Widget _card(BuildContext context, {required bool compact}) {
    final scheme = context.scheme;
    final modelGroups = artistModelGroups(entry.models);
    // 角上两颗按钮的边长与离边距离
    final btn = compact ? 30.0 : 40.0;
    final inset = compact ? 4.0 : 6.0;
    return AnimatedContainer(
      duration: Motion.fast,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16)),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.8 : 1,
        ),
      ),
      child: Material(
        color: scheme.surfaceContainer,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (!tagCategoryDef(entry.category).hasPreview)
                TagTextPreview(text: entry.positive)
              else
                _CardPreview(
                  url: previewUrl,
                  name: entry.name,
                  decodeWidth: decodeWidth,
                  mosaic: mosaic,
                ),
              if (mosaic) _mosaicHint(context),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: compact
                      ? const EdgeInsets.fromLTRB(7, 10, 6, 5)
                      : const EdgeInsets.fromLTRB(10, 14, 8, 7),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: .62),
                      ],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 适用模型角标(按分档归并:标了 V5 Full + Curated 只出一个)。
                      // 没标注的不画 —— 「通用」是默认档,给每张卡都挂一个反而是噪音。
                      if (modelGroups.isNotEmpty && !compact) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final g in modelGroups.take(2))
                              Container(
                                margin: const EdgeInsets.only(right: 4),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: .22),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  g.label,
                                  style: const TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            if (modelGroups.length > 2)
                              Text(
                                '+${modelGroups.length - 2}',
                                style: const TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white70,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 3),
                      ],
                      Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: compact ? 11.5 : 13,
                          fontWeight: FontWeight.w800,
                          color: selected ? scheme.primary : Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: compact ? 5 : 7,
                left: compact ? 5 : 7,
                child: AnimatedContainer(
                  duration: Motion.fast,
                  width: compact ? 20 : 24,
                  height: compact ? 20 : 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected
                        ? scheme.primary
                        : Colors.black.withValues(alpha: .3),
                    border: selected
                        ? null
                        : Border.all(color: Colors.white70, width: 1.5),
                  ),
                  child: selected
                      ? Icon(
                          Icons.check,
                          size: compact ? 13 : 16,
                          color: scheme.onPrimary,
                        )
                      : null,
                ),
              ),
              // 公共卡:右上角收藏钮(40px 圆钮 + 半透明底,已收藏=实心红心);
              // 我的卡:右上角 ⋮ 菜单。
              if (isPublic)
                Positioned(
                  right: inset,
                  top: inset,
                  child: Material(
                    color: collected
                        ? Colors.white.withValues(alpha: .92)
                        : Colors.black.withValues(alpha: .42),
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: onCollect,
                      child: SizedBox(
                        width: btn,
                        height: btn,
                        child: Icon(
                          collected ? Icons.favorite : Icons.favorite_border,
                          size: compact ? 17 : 21,
                          color: collected ? scheme.error : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              if (!isPublic)
                Positioned(
                  right: inset,
                  top: inset,
                  child: Material(
                    color: Colors.black.withValues(alpha: .42),
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      width: btn,
                      height: btn,
                      child: PopupMenuButton<String>(
                        onSelected: onMenu,
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Icons.more_vert,
                          size: compact ? 17 : 20,
                          color: Colors.white,
                        ),
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'edit',
                            child: _MenuRow(Icons.edit_outlined, '编辑'),
                          ),
                          const PopupMenuItem(
                            value: 'copy',
                            child: _MenuRow(Icons.copy, '复制提示词'),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: _MenuRow(
                              Icons.delete_outline,
                              '删除',
                              danger: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label, {this.danger = false});

  final IconData icon;
  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = danger ? context.scheme.error : context.scheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: danger ? c : null)),
      ],
    );
  }
}

/// 无预览图的占位:名称哈希定色相的深色渐变 + 斜纹 + 名称水印
/// (对齐 web HorizontalCard 的 hashHue 占位,同名恒同色)。
class _HueStripes extends StatelessWidget {
  const _HueStripes({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    var h = 0;
    for (final c in name.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    final hue = (h % 360).toDouble();
    return CustomPaint(
      painter: _HueStripePainter(hue),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            name.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              letterSpacing: 4,
              color: Colors.white.withValues(alpha: .2),
            ),
          ),
        ),
      ),
    );
  }
}

class _HueStripePainter extends CustomPainter {
  const _HueStripePainter(this.hue);

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final a = HSLColor.fromAHSL(1, hue, .38, .20).toColor();
    final b = HSLColor.fromAHSL(1, (hue + 24) % 360, .42, .13).toColor();
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [a, b],
        ).createShader(Offset.zero & size),
    );
    final stripe = Paint()..color = Colors.black.withValues(alpha: .16);
    const w = 14.0;
    for (double x = -size.height; x < size.width; x += w * 2.4) {
      final path = Path()
        ..moveTo(x, size.height)
        ..lineTo(x + size.height, 0)
        ..lineTo(x + size.height + w, 0)
        ..lineTo(x + w, size.height)
        ..close();
      canvas.drawPath(path, stripe);
    }
  }

  @override
  bool shouldRepaint(covariant _HueStripePainter old) => old.hue != hue;
}

/// 右缘字母导航条(画风):按住/竖向拖动跳转到该字母首个条目,
/// 交互时左侧弹出当前字母气泡。触区即胶囊本身,不越界抢网格滚动。
class _LetterRail extends StatefulWidget {
  const _LetterRail({required this.letters, required this.onSelect});

  final List<String> letters;
  final ValueChanged<String> onSelect;

  @override
  State<_LetterRail> createState() => _LetterRailState();
}

class _LetterRailState extends State<_LetterRail>
    with SingleTickerProviderStateMixin {
  /// 胶囊 = 触摸宽度;气泡半径(高 46 的一半)。
  static const _railW = 24.0;
  static const _bubbleR = 23.0;

  final _key = GlobalKey();
  int _active = -1; // 当前命中字母下标;-1=未按住

  /// 交互显隐:按住 forward、松手 reverse。驱动胶囊加深、字母放大波、
  /// 气泡淡入淡出——让整条随手指"活"起来,而非硬切。
  late final AnimationController _reveal =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 130),
        reverseDuration: const Duration(milliseconds: 170),
      )..addStatusListener((s) {
        // 收完动画再清 _active,气泡/放大得以在原位平滑退场。
        if (s == AnimationStatus.dismissed && _active != -1) {
          setState(() => _active = -1);
        }
      });

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final n = widget.letters.length;
    return SizedBox(
      width: _railW,
      child: LayoutBuilder(
        builder: (context, c) {
          final h = c.maxHeight;
          const vPad = 10.0;
          // 字母多/屏矮时等比压缩槽高,band 竖向居中;命中与气泡都按同一几何算。
          final slot = n == 0 ? 0.0 : ((h - vPad * 2) / n).clamp(0.0, 22.0);
          final bandTop = (h - slot * n) / 2;

          void update(Offset global) {
            final box = _key.currentContext?.findRenderObject() as RenderBox?;
            if (box == null || n == 0 || slot <= 0) return;
            final dy = box.globalToLocal(global).dy;
            final i = ((dy - bandTop) / slot).floor().clamp(0, n - 1);
            if (i != _active) {
              Haptics.selection();
              widget.onSelect(widget.letters[i]);
              setState(() => _active = i);
            }
            _reveal.forward();
          }

          void stop() => _reveal.reverse();

          return GestureDetector(
            key: _key,
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => update(d.globalPosition),
            onTapUp: (_) => stop(),
            onTapCancel: stop,
            onVerticalDragStart: (d) => update(d.globalPosition),
            onVerticalDragUpdate: (d) => update(d.globalPosition),
            onVerticalDragEnd: (_) => stop(),
            onVerticalDragCancel: stop,
            child: AnimatedBuilder(
              animation: _reveal,
              builder: (context, _) {
                final r = _reveal.value; // 0=静默 1=按住
                final active = _active;
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // 字母条胶囊:常态半透明可见(可发现),按住渐深。
                    Positioned.fill(
                      child: Center(
                        child: Container(
                          width: _railW,
                          height: slot * n + vPad,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHigh.withValues(
                              alpha: .55 + .41 * r,
                            ),
                            borderRadius: BorderRadius.circular(_railW / 2),
                            border: Border.all(
                              color: scheme.outlineVariant.withValues(
                                alpha: .5 * (1 - r),
                              ),
                              width: .5,
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (var i = 0; i < n; i++)
                                SizedBox(
                                  height: slot,
                                  child: Center(
                                    child: _letter(i, active, r, scheme),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // 气泡:向左弹出当前字母,尾巴指向字母条;
                    // 竖向随命中槽滑动(AnimatedPositioned),按住/松手淡入淡出。
                    if (active >= 0 && active < n)
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 65),
                        curve: Curves.easeOut,
                        right: _railW + 6,
                        top: bandTop + (active + 0.5) * slot - _bubbleR,
                        child: Opacity(
                          opacity: r.clamp(0.0, 1.0),
                          child: Transform.scale(
                            scale:
                                .6 +
                                .4 *
                                    Curves.easeOutBack.transform(
                                      r.clamp(0.0, 1.0),
                                    ),
                            alignment: Alignment.centerRight,
                            child: _LetterBubble(
                              widget.letters[active],
                              color: scheme.primary,
                              fg: scheme.onPrimary,
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// 单个字母:离命中点越近越大越亮(放大波),幅度乘 [r] 让它随按住淡入淡出。
  Widget _letter(int i, int active, double r, ColorScheme scheme) {
    final dist = active < 0 ? 999.0 : (i - active).abs().toDouble();
    final prox = (1 - dist / 2.6).clamp(0.0, 1.0) * r; // 命中点 ±2~3 个字母的邻域
    return Transform.scale(
      scale: 1 + .5 * prox,
      child: Text(
        widget.letters[i],
        style: TextStyle(
          fontSize: 10.5,
          height: 1,
          fontWeight: FontWeight.w800,
          color: Color.lerp(scheme.onSurfaceVariant, scheme.primary, prox),
        ),
      ),
    );
  }
}

/// 字母气泡:圆形 + 右向小尾巴(指向字母条),软阴影浮起。
class _LetterBubble extends StatelessWidget {
  const _LetterBubble(this.letter, {required this.color, required this.fg});

  final String letter;
  final Color color;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BubblePainter(color),
      child: SizedBox(
        width: 54,
        height: 46,
        // 尾巴占右 8px,文字回退到圆心。
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Center(
            child: Text(
              letter,
              style: TextStyle(
                fontSize: 22,
                height: 1,
                fontWeight: FontWeight.w800,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BubblePainter extends CustomPainter {
  const _BubblePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.height / 2;
    final center = Offset(r, r);
    final body = Path()..addOval(Rect.fromCircle(center: center, radius: r));
    final tail = Path()
      ..moveTo(center.dx + r - 7, center.dy - 9)
      ..lineTo(size.width, center.dy)
      ..lineTo(center.dx + r - 7, center.dy + 9)
      ..close();
    final shape = Path.combine(PathOperation.union, body, tail);
    canvas.drawShadow(shape, Colors.black.withValues(alpha: .4), 4, false);
    canvas.drawPath(
      shape,
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant _BubblePainter old) => old.color != color;
}
