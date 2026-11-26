import '../../../l10n/l10n.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/platform/desktop.dart';
import '../../../core/store/ui_prefs.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/pinch_columns.dart';
import '../../../core/ui/scroll_memory.dart';
import '../../generate/widgets/common.dart' show hintSnack;
import '../widgets/desktop_inspiration_search.dart';
import 'codex_card.dart';
import 'codex_catalog.dart';
import 'codex_block.dart';
import 'codex_favorites.dart';
import 'codex_image_loading.dart';
import 'codex_masonry.dart';
import 'codex_models.dart';
import 'codex_providers.dart';
import 'codex_sheets.dart';
import 'codex_random_workspace.dart';

/// 法典浏览器:灵感页选中「法典」分类时的正文。
/// 顶部选法典 + 来源;下面搜索 + 顶级分类筛选 + 瀑布流(双指捏合换列数)。
/// 只读,点词条看详情。
class CodexView extends ConsumerStatefulWidget {
  const CodexView({
    super.key,
    this.desktop = false,
    this.embedded = false,
    this.desktopHeaderBuilder,
  });
  final bool desktop;
  final bool embedded;
  final Widget Function(Widget search)? desktopHeaderBuilder;

  @override
  ConsumerState<CodexView> createState() => _CodexViewState();
}

const _edge = 14.0;
const _gap = 10.0;

/// 瀑布流默认列数;捏合可在 1 ~ 4 列之间换。偏好里与标签库四类同表,键 `codex`。
const _kCols = 2;
const _kColsKey = 'codex';

