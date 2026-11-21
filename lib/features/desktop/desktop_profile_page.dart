import '../../l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_settings.dart';
import '../generate/preset_manage_page.dart';
import '../profile/backup_page.dart';
import '../profile/about_page.dart';
import '../profile/account_page.dart';
import '../profile/appearance_page.dart';
import '../profile/cloud_storage_page.dart';
import '../profile/gen_settings_page.dart';
import '../profile/network_settings_page.dart';
import '../profile/storage_page.dart';
import '../stats/stats_page.dart';
import '../shell/shell_state.dart';
import 'desktop_tools_page.dart';

enum _Section {
  account(Icons.manage_accounts_outlined, AccountPage()),
  network(Icons.settings_ethernet, NetworkSettingsPage()),
  dataImport(Icons.import_export, BackupPage()),
  remoteUpload(Icons.cloud_upload_outlined, CloudStoragePage()),
  generation(Icons.tune, GenSettingsPage()),
  presets(Icons.bookmark_outline, PromptPresetManagePage()),
  appearance(Icons.color_lens_outlined, AppearancePage()),
  storage(Icons.storage_outlined, StoragePage()),
  tools(Icons.handyman_outlined, null),
  stats(Icons.query_stats, StatsPage()),
  about(Icons.info_outline, AboutPage());

  const _Section(this.icon, this.page);
  String get label => switch (this) {
    _Section.account => l10nNow.accountAccess,
    _Section.network => l10nNow.desktopNetworkAndProxy,
    _Section.dataImport => l10nNow.desktopBackupAndImport,
    _Section.remoteUpload => '远端上传',
    _Section.generation => l10nNow.generationSettings,
    _Section.presets => l10nNow.promptPresets,
    _Section.appearance => l10nNow.desktopAppearanceAndExperience,
    _Section.storage => l10nNow.storage,
    _Section.tools => l10nNow.toolbox,
    _Section.stats => l10nNow.stats,
    _Section.about => l10nNow.desktopAboutPlana,
  };
  String get group => switch (this) {
    _Section.account => l10nNow.desktopAccountsAndServices,
    _Section.network => l10nNow.desktopAccountsAndServices,
    _Section.dataImport => l10nNow.desktopAccountsAndServices,
    _Section.remoteUpload => l10nNow.desktopAccountsAndServices,
    _Section.generation => l10nNow.desktopCreationPreferences,
    _Section.presets => l10nNow.desktopCreationPreferences,
    _Section.appearance => l10nNow.desktopApplication,
    _Section.storage => l10nNow.desktopApplication,
    _Section.tools => l10nNow.desktopApplication,
    _Section.stats => l10nNow.desktopApplication,
    _Section.about => l10nNow.desktopApplication,
  };
  final IconData icon;

  final Widget? page;
}

/// Keep settings navigation inside the content pane. Lazily retain each visited
/// section, including its subpages and drafts, when switching sidebar entries.
class DesktopProfilePage extends ConsumerStatefulWidget {
  const DesktopProfilePage({super.key, this.toolsKey, this.openTools = false});

  final GlobalKey? toolsKey;
  final bool openTools;

  @override
  ConsumerState<DesktopProfilePage> createState() => _DesktopProfilePageState();
}

