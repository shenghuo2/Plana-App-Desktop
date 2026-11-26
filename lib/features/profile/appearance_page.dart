import '../../core/ui/theme_swatches.dart';
import '../../core/ui/settings_scaffold.dart';
import '../../l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/platform/desktop.dart';
import '../../core/theme/theme_settings.dart';
import 'widgets/settings_ui.dart';
import '../inspiration/inspiration_page.dart';

class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ts = ref.watch(themeSettingsProvider);
    final desktop = ref.watch(desktopModeProvider);
    final notifier = ref.read(themeSettingsProvider.notifier);
    return SettingsScaffold(
      appBar: AppBar(title: Text(desktop ? '外观与体验' : '外观与触感')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: [
          const SettingsPageHeader(),
          SettingsCard(
            children: [
              _LanguageRow(
                value: ts.language,
                onChanged: (value) =>
                    notifier.patch((x) => x.copyWith(language: value)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SettingsLabel(context.l10n.themeMode),
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
                    segments: [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text(context.l10n.followSystem),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text(context.l10n.themeLight),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text(context.l10n.themeDark),
                      ),
                    ],
                    selected: {ts.mode},
                    onSelectionChanged: (s) =>
                        notifier.patch((x) => x.copyWith(mode: s.first)),
                    showSelectedIcon: false,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SettingsLabel(context.l10n.themeColor),
          const SettingsCard(
            children: [
              Padding(padding: EdgeInsets.all(16), child: ThemeSwatches()),
            ],
          ),
          const SizedBox(height: 16),
          if (desktop) ...[
            const SettingsLabel('全局字体大小'),
            SettingsCard(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            '${(ts.textScale * 100).round()}%',
                            key: const ValueKey('appearance-text-scale-value'),
                            style: context.texts.titleLarge,
                          ),
                          TextButton(
                            key: const ValueKey('appearance-text-scale-reset'),
                            onPressed: ts.textScale == 1
                                ? null
                                : () => notifier.patch(
                                    (x) => x.copyWith(textScale: 1),
                                  ),
                            child: Text(l10nNow.resetSettings),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '即时调整整个应用的文字大小，100% 为默认。创作页提示词编辑区保留原有字号基准，也会随此设置缩放。',
                        style: context.texts.bodySmall!.copyWith(
                          color: context.scheme.onSurfaceVariant,
                        ),
                      ),
                      Slider(
                        key: const ValueKey('appearance-text-scale'),
                        value: ts.textScale,
                        min: kMinAppTextScale,
                        max: kMaxAppTextScale,
                        divisions: 12,
                        label: '${(ts.textScale * 100).round()}%',
                        semanticFormatterCallback: (value) =>
                            '${(value * 100).round()}%',
                        onChanged: (value) =>
                            notifier.patch((x) => x.copyWith(textScale: value)),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('80%', style: context.texts.bodySmall),
                          Text('140%', style: context.texts.bodySmall),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const SettingsLabel('页面对齐方式'),
            SettingsCard(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l10nNow
                            .desktopSetTheHorizontalAlignmentOfTheProfileContent,
                        style: context.texts.bodySmall!.copyWith(
                          color: context.scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SegmentedButton<PageAlignment>(
                        segments: [
                          ButtonSegment(
                            value: PageAlignment.center,
                            label: Text(l10nNow.desktopCenter),
                            icon: Icon(Icons.align_horizontal_center),
                          ),
                          ButtonSegment(
                            value: PageAlignment.left,
                            label: Text(l10nNow.desktopLeft),
                            icon: Icon(Icons.align_horizontal_left),
                          ),
                        ],
                        selected: {ts.pageAlignment},
                        onSelectionChanged: (s) => notifier.patch(
                          (x) => x.copyWith(pageAlignment: s.first),
                        ),
                        showSelectedIcon: false,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          SettingsLabel(desktop ? '导航栏' : '底部导航'),
          SettingsCard(
            children: [
              _SwitchRow(
                icon: Icons.auto_awesome,
                title: l10nNow.showAssistant,
                subtitle: desktop ? '关掉后顶部导航不再显示 AI 入口' : '关掉后底栏不再显示 AI 入口',
                value: ts.showAssistant,
                onChanged: (v) =>
                    notifier.patch((x) => x.copyWith(showAssistant: v)),
              ),
              if (desktop)
                _SwitchRow(
                  icon: Icons.handyman_outlined,
                  title: l10nNow.desktopShowToolbox,
                  subtitle:
                      l10nNow.desktopShowToolboxInTheTopNavigationOrAccess,
                  value: ts.showTools,
                  onChanged: (v) =>
                      notifier.patch((x) => x.copyWith(showTools: v)),
                ),
            ],
          ),
          const SizedBox(height: 16),
          SettingsLabel(context.l10n.createPage),
          SettingsCard(
            children: [
              _SwitchRow(
                key: const ValueKey('appearance-collapse-prompts'),
                icon: Icons.view_agenda_outlined,
                title: desktop ? '提示词卡片折叠' : '紧凑角色卡',
                subtitle: desktop
                    ? '允许折叠主体、分区和角色提示词，关闭后卡片始终展开'
                    : '收起头像预览，保留名称、位置与提示词',
                value: desktop
                    ? ts.collapsiblePromptCards
                    : ts.compactCharCards,
                onChanged: (v) => notifier.patch(
                  (x) => desktop
                      ? x.copyWith(collapsiblePromptCards: v)
                      : x.copyWith(compactCharCards: v),
                ),
              ),
              if (desktop)
                _SwitchRow(
                  key: const ValueKey('appearance-fold-after-inspiration-save'),
                  icon: Icons.view_module_outlined,
                  title: context.l10n.foldAfterInspirationSave,
                  subtitle: context.l10n.foldAfterInspirationSaveHint,
                  value: ts.foldAfterInspirationSave,
                  onChanged: (enabled) => notifier.patch(
                    (settings) =>
                        settings.copyWith(foldAfterInspirationSave: enabled),
                  ),
                ),
            ],
          ),
          if (desktop) ...[
            const SizedBox(height: 16),
            SettingsLabel(context.l10n.gallery),
            SettingsCard(
              children: [
                LayoutBuilder(
                  builder: (context, bounds) {
                    final choices = SegmentedButton<GalleryDragFeel>(
                      key: const ValueKey('gallery-drag-feel'),
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: GalleryDragFeel.crisp,
                          label: Text(context.l10n.galleryDragCrisp),
                        ),
                        ButtonSegment(
                          value: GalleryDragFeel.smooth,
                          label: Text(context.l10n.galleryDragSmooth),
                        ),
                        ButtonSegment(
                          value: GalleryDragFeel.bouncy,
                          label: Text(context.l10n.galleryDragBouncy),
                        ),
                      ],
                      selected: {ts.galleryDragFeel},
                      onSelectionChanged: (v) => notifier.patch(
                        (s) => s.copyWith(galleryDragFeel: v.single),
                      ),
                    );
                    return _AppearanceRow(
                      icon: Icons.open_with,
                      title: context.l10n.galleryDragFeel,
                      subtitle: context.l10n.galleryDragFeelHint,
                      control: choices,
                      controlBelow:
                          bounds.maxWidth <
                          440 * MediaQuery.textScalerOf(context).scale(14) / 14,
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            const SettingsLabel('灵感'),
            SettingsCard(
              children: [
                _SwitchRow(
                  key: const ValueKey('appearance-codex-hover-preview'),
                  icon: Icons.photo_outlined,
                  title: l10nNow.desktopCodexHoverPreview,
                  subtitle: l10nNow.desktopCodexImageHoverHint,
                  value: ts.codexHoverPreview,
                  onChanged: (value) => notifier.patch(
                    (settings) => settings.copyWith(codexHoverPreview: value),
                  ),
                ),
                _SwitchRow(
                  key: const ValueKey('appearance-inspiration-row-snap'),
                  icon: Icons.view_stream_outlined,
                  title: context.l10n.inspirationRowSnap,
                  subtitle: context.l10n.inspirationRowSnapHint,
                  value: ts.inspirationRowSnap,
                  onChanged: (value) => notifier.patch(
                    (settings) => settings.copyWith(inspirationRowSnap: value),
                  ),
                ),
                LayoutBuilder(
                  builder: (context, bounds) => _AppearanceRow(
                    icon: Icons.sell_outlined,
                    title: context.l10n.inspirationTagMatch,
                    subtitle: context.l10n.inspirationTagMatchHint,
                    controlBelow:
                        bounds.maxWidth <
                        440 * MediaQuery.textScalerOf(context).scale(14) / 14,
                    control: SegmentedButton<bool>(
                      key: const ValueKey('appearance-tag-match'),
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: false,
                          label: Text(context.l10n.tagIntersection),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text(context.l10n.tagUnion),
                        ),
                      ],
                      selected: {ts.inspirationMatchAnyTag},
                      onSelectionChanged: (v) => notifier.patch(
                        (s) => s.copyWith(inspirationMatchAnyTag: v.single),
                      ),
                    ),
                  ),
                ),
                SettingsRowTextTheme(
                  child: ListTile(
                    key: const ValueKey('appearance-public-blocklist'),
                    leading: const Icon(Icons.block_outlined),
                    title: Text(context.l10n.publicLibraryBlocklist),
                    subtitle: Text(context.l10n.publicLibraryBlocklistHint),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () =>
                        Navigator.of(context, rootNavigator: true).push<void>(
                          MaterialPageRoute(
                            builder: (_) => const InspirationPage.blocklist(),
                          ),
                        ),
                  ),
                ),
              ],
            ),
          ],
          if (!desktop) ...[
            const SizedBox(height: 16),
            const SettingsLabel('触感'),
            SettingsCard(
              children: [
                _SwitchRow(
                  icon: Icons.vibration,
                  title: l10nNow.hapticFeedback,
                  value: ts.haptics,
                  onChanged: (v) =>
                      notifier.patch((x) => x.copyWith(haptics: v)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 卡片里的一行开关。整行可点。
class _LanguageRow extends StatelessWidget {
  const _LanguageRow({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = {
      'zh': '中文',
      'en': 'English',
      'ja': '日本語',
      '': context.l10n.followSystem,
    };
    return SettingsRow(
      key: const ValueKey('appearance-language'),
      icon: Icons.translate,
      title: context.l10n.creationLanguage,
      value: options[value],
      dropdown: true,
      onTap: () async {
        final row = context.findRenderObject()! as RenderBox;
        final overlay =
            Navigator.of(context).overlay!.context.findRenderObject()!
                as RenderBox;
        final picked = await showMenu<String>(
          context: context,
          positionBuilder: (_, _) {
            final edge = row.localToGlobal(
              row.size.bottomRight(Offset.zero),
              ancestor: overlay,
            );
            return RelativeRect.fromRect(
              Rect.fromLTWH(edge.dx - 1, edge.dy, 1, 0),
              Offset.zero & overlay.size,
            );
          },
          items: [
            for (final item in options.entries)
              CheckedPopupMenuItem<String>(
                value: item.key,
                checked: item.key == value,
                child: Text(item.value),
              ),
          ],
        );
        if (context.mounted && picked != null) onChanged(picked);
      },
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => onChanged(!value),
    child: _AppearanceRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      control: Switch(value: value, onChanged: onChanged),
    ),
  );
}

class _AppearanceRow extends StatelessWidget {
  const _AppearanceRow({
    required this.icon,
    required this.title,
    required this.control,
    this.subtitle,
    this.controlBelow = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget control;
  final bool controlBelow;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final row = Row(
      children: [
        Icon(icon, size: 20, color: scheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: SettingsRowTextTheme.titleStyle(context)),
              if (subtitle case final sub?) ...[
                const SizedBox(height: 2),
                Text(sub, style: SettingsRowTextTheme.subtitleStyle(context)),
              ],
            ],
          ),
        ),
        if (!controlBelow) ...[const SizedBox(width: 8), control],
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: controlBelow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                row,
                Padding(
                  padding: const EdgeInsets.only(left: 32, top: 8),
                  child: control,
                ),
              ],
            )
          : row,
    );
  }
}