class _CodexViewState extends ConsumerState<CodexView>
    with SingleTickerProviderStateMixin, PinchColumnsMixin {
  String _search = '';
  bool _favoritesOnly = false;
  bool _newOnly = false;
  final _searchFocus = FocusNode();
  bool _randomWorkspace = false;
  List<String> _catPath = const []; // 分类树选中路径(空=全部;前缀匹配词条 path)
  Timer? _debounce;
  bool _introScheduled = false; // 首次说明弹窗本会话是否已排期(防重复弹)
  final _imageLoading = CodexImageLoadController();
  final _masonry = CodexMasonry(gap: _gap);

  /// 正在显示的是哪一部(build 时定下)。换法典时按它把当前状态存回原主。
  String? _viewId;

  /// 每部法典各记各的搜索词与分类筛选,换走再换回来原样还原。
  /// 滚动位置记在 [ScrollMemory] 里,键带法典 id。
  final _views =
      <
        String,
        ({String search, List<String> cat, bool favoritesOnly, bool newOnly})
      >{};

  late final _scroll = MemoScrollController.keyed(
    () =>
        'inspiration.codex.${_viewId ?? ''}.${_randomWorkspace ? 'random' : 'browse'}',
    onAttach: _imageLoading.attach,
    onDetach: _imageLoading.detach,
  );

  /// 搜索框要能被程序清空(换法典时),所以不能是裸 TextField。
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _debounce?.cancel();
    _searchFocus.dispose();
    _searchCtrl.dispose();
    _scroll.dispose();
    _imageLoading.dispose();
    super.dispose();
  }

  // ---- 双指捏合改列数(见 PinchColumnsMixin) ----

  @override
  int get initialGridColumns =>
      ref.read(uiPrefsProvider).inspirationColumns[_kColsKey] ?? _kCols;

  @override
  int get minGridColumns => 1;

  @override
  int get maxGridColumns => 4;

  @override
  ScrollController get pinchScrollController => _scroll;

  @override
  void onGridColumnsChanged(int cols) => ref
      .read(uiPrefsProvider.notifier)
      .patch(
        (p) => p.copyWith(
          inspirationColumns: {...p.inspirationColumns, _kColsKey: cols},
        ),
      );

  void _onSearch(String v) {
    _debounce?.cancel();
    // 上万词条,逐键过滤会卡;250ms 防抖
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        if ((!widget.desktop || widget.embedded) && _scroll.hasClients) {
          _scroll.jumpTo(0);
        }
        setState(() => _search = v);
      }
    });
  }

  String _resolveSelectedId(List<CodexMeta> index) =>
      resolveSelectedCodex(index, ref.watch(selectedCodexProvider)).id;

  List<CodexEntry> _filtered(
    CodexData d,
    CodexBlock block,
    Set<String> favorites,
    String search, {
    List<String>? category,
  }) {
    final q = search.trim().toLowerCase();
    return d.onePerArtist([
      for (final e in d.entries)
        if (codexPathUnder(e.path, category ?? _catPath) &&
            !block.hides(e.path) &&
            (!_newOnly || e.isNew) &&
            (!_favoritesOnly ||
                favorites.contains(codexFavKey(d.meta.id, e.id))) &&
            (q.isEmpty ||
                e.title.toLowerCase().contains(q) ||
                e.tags.toLowerCase().contains(q) ||
                e.path.any((p) => p.toLowerCase().contains(q)) ||
                e.characters.any((c) => c.prompt.toLowerCase().contains(q))))
          e,
    ]);
  }

  /// 分类弹层数条数用的整部词条(一位画师算一条);按法典数据缓存。
  CodexData? _browseFor;
  List<CodexEntry> _browse = const [];
  List<CodexEntry> _browseEntries(CodexData d) {
    if (!identical(d, _browseFor)) {
      _browseFor = d;
      _browse = d.onePerArtist(d.entries);
    }
    return _browse;
  }

  @override
  Widget build(BuildContext context) {
    // 换法典:当前这部的搜索与分类存回它名下,换上目标那部上次的(没去过就是空)。
    // 选择器在外层顶栏,靠 provider 联动。
    //
    // 搜索不能跨法典带过去:新法典多半一条都匹配不上,切过去只看到「没有匹配的
    // 词条」,没人会想到是上面那个旧关键词在过滤。输入框文本、过滤用的 _search、
    // 以及**防抖里压着的那次**三样一起换(不取消的话它会在切换后才落地,把旧
    // 关键词写进新法典)。滚动位置不用管:网格按法典 id 换 key 重建,从那部的
    // 账上落位。
    ref.listen(selectedCodexProvider, (_, next) {
      if (!mounted || next == null || next == _viewId) return;
      _debounce?.cancel();
      final from = _viewId;
      if (from != null) {
        _views[from] = (
          search: _searchCtrl.text,
          cat: _catPath,
          favoritesOnly: _favoritesOnly,
          newOnly: _newOnly,
        );
      }
      final to = _views[next];
      _searchCtrl.text = to?.search ?? '';
      setState(() {
        _catPath = to?.cat ?? const [];
        _search = to?.search ?? '';
        _favoritesOnly = to?.favoritesOnly ?? false;
        _newOnly = to?.newOnly ?? false;
      });
    });
    final indexAsync = ref.watch(codexIndexProvider);
    final body = indexAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _error(
        context.l10n.codexIndexFailed,
        () => ref.invalidate(codexIndexProvider),
      ),
      data: (index) {
        if (index.isEmpty) return _msg(context.l10n.noCodex);
        final selId = _viewId = _resolveSelectedId(index);
        final meta = index.firstWhere((m) => m.id == selId);
        // 首次进入法典功能:读盘确认为「没读过」时弹一次说明。
        if (ref.watch(codexIntroProvider) == false) _maybeShowIntro();
        return _body(index, meta);
      },
    );
    if (!widget.desktop || widget.embedded) return body;
    final search = buildDesktopInspirationSearch(
      context,
      key: const ValueKey('desktop-codex-search'),
      controller: _searchCtrl,
      focusNode: _searchFocus,
      onChanged: _onSearch,
      hint: context.l10n.searchTitlePromptHint,
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            _searchFocus.requestFocus(),
      },
      child: Column(
        children: [
          widget.desktopHeaderBuilder?.call(search) ??
              Align(
                alignment: Alignment.centerRight,
                child: SizedBox(width: 300, child: search),
              ),
          Expanded(child: body),
        ],
      ),
    );
  }

  /// 首次进入弹一次说明(post-frame 起弹,防重入)。
  void _maybeShowIntro() {
    if (_introScheduled) return;
    _introScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showIntroDialog();
    });
  }

  void _showIntroDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.menu_book_outlined, color: context.scheme.primary),
        title: Text(context.l10n.codexSource),
        content: SelectableText(
          context.l10n.codexAbout,
          style: context.texts.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () {
              ref.read(codexIntroProvider.notifier).ack();
              Navigator.pop(ctx);
              launchUrl(
                Uri.parse('https://novelai.quicktagcloud.com/'),
                mode: LaunchMode.externalApplication,
              );
            },
            child: Text(context.l10n.sourcesThanks),
          ),
          FilledButton(
            onPressed: () {
              ref.read(codexIntroProvider.notifier).ack();
              Navigator.pop(ctx);
            },
            child: Text(context.l10n.gotIt),
          ),
        ],
      ),
    );
  }

  Widget _body(List<CodexMeta> index, CodexMeta meta) {
    final dataAsync = ref.watch(codexDataProvider(meta.id));
    // 索引后台刷新出新版本时,新数据到手前继续显示旧的
    return dataAsync.when(
      skipLoadingOnReload: true,
      skipError: true,
      loading: () => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.desktop && !widget.embedded) const CodexPickerButton(),
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              context.l10n.loadingEntries(meta.entryCount),
              style: context.texts.bodySmall!.copyWith(
                color: context.scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      error: (e, _) => Column(
        children: [
          if (widget.desktop && !widget.embedded) const CodexPickerButton(),
          Expanded(
            child: _error(
              context.l10n.codexLoadFailed,
              () => ref.invalidate(codexDataProvider(meta.id)),
            ),
          ),
        ],
      ),
      data: (d) {
        // 词条到手就把这部的中文对照也拉上:点开详情时表多半已就绪,芯片不用
        // 先出离线词库的译名、再被对照表换一遍字。listen 不 watch —— 表到了
        // 这层不用重建。
        ref.listen(codexTagZhProvider(meta.id), (_, _) {});
        final media =
            ref.watch(codexMediaProvider).value ?? CodexMedia.fallback;
        ref.listen(codexBlockProvider(meta.id), (_, b) {
          if (b.hides(_catPath)) setState(() => _catPath = const []);
        });
        final block = ref.watch(codexBlockProvider(meta.id));
        if (block.hides(_catPath)) _catPath = const [];
        final favorites = ref.watch(codexFavKeysProvider);
        final entries = _filtered(d, block, favorites, _search);
        if (widget.desktop) {
          return _desktopBody(d, meta, media, entries, favorites, block);
        }
        return Column(
          children: [
            _searchRow(),
            _filterBar(d, meta, media, entries, block),
            Expanded(
              child: entries.isEmpty
                  ? _msg(
                      _search.isNotEmpty
                          ? context.l10n.noMatchingEntries
                          : context.l10n.noEntries,
                    )
                  : _grid(meta, media, entries),
            ),
          ],
        );
      },
    );
  }

  void _selectCategory(List<String> path) {
    if ((!widget.desktop || widget.embedded) && _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    setState(() => _catPath = path);
  }

  Widget _embeddedSearch() => TextField(
    key: const ValueKey('desktop-codex-search'),
    controller: _searchCtrl,
    focusNode: _searchFocus,
    onChanged: _onSearch,
    decoration: InputDecoration(
      hintText: l10nNow.searchTitlePromptHint,
      prefixIcon: const Icon(Icons.search, size: 20),
      isDense: true,
      filled: true,
      fillColor: context.scheme.surfaceContainerLowest,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    ),
  );

  Widget _desktopBody(
    CodexData data,
    CodexMeta meta,
    CodexMedia media,
    List<CodexEntry> entries,
    Set<String> favorites,
    CodexBlock block,
  ) {
    final scheme = context.scheme;
    return LayoutBuilder(
      builder: (context, box) {
        final edge = widget.embedded ? 12.0 : 24.0;
        final category = _catButton(data, meta, block);
        final favorite = _favButton();
        final random = _desktopFilterButton(
          key: const ValueKey('desktop-codex-random'),
          selected: _randomWorkspace,
          onPressed: _toggleRandomWorkspace,
          icon: _randomWorkspace ? Icons.casino : Icons.casino_outlined,
          label: context.l10n.desktopRandomInspiration,
        );
        final scope = _catPath.isEmpty
            ? context.l10n.codexAllEntries
            : _catPath.join(' / ');
        final itemCount = context.l10n.itemsN(entries.length);
        final summary = '$scope · $itemCount';
        final mainDraw = widget.embedded
            ? false
            : ref.watch(codexMainDrawProvider);
        final drawing = widget.embedded ? _randomWorkspace : mainDraw;
        final deck = drawing
            ? CodexRandomWorkspace(
                key: ValueKey('draw-${meta.id}'),
                wide: !widget.embedded && CodexCatalog.hasRail(box),
                onBrowseCategory: (path) {
                  _selectCategory(path);
                  _toggleRandomWorkspace();
                },
                scope: ([category]) => [
                  (category ?? _catPath).isEmpty
                      ? context.l10n.allCategories
                      : (category ?? _catPath).join(' / '),
                  if (_favoritesOnly) context.l10n.codexOnlyFavorites,
                  if (_newOnly) context.l10n.codexRecentAdditions,
                  if (_searchCtrl.text.trim().isNotEmpty)
                    '“${_searchCtrl.text.trim()}”',
                ].join(' · '),
                scopeKey: ([category]) => jsonEncode([
                  meta.id,
                  // An entry recalled from a different branch uses that branch's round.
                  category != null && !codexPathUnder(category, _catPath)
                      ? category
                      : _catPath,
                  _favoritesOnly,
                  _newOnly,
                  _searchCtrl.text.trim().toLowerCase(),
                  block.paths.map(jsonEncode).toList()..sort(),
                ]),
                codex: meta,
                entries: entries,
                candidatesForDraw: ([category]) {
                  final query = _searchCtrl.text;
                  if (category != null && !codexPathUnder(category, _catPath)) {
                    return _filtered(
                      data,
                      block,
                      favorites,
                      query,
                      category: category,
                    );
                  }
                  final pool = query == _search
                      ? entries
                      : _filtered(data, block, favorites, query);
                  return category == null
                      ? pool
                      : pool
                            .where((e) => codexPathUnder(e.path, category))
                            .toList();
                },
                bookPicker: const CodexPickerButton(expanded: true),
                categoryPicker: category,
                favoritesOnly: _favoritesOnly,
                onFavorites: _toggleFavorites,
                query: _search.trim(),
                onClearQuery: () {
                  _debounce?.cancel();
                  _searchCtrl.clear();
                  setState(() => _search = '');
                },
                newOnly: _newOnly,
                onToggleNew: () => setState(() => _newOnly = !_newOnly),
                media: media,
                onClose: _toggleRandomWorkspace,
              )
            : null;
        if (!widget.embedded) {
          return CodexCatalog(
            key: ValueKey('book-${meta.id}'),
            data: data,
            media: media,
            entries: entries,
            favorites: favorites,
            block: block,
            path: _catPath,
            query: _search,
            favoritesOnly: _favoritesOnly,
            newOnly: _newOnly,
            categoryPicker: category,
            bookPicker: const CodexPickerButton(expanded: true),
            onCategory: _selectCategory,
            onFavorites: _toggleFavorites,
            onRecent: () => setState(() => _newOnly = !_newOnly),
            onDraw: _toggleRandomWorkspace,
            onReset: () {
              _debounce?.cancel();
              _searchCtrl.clear();
              setState(() {
                _search = '';
                _catPath = const [];
                _favoritesOnly = false;
                _newOnly = false;
              });
            },
            drawWorkspace: deck,
          );
        }
        if (deck != null) {
          return KeyedSubtree(
            key: const ValueKey('desktop-codex-browser'),
            child: deck,
          );
        }
        return Column(
          key: const ValueKey('desktop-codex-browser'),
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(edge, 12, edge, 8),
              child: Column(
                key: const ValueKey('embedded-codex-toolbar'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        flex: 6,
                        child: CodexPickerButton(expanded: true),
                      ),
                      const SizedBox(width: 8),
                      Expanded(flex: 5, child: category),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _embeddedSearch(),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Tooltip(
                          message: summary,
                          child: DefaultTextStyle(
                            style: context.texts.bodyMedium!.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            child: Wrap(
                              key: const ValueKey('embedded-codex-summary'),
                              spacing: 4,
                              children: [Text(scope), Text('· $itemCount')],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      favorite,
                      const SizedBox(width: 4),
                      random,
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: _desktopGrid(meta, media, entries, favorites, edge),
            ),
          ],
        );
      },
    );
  }

  Widget _desktopGrid(
    CodexMeta meta,
    CodexMedia media,
    List<CodexEntry> entries,
    Set<String> favorites,
    double edge,
  ) => entries.isEmpty
      ? _msg(_favoritesOnly ? '没有匹配的收藏词条' : '没有匹配的词条')
      : LayoutBuilder(
          builder: (context, gridBox) {
            final layout = CodexCard.desktopGrid(
              context,
              gridBox.maxWidth - edge * 2,
              embedded: widget.embedded,
            );
            return Scrollbar(
              controller: _scroll,
              thumbVisibility: true,
              child: GridView.builder(
                key: const ValueKey('desktop-codex-grid'),
                controller: _scroll,
                // Prepare two nearby rows without keeping the
                // entire remote collection alive.
                scrollCacheExtent: const ScrollCacheExtent.pixels(692),
                padding: EdgeInsets.fromLTRB(edge, 0, edge, 24),
                gridDelegate: layout.delegate,
                itemCount: entries.length,
                itemBuilder: (_, i) => CodexCard(
                  key: ValueKey('desktop-codex-card-${entries[i].id}'),
                  codex: meta,
                  entry: entries[i],
                  media: media,
                  desktop: true,
                  embedded: widget.embedded,
                  imageLoading: _imageLoading,
                  decodeWidth: layout.width,
                  favorite: favorites.contains(
                    codexFavKey(meta.id, entries[i].id),
                  ),
                  onFavorite: () async {
                    final notifier = ref.read(codexFavoritesProvider.notifier);
                    final selected = await notifier.toggle(
                      meta.id,
                      entries[i],
                      now: DateTime.now().millisecondsSinceEpoch,
                    );
                    if (mounted && !selected && notifier.isFull) {
                      hintSnack(this.context, l10nNow.desktopFavoritesAreFull);
                    }
                  },
                  onTap: () => showCodexDetailSheet(
                    this.context,
                    meta,
                    media,
                    entries: entries,
                    index: i,
                  ),
                ),
              ),
            );
          },
        );

  Widget _searchRow() {
    final scheme = context.scheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_edge, 8, _edge, 0),
      child: TextField(
        controller: _searchCtrl,
        onChanged: _onSearch,
        decoration: InputDecoration(
          isDense: true,
          hintText: l10nNow.searchTitlePromptHint,
          prefixIcon: const Icon(Icons.search, size: 20),
          filled: true,
          fillColor: scheme.surfaceContainerHigh,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
        ),
      ),
    );
  }

  /// 筛选行:分类树入口(全部分类栏)+ 右侧收藏 / 随机。上下外边距相等。
  /// 分类按钮用 Expanded 占左、右侧两枚自然宽靠右——单个 Expanded 吸掉所有
  /// 余量,右侧才会真正贴右(Flexible + Spacer 双 flex 会把余量甩到行尾)。
  Widget _filterBar(
    CodexData d,
    CodexMeta meta,
    CodexMedia media,
    List<CodexEntry> entries,
    CodexBlock block,
  ) {
    final tree = d.effectiveTree;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_edge, 8, _edge, 8),
      child: Row(
        children: [
          Expanded(
            child: tree.isNotEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: _catButton(d, meta, block),
                  )
                : const SizedBox.shrink(),
          ),
          _favButton(),
          const SizedBox(width: 8),
          _randomButton(meta, media, entries),
        ],
      ),
    );
  }

  void _toggleFavorites() {
    if ((!widget.desktop || widget.embedded) && _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    setState(() => _favoritesOnly = !_favoritesOnly);
  }

  void _toggleRandomWorkspace() {
    if (widget.embedded) {
      setState(() => _randomWorkspace = !_randomWorkspace);
    } else {
      ref.read(codexMainDrawProvider.notifier).toggle();
    }
  }

  Widget _desktopFilterButton({
    required Key key,
    required bool selected,
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
  }) => Semantics(
    selected: selected,
    child: OutlinedButton.icon(
      key: key,
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: selected ? context.scheme.primaryContainer : null,
        minimumSize: widget.embedded ? const Size(0, 36) : null,
        padding: widget.embedded
            ? const EdgeInsets.symmetric(horizontal: 8)
            : null,
        tapTargetSize: widget.embedded
            ? MaterialTapTargetSize.shrinkWrap
            : null,
      ),
      icon: Icon(icon, size: widget.embedded ? 16 : 19),
      label: Text(label),
    ),
  );

  /// Filter this book in place, together with the active search and category.
  Widget _favButton() {
    final scheme = context.scheme;
    if (widget.desktop) {
      return _desktopFilterButton(
        key: const ValueKey('desktop-codex-favorites'),
        selected: _favoritesOnly,
        onPressed: _toggleFavorites,
        icon: _favoritesOnly ? Icons.star_rounded : Icons.star_outline,
        label: l10nNow.favorites,
      );
    }
    return Material(
      key: const ValueKey('codex-favorites-filter'),
      color: _favoritesOnly
          ? scheme.primaryContainer
          : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _toggleFavorites,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _favoritesOnly
                    ? Icons.star_rounded
                    : Icons.star_outline_rounded,
                size: 16,
                color: _favoritesOnly
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                context.l10n.favorites,
                style: context.texts.labelMedium!.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 分类胶囊:点开层级树选;已选时显示末级名 + 清除叉,主色实底标记。
  /// 有屏蔽生效时名字后带闭眼 + 屏蔽数。
  Widget _catButton(CodexData d, CodexMeta meta, CodexBlock block) {
    final scheme = context.scheme;
    final on = _catPath.isNotEmpty;
    final label = on ? _catPath.last : '全部分类';
    final radius = BorderRadius.circular(widget.embedded ? 10 : 20);
    return Builder(
      builder: (anchorContext) => Material(
        key: const ValueKey('codex-category-picker'),
        color: on ? scheme.primary : scheme.surfaceContainerHigh,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: () async {
            final picked = await showCodexCategorySheet(
              anchorContext,
              meta.id,
              d.effectiveTree,
              _catPath,
              _browseEntries(d),
            );
            if (picked != null && mounted) _selectCategory(picked);
          },
          child: Container(
            constraints: widget.embedded
                ? const BoxConstraints(minHeight: 36)
                : null,
            padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.account_tree_outlined,
                  size: 15,
                  color: on ? scheme.onPrimary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Flexible(
                  fit: widget.embedded ? FlexFit.tight : FlexFit.loose,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.labelMedium!.copyWith(
                      fontWeight: FontWeight.w600,
                      color: on ? scheme.onPrimary : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (block.active) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.visibility_off_outlined,
                    size: 14,
                    color: on ? scheme.onPrimary : scheme.primary,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '${block.paths.length}',
                    style: mono(
                      context,
                      size: 11,
                      color: on ? scheme.onPrimary : scheme.primary,
                    ),
                  ),
                ],
                const SizedBox(width: 4),
                if (on)
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => setState(() => _catPath = const []),
                    child: Icon(Icons.close, size: 16, color: scheme.onPrimary),
                  )
                else
                  Icon(
                    Icons.keyboard_arrow_down,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 随机按钮:从当前筛选出的词条里随机抽一条,弹详情并可「继续抽」。
  Widget _randomButton(
    CodexMeta meta,
    CodexMedia media,
    List<CodexEntry> entries,
  ) {
    final scheme = context.scheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          if (entries.isEmpty) {
            hintSnack(
              context,
              context.l10n.nothingToDraw,
              icon: Icons.casino_outlined,
            );
            return;
          }
          showCodexRandomSheet(context, meta, media, entries);
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.casino_outlined,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                context.l10n.random,
                style: context.texts.labelMedium!.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 瀑布流。几何见 [CodexMasonryLayout];捏合与过渡只重建 pinchBuilder 里那一块,
  /// 上面的筛选(上万条逐条比对)不跟着每帧重跑。
  Widget _grid(CodexMeta meta, CodexMedia media, List<CodexEntry> entries) =>
      pinchLayer(
        child: pinchBuilder((_) {
          // 例图按落定列数下的列宽解码(gridColumns 在换档过渡中是起点那一档)
          final cols = gridColumns;
          final decodeW =
              (MediaQuery.sizeOf(context).width -
                  _edge * 2 -
                  _gap * (cols - 1)) /
              cols;
          return CustomScrollView(
            key: ValueKey(meta.id), // 换法典即换一份列表,从那部的滚动账上落位
            controller: _scroll,
            physics: pinchPhysics(const AlwaysScrollableScrollPhysics()),
            slivers: [
              // 顶部不留边:筛选行自带下外边距,再留一道就叠出双倍空隙
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(_edge, 0, _edge, _gap),
                sliver: SliverGrid(
                  gridDelegate: zoomGridDelegate(
                    (n) => _masonry.delegate(entries, n),
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (_, i) => CodexCard(
                      codex: meta,
                      entry: entries[i],
                      media: media,
                      decodeWidth: decodeW,
                      // 详情页左右滑动就在当前筛选出的这一整批里翻
                      onTap: () => showCodexDetailSheet(
                        context,
                        meta,
                        media,
                        entries: entries,
                        index: i,
                      ),
                    ),
                    childCount: entries.length,
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 20)),
            ],
          );
        }),
      );

  Widget _error(String text, VoidCallback onRetry) {
    final scheme = context.scheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 44,
            color: scheme.outlineVariant,
          ),
          const SizedBox(height: 10),
          Text(
            text,
            style: context.texts.bodyMedium!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.tonal(onPressed: onRetry, child: Text(l10nNow.retry)),
        ],
      ),
    );
  }

  Widget _msg(String text) {
    final scheme = context.scheme;
    return Center(
      child: Text(
        text,
        style: context.texts.bodyMedium!.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

Widget _miniTag(BuildContext context, String label, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
  decoration: BoxDecoration(
    color: color.withValues(alpha: .16),
    borderRadius: BorderRadius.circular(6),
  ),
  child: Text(
    label,
    style: context.texts.labelSmall!.copyWith(
      color: color,
      fontWeight: FontWeight.w700,
    ),
  ),
);

/// 解析当前应显示的法典:选过就用选中项,否则取索引首个非 R18(退而取首个)。
CodexMeta resolveSelectedCodex(List<CodexMeta> index, String? sel) {
  if (sel != null) {
    for (final m in index) {
      if (m.id == sel) return m;
    }
  }
  final sfw = index.where((m) => !m.nsfw);
  return sfw.isNotEmpty ? sfw.first : index.first;
}

/// 「选择主法典」按钮:显示当前法典标题,点开选择器换法典。
/// 放在灵感页法典模式顶栏右侧的空位,替代原 CodexView 头部整行。
/// 换法典只改 [selectedCodexProvider],正文的分类筛选由 CodexView 监听联动重置。
class CodexPickerButton extends ConsumerWidget {
  const CodexPickerButton({super.key, this.expanded = false});

  final bool expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final desktop = ref.watch(desktopModeProvider);
    final index = ref.watch(codexIndexProvider).value;
    if (index == null || index.isEmpty) {
      return SizedBox(height: desktop ? 36 : 44);
    }
    final meta = resolveSelectedCodex(index, ref.watch(selectedCodexProvider));
    return ConstrainedBox(
      constraints: desktop
          ? const BoxConstraints(maxWidth: 320)
          : const BoxConstraints(),
      child: Tooltip(
        message: '选择法典：${meta.displayTitle}',
        child: Material(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(desktop ? 10 : 22),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('codex-picker-button'),
            onTap: () async {
              final id = await showCodexPickerSheet(context, index, meta.id);
              if (id != null && context.mounted) {
                ref.read(selectedCodexProvider.notifier).select(id);
              }
            },
            child: Container(
              height: desktop ? null : 44,
              constraints: const BoxConstraints(minHeight: 36),
              padding: desktop
                  ? const EdgeInsets.fromLTRB(12, 6, 8, 6)
                  : const EdgeInsets.fromLTRB(14, 0, 8, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (expanded) ...[
                    Icon(
                      Icons.menu_book_outlined,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    fit: expanded ? FlexFit.tight : FlexFit.loose,
                    child: Text(
                      meta.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          (desktop
                                  ? context.texts.labelLarge
                                  : context.texts.titleSmall)!
                              .copyWith(
                                fontWeight: desktop
                                    ? FontWeight.w600
                                    : FontWeight.w800,
                              ),
                    ),
                  ),
                  if (meta.nsfw) ...[
                    const SizedBox(width: 6),
                    _miniTag(context, 'R18', scheme.error),
                  ],
                  const SizedBox(width: 4),
                  Icon(
                    Icons.keyboard_arrow_down,
                    size: desktop ? 18 : 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CodexMainDrawButton extends ConsumerWidget {
  const CodexMainDrawButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(codexMainDrawProvider);
    return FilledButton.tonalIcon(
      key: const ValueKey('codex-main-draw-toggle'),
      onPressed: ref.read(codexMainDrawProvider.notifier).toggle,
      icon: const Icon(Icons.casino_outlined, size: 18),
      label: Text(
        open
            ? context.l10n.codexCloseDrawDesk
            : context.l10n.desktopRandomInspiration,
      ),
    );
  }
}
