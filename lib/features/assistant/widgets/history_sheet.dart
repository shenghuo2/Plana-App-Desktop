/// 历史会话。标题取第一句用户输入,副行取最后一句 AI 回复,右下角只放一个数字:
/// 这段对话最终攒出多少 tag —— 那是用户回头找它的真正理由。
library;

import '../../../l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/desktop.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/desktop_popover.dart';
import '../../generate/widgets/common.dart' show confirmDialog, dropFocusSoon;
import '../assistant_models.dart';
import '../assistant_state.dart';

Future<void> showHistorySheet(BuildContext context) async {
  if (ProviderScope.containerOf(
    context,
    listen: false,
  ).read(desktopModeProvider)) {
    await showDesktopPopover(
      context,
      width: 380,
      maxHeight: 460,
      builder: (_) => const AssistantHistoryPanel(),
    );
    return;
  }
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _HistorySheet(),
  );
  dropFocusSoon();
}

/// Shared by the desktop history popover and the main assistant's left rail.
class AssistantHistoryPanel extends ConsumerStatefulWidget {
  const AssistantHistoryPanel({
    super.key,
    this.sidebar = false,
    this.onNewChat,
  });
  final bool sidebar;
  final VoidCallback? onNewChat;

  @override
  ConsumerState<AssistantHistoryPanel> createState() =>
      _AssistantHistoryPanelState();
}

class _AssistantHistoryPanelState extends ConsumerState<AssistantHistoryPanel> {
  String _query = '';

  Future<void> _clear(int count) async {
    final ok = await confirmDialog(
      context,
      title: l10nNow.clearHistoryQ,
      message: '$count 段对话都会删掉,当前对话和创作页不受影响。',
      confirmLabel: '清空',
    );
    if (ok && mounted) ref.read(assistantProvider.notifier).clearSessions();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final state = ref.watch(assistantProvider);
    final notifier = ref.read(assistantProvider.notifier);
    final query = _query.trim().toLowerCase();
    bool matches(ArchivedSession s) =>
        query.isEmpty ||
        '${s.title}\n${s.preview}'.toLowerCase().contains(query);
    final sessions = state.history.where(matches).toList();
    final currentId = state.currentSession?.id;
    final list = ListView(
      shrinkWrap: !widget.sidebar,
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      children: [
        if (widget.sidebar && sessions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: Text(
              l10nNow.chatHistory,
              style: context.texts.labelSmall!.copyWith(color: scheme.outline),
            ),
          ),
        for (final session in sessions)
          _DesktopSessionRow(
            key: ValueKey('assistant-session-${session.id}'),
            session: session,
            current: currentId == session.id,
            onOpen: state.running
                ? null
                : () {
                    notifier.openSession(session.id);
                    if (!widget.sidebar) Navigator.pop(context);
                  },
            onDelete: () => notifier.deleteSession(session.id),
            onPin: () => notifier.toggleSessionPin(session.id),
            onRename: (title) => notifier.renameSession(session.id, title),
          ),
        if (sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
            child: Text(
              query.isNotEmpty ? '没有匹配的会话' : '还没有历史会话\n普通聊天开始后会显示在这里。',
              style: context.texts.bodySmall!.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.7,
              ),
            ),
          ),
      ],
    );
    final clearHistoryButton = state.sessions.isEmpty
        ? null
        : IconButton(
            tooltip: l10nNow.desktopClearConversationHistory,
            visualDensity: VisualDensity.compact,
            onPressed: () => _clear(state.sessions.length),
            icon: const Icon(Icons.delete_sweep_outlined, size: 18),
          );
    return ColoredBox(
      color: scheme.surfaceContainerLow,
      child: Column(
        mainAxisSize: widget.sidebar ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.sidebar)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10nNow.chatHistory,
                      style: context.texts.titleSmall!.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  ?clearHistoryButton,
                  IconButton(
                    tooltip: l10nNow.close,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
          if (widget.sidebar)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: state.running ? null : widget.onNewChat,
                      icon: const Icon(Icons.edit_square, size: 18),
                      label: Text(l10nNow.newChat),
                    ),
                  ),
                  if (clearHistoryButton != null) ...[
                    const SizedBox(width: 8),
                    clearHistoryButton,
                  ],
                ],
              ),
            ),
          if (widget.sidebar || state.history.length >= 6 || _query.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: TextField(
                key: const ValueKey('assistant-history-search'),
                onChanged: (value) => setState(() => _query = value),
                style: context.texts.bodySmall,
                decoration: InputDecoration(
                  hintText: l10nNow.desktopSearchConversations,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  isDense: true,
                  filled: true,
                  fillColor: scheme.surface,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          if (widget.sidebar) Expanded(child: list) else Flexible(child: list),
        ],
      ),
    );
  }
}

class _DesktopSessionRow extends StatelessWidget {
  const _DesktopSessionRow({
    super.key,
    required this.session,
    this.current = false,
    this.onOpen,
    required this.onDelete,
    required this.onPin,
    required this.onRename,
  });
  final ArchivedSession session;
  final bool current;
  final VoidCallback? onOpen;
  final VoidCallback onDelete;
  final VoidCallback onPin;
  final ValueChanged<String> onRename;