class _DesktopProfilePageState extends ConsumerState<DesktopProfilePage>
    with AutomaticKeepAliveClientMixin {
  _Section _selected = _Section.account;
  final _visited = {_Section.account};
  final _navigators = {
    for (final section in _Section.values) section: GlobalKey<NavigatorState>(),
  };

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (widget.openTools) {
      _selected = _Section.tools;
      _visited.add(_Section.tools);
    }
  }

  @override
  void didUpdateWidget(DesktopProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.openTools && !oldWidget.openTools) {
      _selected = _Section.tools;
      _visited.add(_Section.tools);
    }
  }

  void _select(_Section section) {
    if (_selected == section) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _selected = section;
      _visited.add(section);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final active = ref.watch(shellIndexProvider) == kTabProfile;
    final showTools = ref.watch(
      themeSettingsProvider.select((settings) => settings.showTools),
    );
    ref.listen<bool>(
      themeSettingsProvider.select((settings) => settings.showTools),
      (_, show) {
        if (show && _selected == _Section.tools) _select(_Section.appearance);
      },
    );
    final sections = _Section.values.where(
      (section) => section != _Section.tools || !showTools,
    );
    final alignment = ref.watch(
      themeSettingsProvider.select((settings) => settings.pageAlignment),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final sidebar = constraints.maxWidth >= 700;
        final scheme = context.scheme;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            sidebar ? 20 : 12,
            16,
            sidebar ? 20 : 12,
            16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.only(left: sidebar ? 22 : 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10nNow
                            .desktopAccountsCreationPreferencesAndAppSettings,
                        style: context.texts.bodySmall!.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (!sidebar)
                      PopupMenuButton<_Section>(
                        key: const ValueKey('profile-section-menu'),
                        tooltip: l10nNow.desktopSettingsCategories,
                        initialValue: _selected,
                        onSelected: _select,
                        itemBuilder: (context) => [
                          for (final section in sections)
                            CheckedPopupMenuItem(
                              value: section,
                              checked: section == _selected,
                              child: Text(section.label),
                            ),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_selected.label),
                              const SizedBox(width: 8),
                              const Icon(Icons.expand_more, size: 18),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (sidebar) ...[
                      SizedBox(
                        key: const ValueKey('profile-sidebar'),
                        width: constraints.maxWidth >= 1100 ? 208 : 184,
                        child: Material(
                          color: scheme.surfaceContainerLow,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                            side: BorderSide(
                              color: scheme.outlineVariant.withValues(
                                alpha: .4,
                              ),
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                            children: [
                              for (final group in [
                                l10nNow.desktopAccountsAndServices,
                                l10nNow.desktopCreationPreferences,
                                l10nNow.desktopApplication,
                              ]) ...[
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    18,
                                    12,
                                    8,
                                  ),
                                  child: Text(
                                    group,
                                    style: context.texts.labelSmall!.copyWith(
                                      color: scheme.outline,
                                    ),
                                  ),
                                ),
                                for (final section in sections.where(
                                  (s) => s.group == group,
                                ))
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 4),
                                    child: ListTile(
                                      key: ValueKey(
                                        'profile-section-${section.name}',
                                      ),
                                      dense: true,
                                      minTileHeight: 48,
                                      visualDensity: VisualDensity.standard,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 12,
                                          ),
                                      minLeadingWidth: 20,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      selected: _selected == section,
                                      selectedTileColor: scheme.primaryContainer
                                          .withValues(alpha: .65),
                                      selectedColor: scheme.primary,
                                      leading: Icon(section.icon, size: 22),
                                      title: Text(
                                        section.label,
                                        style: TextStyle(
                                          fontWeight: _selected == section
                                              ? FontWeight.w700
                                              : FontWeight.w400,
                                        ),
                                      ),
                                      onTap: () => _select(section),
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                    ],
                    Expanded(
                      child: Align(
                        alignment: alignment == PageAlignment.center
                            ? Alignment.topCenter
                            : Alignment.topLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1000),
                          child: IndexedStack(
                            key: const ValueKey('profile-content'),
                            index: _selected.index,
                            sizing: StackFit.expand,
                            children: [
                              for (final section in _Section.values)
                                if (section == _Section.tools)
                                  !showTools &&
                                          (widget.toolsKey != null ||
                                              _visited.contains(section))
                                      ? DesktopToolsPage(
                                          key: widget.toolsKey,
                                          active:
                                              active && _selected == section,
                                        )
                                      : const SizedBox.shrink()
                                else
                                  _visited.contains(section)
                                      ? TickerMode(
                                          enabled: _selected == section,
                                          child: ExcludeFocus(
                                            excluding: _selected != section,
                                            child: NavigatorPopHandler<Object?>(
                                              enabled:
                                                  active &&
                                                  _selected == section,
                                              onPopWithResult: (result) {
                                                final navigator =
                                                    _navigators[section]!
                                                        .currentState!;
                                                if (active &&
                                                    _selected == section &&
                                                    navigator.canPop()) {
                                                  navigator.pop(result);
                                                }
                                              },
                                              child: Navigator(
                                                key: _navigators[section],
                                                onGenerateRoute: (_) =>
                                                    MaterialPageRoute<void>(
                                                      builder: (_) =>
                                                          section.page!,
                                                    ),
                                              ),
                                            ),
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
