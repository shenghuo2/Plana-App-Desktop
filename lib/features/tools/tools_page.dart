import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/ui_prefs.dart';
import '../../core/platform/desktop.dart';
import '../../core/ui/settings_scaffold.dart';
import 'metadata_tool_page.dart';
import 'metadata_compare_page.dart';
import 'metadata_tool_link.dart';
import 'weight_convert_page.dart';
import '../../l10n/l10n.dart';

/// 工具箱的权重转换、图片元数据与图片比对页签。
/// 切换页签时保留已输入的内容与已选图片。
class ToolsPage extends ConsumerStatefulWidget {
  const ToolsPage({super.key});

  @override
  ConsumerState<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends ConsumerState<ToolsPage> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _desktopFrame(Widget child) => Padding(
    padding: const EdgeInsets.all(24),
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1440),
        child: child,
      ),
    ),
  );

  Widget _desktopBody(int tab, Widget tabs) {
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [const SettingsPageHeader(), tabs],
    );
    const editors = [WeightConvertView(), MetadataToolView()];
    return IndexedStack(
      index: tab == 2 ? 1 : 0,
      children: [
        Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            key: const PageStorageKey('desktop-tools-scroll'),
            controller: _scroll,
            child: _desktopFrame(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  for (final (i, editor) in editors.indexed)
                    Offstage(
                      offstage: tab != i,
                      child: TickerMode(
                        enabled: tab == i,
                        child: ExcludeFocus(excluding: tab != i, child: editor),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        _desktopFrame(
          CustomScrollView(
            primary: false,
            slivers: [
              SliverToBoxAdapter(child: header),
              SliverLayoutBuilder(
                builder: (context, viewport) => SliverToBoxAdapter(
                  child: MetadataCompareView(
                    desktopViewportHeight:
                        viewport.viewportMainAxisExtent -
                        viewport.precedingScrollExtent,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktop = ref.watch(desktopModeProvider);
    final tab = ref.watch(
      uiPrefsProvider.select((p) => p.toolsTab.clamp(0, 2)),
    );
    ref.listen(singleMetadataRequestProvider, (_, _) {
      final toolsRoute = ModalRoute.of(context);
      Navigator.of(
        context,
      ).popUntil((route) => route == toolsRoute || route.isFirst);
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
    final selector = SegmentedButton<int>(
      segments: [
        ButtonSegment(
          value: 0,
          label: Text(l10nNow.weightConverter, maxLines: 1),
          icon: Icon(Icons.swap_horiz, size: 17),
        ),
        ButtonSegment(
          value: 1,
          label: Text(l10nNow.imageMetadata, maxLines: 1),
          icon: Icon(Icons.document_scanner_outlined, size: 17),
        ),
        ButtonSegment(
          value: 2,
          label: Text(l10nNow.compareImages, maxLines: 1),
          icon: const Icon(Icons.compare_outlined, size: 17),
        ),
      ],
      selected: {tab},
      onSelectionChanged: (s) {
        FocusManager.instance.primaryFocus?.unfocus();
        ref
            .read(uiPrefsProvider.notifier)
            .patch((p) => p.copyWith(toolsTab: s.first));
      },
      showSelectedIcon: false,
    );
    final tabs = Padding(
      padding: desktop
          ? const EdgeInsets.only(bottom: 20)
          : const EdgeInsets.fromLTRB(14, 4, 14, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: selector,
      ),
    );
    return SettingsScaffold(
      appBar: AppBar(title: Text(l10nNow.toolbox)),
      body: desktop
          ? _desktopBody(tab, tabs)
          : Column(
              children: [
                tabs,
                Expanded(
                  child: IndexedStack(
                    index: tab,
                    children: const [
                      WeightConvertView(),
                      MetadataToolView(),
                      MetadataCompareView(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