  Future<void> _menu(BuildContext anchor) async {
    final action = await showDesktopPopover<String>(
      anchor,
      width: 200,
      maxHeight: 160,
      builder: (context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('assistant-session-rename'),
              leading: const Icon(Icons.drive_file_rename_outline, size: 20),
              title: Text(l10nNow.rename),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              key: const ValueKey('assistant-session-delete'),
              leading: Icon(
                Icons.delete_outline,
                size: 20,
                color: context.scheme.error,
              ),
              title: Text(l10nNow.delete, style: TextStyle(color: context.scheme.error)),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!anchor.mounted) return;
    if (action == 'delete') {
      onDelete();
    } else if (action == 'rename') {
      final name = await showDialog<String>(
        context: anchor,
        builder: (_) => _RenameConversation(title: session.title),
      );
      if (name != null && anchor.mounted) onRename(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        selected: current,
        child: Material(
          color: current ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.bodySmall!.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${_when(session.at)} · ${session.turns} 轮',
                          style: context.texts.labelSmall!.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (session.preview.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            session.preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.texts.labelSmall!.copyWith(
                              color: scheme.outline,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    key: ValueKey('assistant-session-pin-${session.id}'),
                    tooltip: session.meta.pinned ? '取消置顶' : '置顶',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 36,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: onPin,
                    icon: Icon(
                      session.meta.pinned
                          ? Icons.push_pin
                          : Icons.push_pin_outlined,
                      size: 17,
                      color: session.meta.pinned
                          ? scheme.primary
                          : scheme.outline,
                    ),
                  ),
                  Builder(
                    builder: (anchor) => IconButton(
                      key: ValueKey('assistant-session-menu-${session.id}'),
                      tooltip: l10nNow.desktopConversationActions,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 36,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: () => _menu(anchor),
                      icon: const Icon(Icons.more_horiz, size: 19),
                    ),
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

class _RenameConversation extends StatefulWidget {
  const _RenameConversation({required this.title});
  final String title;
  @override
  State<_RenameConversation> createState() => _RenameConversationState();
}

class _RenameConversationState extends State<_RenameConversation> {
  late final _name = TextEditingController(text: widget.title)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.title.length,
    );
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isNotEmpty) Navigator.pop(context, _name.text.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(l10nNow.desktopRenameConversation),
    content: SizedBox(
      width: 360,
      child: TextField(
        key: const ValueKey('assistant-session-name'),
        controller: _name,
        autofocus: true,
        maxLength: 100,
        decoration: InputDecoration(labelText: l10nNow.desktopConversationName),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _save(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(l10nNow.cancel),
      ),
      FilledButton(
        onPressed: _name.text.trim().isEmpty ? null : _save,
        child: Text(l10nNow.save),
      ),
    ],
  );
}

class _HistorySheet extends ConsumerWidget {
  const _HistorySheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final sessions = ref.watch(assistantProvider.select((s) => s.sessions));
    final n = ref.read(assistantProvider.notifier);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 10, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10nNow.chatHistory,
                      style: context.texts.titleMedium!.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (sessions.isNotEmpty)
                    TextButton(
                      onPressed: () async {
                        final ok = await confirmDialog(
                          context,
                          title: l10nNow.clearHistoryQ,
                          message: '${sessions.length} 段对话都会删掉,已经写进创作页的改动不受影响。',
                          confirmLabel: '清空',
                        );
                        if (ok) n.clearSessions();
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.error,
                        minimumSize: const Size(0, 44),
                      ),
                      child: Text(l10nNow.clear),
                    ),
                ],
              ),
            ),
            if (sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 30, 20, 46),
                child: Text(
                  l10nNow.noArchivedChats,
                  textAlign: TextAlign.center,
                  style: context.texts.bodySmall!.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.7,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  itemCount: sessions.length,
                  itemBuilder: (context, i) => _Row(
                    s: sessions[i],
                    onOpen: () {
                      n.openSession(sessions[i].id);
                      Navigator.pop(context);
                    },
                    onDelete: () => n.deleteSession(sessions[i].id),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.s, required this.onOpen, required this.onDelete});

  final ArchivedSession s;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    // 左滑删单条(原生手势);顶栏「清空」是兜底入口,不让手势成为唯一路径。
    return Dismissible(
      key: ValueKey(s.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        margin: const EdgeInsets.only(bottom: 9),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Material(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.bodyMedium!.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (s.hasError) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.error_outline,
                          size: 15,
                          color: scheme.error,
                        ),
                      ],
                    ],
                  ),
                  if (s.preview.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      s.preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodySmall!.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  DefaultTextStyle(
                    style: context.texts.labelSmall!.copyWith(
                      color: scheme.outline,
                    ),
                    child: Row(
                      children: [
                        Text(_when(s.at)),
                        const SizedBox(width: 10),
                        Text('${s.turns} 轮'),
                        if (s.tagCount > 0) ...[
                          const SizedBox(width: 10),
                          Text('${s.tagCount} tag'),
                        ],
                      ],
                    ),
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

/// 相对时间:今天报时分,昨天报「昨天 HH:mm」,更早报「M/d」。
String _when(int ms) {
  if (ms <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(t.year, t.month, t.day);
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  final diff = today.difference(that).inDays;
  if (diff == 0) {
    return now.difference(t).inMinutes < 3 ? '刚刚' : hm;
  }
  if (diff == 1) return '昨天 $hm';
  return '${t.month}/${t.day}';
}
