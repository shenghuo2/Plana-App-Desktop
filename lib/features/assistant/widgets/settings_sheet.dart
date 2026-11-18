/// 助手设置弹层。版式与编辑器设置同源([SettingSheet] / [SettingRow])——
/// 同一个 app 里两处设置长得不一样,用户会以为自己进错了地方。
///
/// 「自动」那几项都是把默认的手动改成自动,默认一律关着:这套流程的地基是
/// 「AI 碰创作页、花点数出图,两件事都得用户按一下」,打开哪一项都是用户明知
/// 自己在放权,不能替他决定。
library;

import '../refusal_keywords_page.dart';
import '../endpoints_page.dart';
import '../../../l10n/l10n.dart';

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/desktop.dart';
import '../../../core/ui/setting_row.dart';
import '../../../core/util/haptics.dart';
import '../../generate/prompt_sections.dart' show SectionImport;
import '../../generate/widgets/common.dart' show dropFocusSoon, hintSnack;
import '../agent_model.dart'
    show assistantBotAuthorizedProvider, assistantEndpointProvider;
import '../assistant_settings.dart';
import '../assistant_state.dart';
import '../preset_rules.dart';
import '../rules_page.dart';
import 'desktop_settings_dropdown.dart';

Future<void> showAssistantSettings(BuildContext context) async {
  if (ProviderScope.containerOf(
    context,
    listen: false,
  ).read(desktopModeProvider)) {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭助手设置',
      barrierColor: Colors.black.withValues(alpha: .12),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) => const _DesktopSettingsPanel(),
      transitionBuilder: (_, animation, _, child) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(begin: const Offset(.08, 0), end: Offset.zero)
              .animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
          child: child,
        ),
      ),
    );
    dropFocusSoon();
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // 抓手和圆角由 SettingSheet 自己画(与编辑器设置同一套),
    // 所以这儿把系统那份关掉、底色让给它。
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .18),
    builder: (_) => const _SettingsSheet(),
  );
  dropFocusSoon();
}

class _DesktopSettingsPanel extends ConsumerWidget {
  const _DesktopSettingsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(assistantSettingsProvider).value;
    final n = ref.read(assistantSettingsProvider.notifier);
    final authorized = ref.watch(assistantBotAuthorizedProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget section(String title, List<Widget> rows) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Material(
            color: scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: .65),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                      color: scheme.outlineVariant.withValues(alpha: .45),
                    ),
                  rows[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
    Widget page(List<Widget> children) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );

    return SafeArea(
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            key: const ValueKey('desktop-assistant-settings'),
            width: 440,
            height: 620,
            child: Theme(
              data: theme.copyWith(
                textTheme: theme.textTheme.copyWith(
                  bodyLarge: theme.textTheme.bodyLarge?.copyWith(fontSize: 13),
                  labelLarge: theme.textTheme.labelLarge?.copyWith(
                    fontSize: 12,
                  ),
                  labelSmall: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 11,
                    height: 1.5,
                  ),
                ),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Material(
                color: scheme.surface,
                elevation: 10,
                shadowColor: Colors.black26,
                borderRadius: BorderRadius.circular(20),
                clipBehavior: Clip.antiAlias,
                child: DefaultTabController(
                  length: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(9),
                              decoration: BoxDecoration(
                                color: scheme.primaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.tune,
                                color: scheme.onPrimaryContainer,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10nNow.assistantSettings,
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  SizedBox(height: 3),
                                  Text(
                                    l10nNow.desktopChatAndCreationPreferences,
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: l10nNow.desktopCloseAssistantSettings,
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close, size: 20),
                            ),
                          ],
                        ),
                      ),
                      const TabBar(
                        labelStyle: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        tabs: [
                          Tab(text: '对话'),
                          Tab(text: '生成'),
                          Tab(text: '资料与规则'),
                        ],
                      ),
                      Expanded(
                        child: s == null
                            ? const Center(child: CircularProgressIndicator())
                            : TabBarView(
                                children: [
                                  page([
                                    section('阅读与回复', [
                                      SettingStepperRow(
                                        icon: Icons.format_size,
                                        title: l10nNow.settingMessageSize,
                                        desc: '对话消息的文字大小',
                                        value: s.fontSize,
                                        min: AssistantSettings.fontSizeMin,
                                        max: AssistantSettings.fontSizeMax,
                                        step: AssistantSettings.fontSizeStep,
                                        format: (v) => v.toStringAsFixed(0),
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(fontSize: v),
                                        ),
                                      ),
                                      SettingRow(
                                        icon: Icons.keyboard_outlined,
                                        title: l10nNow.streamOutput,
                                        desc: '逐字显示回复',
                                        value: s.stream,
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(stream: v),
                                        ),
                                      ),
                                      SettingRow(
                                        icon: Icons.image_outlined,
                                        title: l10nNow.inlineImages,
                                        desc: '生成图片仍会保存至图库',
                                        value: s.inlineImage,
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(inlineImage: v),
                                        ),
                                      ),
                                    ]),
                                    section('侧栏图片按钮', [
                                      SettingRow(
                                        icon: Icons.image_outlined,
                                        title: l10nNow.addImages,
                                        desc: '在创作页侧栏显示文件选择按钮，支持多选',
                                        value: s.showSidebarImagePicker,
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(
                                            showSidebarImagePicker: v,
                                          ),
                                        ),
                                      ),
                                      SettingRow(
                                        icon: Icons.photo_library_outlined,
                                        title: l10nNow.desktopChooseFromHistory,
                                        desc: '在创作页侧栏显示历史图片按钮',
                                        value: s.showSidebarHistoryPicker,
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(
                                            showSidebarHistoryPicker: v,
                                          ),
                                        ),
                                      ),
                                      SettingRow(
                                        icon: Icons.content_paste,
                                        title: l10nNow.desktopPasteFromClipboard,
                                        desc: '在创作页侧栏显示图片粘贴按钮',
                                        value: s.showSidebarClipboardButton,
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(
                                            showSidebarClipboardButton: v,
                                          ),
                                        ),
                                      ),
                                    ]),
                                    section('对话记忆', [
                                      ..._retrySettings(context, s, n),
                                      SettingStepperRow(
                                        icon: Icons.history,
                                        title: l10nNow.contextTurns,
                                        desc: '每次发送带上最近几轮对话',
                                        value: s.historyTurns.toDouble(),
                                        min: AssistantSettings.historyTurnsMin
                                            .toDouble(),
                                        max: AssistantSettings.historyTurnsMax
                                            .toDouble(),
                                        step: 1,
                                        format: (v) => v.toStringAsFixed(0),
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(
                                            historyTurns: v.round(),
                                          ),
                                        ),
                                      ),
                                    ]),
                                  ]),
                                  page([
                                    section('提示词结果', [
                                      SettingRow(
                                        icon: Icons.notes,
                                        title: l10nNow.plainTextFormat,
                                        desc: '提示词只显示为文本，不导入也不出图',
                                        value: s.noDraw,
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(noDraw: v),
                                        ),
                                      ),
                                      _DesktopImportChoice(
                                        enabled: !s.noDraw,
                                        value: s.importTo,
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(importTo: v),
                                        ),
                                      ),
                                    ]),
                                    section('自动操作', [
                                      SettingRow(
                                        icon: Icons.draw_outlined,
                                        title: l10nNow.autoWrite,
                                        desc: '生成的提示词自动写回创作页',
                                        enabled: !s.noDraw,
                                        value: s.autoImport,
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(autoImport: v),
                                        ),
                                      ),
                                      SettingRow(
                                        icon: Icons.bolt_outlined,
                                        title: l10nNow.autoDraw,
                                        desc: '提示词完成后立即生成图片',
                                        enabled: !s.noDraw,
                                        value: s.autoGenerate,
                                        onChanged: (v) => n.patch(
                                          (o) => o.copyWith(autoGenerate: v),
                                        ),
                                      ),
                                    ]),
                                    if (s.noDraw)
                                      Text(
                                        l10nNow.desktopPlainTextIsOnAutomaticImportAndGeneration,
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.6,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                  ]),
                                  page([
                                    section('参考资料', [
                                      Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              l10nNow.libraryScope,
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              l10nNow.desktopSourcesUsedToLookUpArtistPromptsAnd,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: scheme.onSurfaceVariant,
                                              ),
                                            ),
                                            const SizedBox(height: 12),
                                            DesktopSettingsDropdown<
                                              LibraryScope
                                            >(
                                              id: 'assistant-library-dropdown',
                                              label: l10nNow.libraryScope,
                                              value: effectiveLibraryScope(
                                                s.libraryScope,
                                                botAuthorized: authorized,
                                              ),
                                              options: LibraryScope.values,
                                              labelOf: libraryScopeLabel,
                                              optionEnabled: (scope) =>
                                                  libraryScopeAllowed(
                                                    scope,
                                                    botAuthorized: authorized,
                                                  ),
                                              optionNote: (scope) =>
                                                  libraryScopeAllowed(
                                                    scope,
                                                    botAuthorized: authorized,
                                                  )
                                                  ? null
                                                  : '需要 Bot 授权',
                                              onChanged: (scope) => n.patch(
                                                (o) => o.copyWith(
                                                  libraryScope: scope,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ]),
                                    section('创作规则', [
                                      SettingNavRow(
                                        icon: Icons.rule_outlined,
                                        title: l10nNow.rulePresets,
                                        desc: '生成提示词时遵循的规则',
                                        value: _rulesValue(ref),
                                        onTap: () => Navigator.of(context).push(
                                          MaterialPageRoute<void>(
                                            builder: (_) =>
                                                const RulesPresetPage(),
                                          ),
                                        ),
                                      ),
                                    ]),
                                    section('记录', [
                                      SettingNavRow(
                                        icon: Icons.file_download_outlined,
                                        title: l10nNow.exportChatLog,
                                        desc: '保存当前对话的请求与回复',
                                        value: '',
                                        onTap: () => _exportTrace(context, ref),
                                      ),
                                    ]),
                                  ]),
                                ],
                              ),
                      ),
                      Divider(
                        height: 1,
                        color: scheme.outlineVariant.withValues(alpha: .5),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          l10nNow.desktopChangesAreSavedAutomatically,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Give the explanation and the full-width selection field separate space.
class _DesktopImportChoice extends StatelessWidget {
  const _DesktopImportChoice({
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final SectionImport value;
  final bool enabled;
  final ValueChanged<SectionImport> onChanged;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : .42,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.splitscreen_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: SettingRowTexts(
                    title: l10nNow.importMode,
                    desc: '提示词写入主提示词的位置',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DesktopSettingsDropdown<SectionImport>(
              id: 'assistant-import-dropdown',
              label: l10nNow.importMode,
              value: value,
              enabled: enabled,
              options: SectionImport.values,
              labelOf: sectionImportLabel,
              onChanged: (mode) {
                Haptics.selection();
                onChanged(mode);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSheet extends ConsumerWidget {
  const _SettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(assistantSettingsProvider).value;
    final n = ref.read(assistantSettingsProvider.notifier);
    final authorized = ref.watch(assistantBotAuthorizedProvider);
    final customEndpoint = ref.watch(assistantEndpointProvider) != null;
    return SettingSheet(
      title: l10nNow.assistantSettings,
      children: [
        if (s == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          settingSection(context, l10nNow.settingDisplay),
          SettingStepperRow(
            icon: Icons.format_size,
            title: l10nNow.settingMessageSize,
            desc: '对话消息的文字显示大小',
            value: s.fontSize,
            min: AssistantSettings.fontSizeMin,
            max: AssistantSettings.fontSizeMax,
            step: AssistantSettings.fontSizeStep,
            format: (v) => v.toStringAsFixed(0),
            onChanged: (v) => n.patch((o) => o.copyWith(fontSize: v)),
          ),
          SettingRow(
            icon: Icons.keyboard_outlined,
            title: l10nNow.streamOutput,
            desc: '逐字显示回复',
            value: s.stream,
            onChanged: (v) => n.patch((o) => o.copyWith(stream: v)),
          ),
          settingSection(context, l10nNow.settingDraw),
          SettingRow(
            icon: Icons.notes,
            title: l10nNow.plainTextFormat,
            desc: '提示词只显示为文本,不导入也不出图',
            value: s.noDraw,
            onChanged: (v) => n.patch((o) => o.copyWith(noDraw: v)),
          ),
          SettingChoiceRow<SectionImport>(
            icon: Icons.splitscreen_outlined,
            title: l10nNow.importMode,
            desc: '提示词写入创作页主提示词的位置',
            enabled: !s.noDraw,
            value: s.importTo,
            options: SectionImport.values,
            labelOf: sectionImportLabel,
            onChanged: (v) => n.patch((o) => o.copyWith(importTo: v)),
          ),
          settingSection(context, l10nNow.aiChoice),
          // 纯文本格式开着时这两项不会发生,淡显
          SettingRow(
            icon: Icons.bolt_outlined,
            title: l10nNow.autoDraw,
            desc: '提示词生成完成后立即开始出图',
            enabled: !s.noDraw,
            value: s.autoGenerate,
            onChanged: (v) => n.patch((o) => o.copyWith(autoGenerate: v)),
          ),
          SettingRow(
            icon: Icons.image_outlined,
            title: l10nNow.inlineImages,
            desc: '生成的图片显示在对话内,同时保存至图库',
            value: s.inlineImage,
            onChanged: (v) => n.patch((o) => o.copyWith(inlineImage: v)),
          ),
          SettingRow(
            icon: Icons.draw_outlined,
            title: l10nNow.autoWrite,
            desc: '生成的提示词自动写回创作页,无需手动导入',
            enabled: !s.noDraw,
            value: s.autoImport,
            onChanged: (v) => n.patch((o) => o.copyWith(autoImport: v)),
          ),
          settingSection(context, l10nNow.settingChat),
          ..._retrySettings(context, s, n),
          SettingStepperRow(
            icon: Icons.history,
            title: l10nNow.contextTurns,
            desc: '每次发送带上最近几轮对话',
            value: s.historyTurns.toDouble(),
            min: AssistantSettings.historyTurnsMin.toDouble(),
            max: AssistantSettings.historyTurnsMax.toDouble(),
            step: AssistantSettings.historyTurnsStep.toDouble(),
            format: (v) => v.toStringAsFixed(0),
            onChanged: (v) =>
                n.patch((o) => o.copyWith(historyTurns: v.round())),
          ),
          settingSection(context, l10nNow.settingLibrary),
          SettingChoiceRow<LibraryScope>(
            icon: Icons.library_books_outlined,
            title: l10nNow.libraryScope,
            desc: '查询画师串与角色时使用的资料来源',
            value: effectiveLibraryScope(
              s.libraryScope,
              botAuthorized: authorized,
            ),
            options: LibraryScope.values,
            labelOf: libraryScopeLabel,
            optionEnabled: (o) =>
                libraryScopeAllowed(o, botAuthorized: authorized),
            optionNote: (o) => libraryScopeAllowed(o, botAuthorized: authorized)
                ? libraryScopeDesc(o)
                : '需要 Bot 授权',
            onChanged: (v) => n.patch((o) => o.copyWith(libraryScope: v)),
          ),
          SettingRow(
            icon: Icons.person_outline,
            title: l10nNow.ocPlaceholder,
            desc: customEndpoint
                ? '本地与公共 OC 只给 AI 占位符，出图时还原；调整原设时请关闭'
                : '仅自定义接口渠道可用',
            value: customEndpoint && s.ocPlaceholders,
            enabled: customEndpoint,
            onChanged: (v) => n.patch((o) => o.copyWith(ocPlaceholders: v)),
          ),
          settingSection(context, l10nNow.settingRules),
          SettingNavRow(
            icon: Icons.rule_outlined,
            title: l10nNow.rulePresets,
            desc: '生成提示词时遵循的规则',
            value: _rulesValue(ref),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RulesPresetPage()),
            ),
          ),
          settingSection(context, l10nNow.settingDebug),
          SettingNavRow(
            icon: Icons.bug_report_outlined,
            title: l10nNow.exportChatLog,
            desc: '当前对话每一轮发给 AI 的内容和返回',
            value: switch (ref.read(assistantProvider.notifier).traceCount) {
              0 => '',
              final n => '$n 轮',
            },
            onTap: () => _exportTrace(context, ref),
          ),
        ],
      ],
    );
  }
}

/// 导出成一个文本文件,存到用户选的位置。内容见 `renderTraceExport`。
Future<void> _exportTrace(BuildContext context, WidgetRef ref) async {
  if (ref.read(assistantProvider).msgs.isEmpty) {
    hintSnack(context, l10nNow.chatEmpty, icon: Icons.info_outline);
    return;
  }
  try {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final path = await FilePicker.platform.saveFile(
      fileName: 'plana-assistant-$stamp.txt',
      bytes: utf8.encode(ref.read(assistantProvider.notifier).exportTrace()),
    );
    if (path != null && context.mounted) {
      hintSnack(context, l10nNow.chatLogExported, icon: Icons.check_circle_outline);
    }
  } catch (e) {
    if (context.mounted) {
      hintSnack(context, '导出失败:$e', icon: Icons.error_outline);
    }
  }
}

/// 规则那一行右边的状态:两个模型都用默认规则就是「默认」;都用同一份导入的预设
/// 就报它的名字;两边各用各的只说「自定义」,名字留给点进去的那一页。
String _rulesValue(WidgetRef ref) {
  final lib = ref.watch(rulesLibraryProvider).value;
  if (lib == null) return '';
  final used = [for (final f in RulesFamily.values) lib.activeFor(f)];
  if (used.every((p) => p.isDefault)) return '默认';
  if (used.every((p) => p.id == used.first.id)) return used.first.name;
  return '自定义';
}

List<Widget> _retrySettings(BuildContext context, AssistantSettings s, AssistantSettingsNotifier n) {
  final l = context.l10n;
  return [
    SettingNavRow(icon: Icons.dns_outlined, title: l.myEndpoints, desc:'', value:'',
      onTap:()=>openEndpointsPage(context)),
    SettingStepperRow(icon:Icons.refresh,title:l.failRetries,desc:l.failRetriesDesc,value:s.retries.toDouble(),
      min:0,max:AssistantSettings.retriesMax.toDouble(),step:1,format:(v)=>v.toInt().toString(),
      onChanged:(v)=>n.patch((old)=>old.copyWith(retries:v.toInt()))),
    SettingStepperRow(icon:Icons.replay,title:l.refusalRetries,desc:l.refusalRetriesDesc,value:s.rerolls.toDouble(),
      min:0,max:AssistantSettings.retriesMax.toDouble(),step:1,format:(v)=>v.toInt().toString(),
      onChanged:(v)=>n.patch((old)=>old.copyWith(rerolls:v.toInt()))),
    SettingNavRow(icon:Icons.text_fields,title:l.refusalKeywords,desc:l.refusalKeywordsDesc,
      value:s.refusalKeywords.length.toString(),
      onTap:()=>Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>const RefusalKeywordsPage()))),
  ];
}
