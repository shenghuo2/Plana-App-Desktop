import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../l10n/l10n.dart';
import '../agent_model.dart';
import '../endpoints_page.dart' show openEndpointsPage, planHubId;
import '../model_catalog.dart';
import '../subscription/plan_accounts.dart';
import 'assistant_tag.dart';
import 'catalog_model_picker.dart';

const planUsageUrl = 'https://chatgpt.com/settings/usage';
Future<void> _link(BuildContext context, String url) async {
  if (!await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication) &&
      context.mounted) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: SelectableText(url)));
  }
}

class PlanNotice extends StatefulWidget {
  const PlanNotice({super.key, required this.first});
  final bool first;
  @override
  State<PlanNotice> createState() => _PlanNoticeState();
}

class _PlanNoticeState extends State<PlanNotice> with WidgetsBindingObserver {
  late int seconds = widget.first ? 10 : 0;
  Timer? timer;
  bool foreground = true;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (seconds > 0) {
      timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!foreground || ModalRoute.of(context)?.isCurrent == false) return;
        setState(() => seconds--);
        if (seconds == 0) t.cancel();
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AlertDialog(
      scrollable: true,
      title: Text(l.planNotice),
      content: SizedBox(
        width: 430,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.planDisclosure),
            const SizedBox(height: 12),
            Text(l.planConduct),
            Wrap(
              children: [
                TextButton(
                  onPressed: () => _link(
                    context,
                    'https://openai.com/policies/sign-in-with-chatgpt-terms/',
                  ),
                  child: Text(l.planTerms),
                ),
                TextButton(
                  onPressed: () => _link(
                    context,
                    'https://openai.com/policies/usage-policies/',
                  ),
                  child: Text(l.planPolicy),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l.cancel),
        ),
        FilledButton(
          key: const ValueKey('plan-consent'),
          onPressed: seconds > 0 ? null : () => Navigator.pop(context, true),
          child: Text(
            seconds > 0 ? '${l.planConfirm} ($seconds s)' : l.planConfirm,
          ),
        ),
      ],
    );
  }
}

Future<void> openPlanAccounts(
  BuildContext context, {
  required bool login,
  VoidCallback? onManage,
}) async {
  final manage = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PlanAccountsPanel(login: login),
  );
  if (manage != true || !context.mounted) return;
  if (onManage != null) {
    onManage();
  } else {
    await openEndpointsPage(context, editId: planHubId);
  }
}

class PlanAccountsPanel extends ConsumerStatefulWidget {
  const PlanAccountsPanel({
    super.key,
    this.login = false,
    this.embedded = false,
  });
  final bool login;
  final bool embedded;
  @override
  ConsumerState<PlanAccountsPanel> createState() => _AccountsState();
}

class _AccountsState extends ConsumerState<PlanAccountsPanel> {
  bool busy = false;
  String message = '';
  Completer<void>? cancel;
  PlanStore get store => ref.read(planStoreProvider);
  @override
  void initState() {
    super.initState();
    if (widget.login) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_login());
      });
    }
  }

  @override
  void dispose() {
    _cancelLogin();
    super.dispose();
  }

  void _cancelLogin() {
    if (cancel != null && !cancel!.isCompleted) cancel!.complete();
  }

  Future<void> _work(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    } finally {
      if (mounted) {
        ref.invalidate(planAccountsProvider);
        setState(() => busy = false);
      }
    }
  }

  Future<void> _select(String id) async {
    final accountsStore = store;
    final prefs = ref.read(assistantModelPrefProvider.notifier);
    final old = planChoiceOf(await ref.read(assistantModelPrefProvider.future));
    if (!mounted) return;
    await accountsStore.activate(id);
    final cached = (await accountsStore.accounts()).find(id);
    if (!mounted || cached == null) return;
    final selected = cached.selectedModels;
    await prefs.set(
      planModelKey(
        id,
        selected.containsKey(old?.model)
            ? old!.model
            : selected.keys.firstOrNull ?? '',
      ),
    );
  }

  Future<void> _pickModels(String id) async {
    final accountsStore = store;
    PlanProfile profile;
    try {
      profile = await accountsStore.refreshModels(id);
    } catch (e) {
      if (!mounted) return;
      final accounts = await accountsStore.accounts();
      final cached = accounts.active;
      if (cached == null ||
          cached.id != id ||
          !cached.connected ||
          cached.models.isEmpty) {
        rethrow;
      }
      profile = cached;
      if (mounted) {
        setState(() => message = '$e · ${context.l10n.planCachedModels}');
      }
    }
    if (!mounted) return;
    final picked = await showCatalogModelPicker(
      context,
      {
        for (final slug in profile.models.keys)
          slug: const CatalogModel(
            EndpointModelKind.chat,
            ModelEvidence.provider,
          ),
      },
      profile.selectedModels.keys.toSet(),
      const {},
      false,
      displayNames: profile.models,
      allowClassification: false,
    );
    if (picked == null || !mounted) return;
    final saved = await store.selectModels(id, picked.selected);
    if (!mounted) return;
    final old = planChoiceOf(await ref.read(assistantModelPrefProvider.future));
    if (old?.client == id &&
        !saved.selectedModels.containsKey(old?.model) &&
        mounted) {
      await ref
          .read(assistantModelPrefProvider.notifier)
          .set(planModelKey(id, saved.selectedModels.keys.firstOrNull ?? ''));
    }
  }

  Future<void> _login([String? id]) => _work(() async {
    final first = !await store.hasSignedIn;
    if (!mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => PlanNotice(first: first),
    );
    if (yes != true || !mounted) return;
    setState(() => cancel = Completer<void>());
    String? connected;
    try {
      connected = await store.signIn(id: id, cancel: cancel!.future);
    } finally {
      if (mounted) setState(() => cancel = null);
    }
    if (connected == null || !mounted) return;
    ref.invalidate(planAccountsProvider);
    if (first) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.l10n.planSection),
          content: Text(ctx.l10n.planReady),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(ctx.l10n.ok),
            ),
          ],
        ),
      );
    }
    if (mounted) await _select(connected);
    if (mounted) await _pickModels(connected);
  });

  Future<void> _rename(PlanProfile p) async {
    var label = p.label;
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.planAccountLabel),
        content: TextFormField(
          initialValue: label,
          autofocus: true,
          maxLength: 64,
          onChanged: (s) => label = s,
          onFieldSubmitted: (s) => Navigator.pop(ctx, s),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, label),
            child: Text(ctx.l10n.save),
          ),
        ],
      ),
    );
    if (value != null && mounted) await _work(() => store.rename(p.id, value));
  }

  bool showSelected = true;

  Widget _account(PlanProfile profile, bool active) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.edit_outlined),
          tooltip: l.rename,
          onPressed: busy ? null : () => _rename(profile),
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: l.planRelogin,
          onPressed: busy ? null : () => _login(profile.id),
        ),
        if (profile.connected)
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: l.planLogout,
            onPressed: busy
                ? null
                : () => _work(() async {
                    final ok = await store.signOut(profile.id);
                    if (!ok && mounted) {
                      setState(() => message = l.planRevocation);
                    }
                  }),
          ),
      ],
    );
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 3,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              profile.displayLabel,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            AssistantTag(profile.shortId),
            if (active) AssistantTag(l.planActive),
          ],
        ),
        if (profile.connected && profile.email.isNotEmpty)
          Text(profile.email)
        else if (!profile.connected)
          Text(l.planRelogin),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: active
            ? scheme.primaryContainer.withValues(alpha: .42)
            : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: active ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('plan-account-${profile.id}'),
          onTap: busy
              ? null
              : profile.connected
              ? () => _work(() => _select(profile.id))
              : () => _login(profile.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: LayoutBuilder(
              builder: (_, constraints) {
                final narrow = constraints.maxWidth < 340;
                return Row(
                  children: [
                    Icon(
                      active
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: active ? scheme.primary : scheme.outline,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [identity, if (narrow) actions],
                      ),
                    ),
                    if (!narrow) actions,
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(planAccountsProvider);
    final accounts = snapshot.value;
    final profiles = accounts?.profiles ?? const <PlanProfile>[];
    final active = accounts?.active;
    final selected = active?.connected == true
        ? active!.selectedModels
        : const <String, String>{};
    final l = context.l10n;
    final theme = Theme.of(context);
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
      child: Row(
        children: [
          Image.asset(
            'assets/assistant/providers/openai.png',
            width: 28,
            height: 28,
            color: theme.colorScheme.onSurface,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 3,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  l.planSection,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                AssistantTag(l.accountsCount(profiles.length)),
              ],
            ),
          ),
          if (widget.embedded)
            Tooltip(
              message: accounts?.enabled == false ? l.enable : l.disable,
              child: Switch(
                value: accounts?.enabled ?? true,
                onChanged: busy || !profiles.any((p) => p.connected)
                    ? null
                    : (v) => _work(() => store.setEnabled(v)),
              ),
            )
          else
            IconButton(
              tooltip: l.close,
              icon: const Icon(Icons.close),
              onPressed: busy ? null : () => Navigator.pop(context),
            ),
        ],
      ),
    );
    final actions = <Widget>[
      FilledButton.icon(
        onPressed: busy ? null : () => _login(),
        icon: const Icon(Icons.person_add_alt, size: 18),
        label: Text(l.planAdd),
      ),
      OutlinedButton.icon(
        key: const ValueKey('plan-refresh-models'),
        onPressed: busy || active == null || !active.connected
            ? null
            : () => _work(() => _pickModels(active.id)),
        icon: const Icon(Icons.refresh, size: 18),
        label: Text(l.catalogRefresh),
      ),
      OutlinedButton.icon(
        onPressed: () => _link(context, planUsageUrl),
        icon: const Icon(Icons.open_in_new, size: 16),
        label: Text(l.planUsageShort),
      ),
    ];
    final buttons = LayoutBuilder(
      builder: (_, constraints) {
        if (!widget.embedded && constraints.maxWidth >= 490) {
          return Row(
            children: [
              for (final (i, button) in actions.indexed) ...[
                if (i != 0) const SizedBox(width: 8),
                Expanded(flex: i == 0 ? 4 : 3, child: button),
              ],
            ],
          );
        }
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: widget.embedded ? WrapAlignment.end : WrapAlignment.start,
          children: actions,
        );
      },
    );
    final body = Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.embedded) ...[
            LayoutBuilder(
              builder: (_, constraints) {
                final title = Text(
                  l.planWorkspaces,
                  style: theme.textTheme.titleMedium,
                );
                if (constraints.maxWidth >= 630) {
                  return Row(
                    children: [
                      Expanded(child: title),
                      Expanded(flex: 3, child: buttons),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [title, const SizedBox(height: 10), buttons],
                );
              },
            ),
            const SizedBox(height: 14),
          ],
          if (snapshot.hasError) SelectableText('${snapshot.error}'),
          if ((snapshot.isLoading && !snapshot.hasValue || busy) &&
              ModalRoute.isCurrentOf(context) != false)
            const LinearProgressIndicator(),
          if (cancel != null) Text(l.planWaiting),
          if (message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SelectableText(message),
            ),
          for (final p in profiles)
            _account(p, p.id == active?.id && p.connected),
          if (profiles.isEmpty && snapshot.hasValue)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(l.planNoAccounts),
            ),
          if (!widget.embedded) ...[const SizedBox(height: 12), buttons],
          const SizedBox(height: 16),
          Material(
            color: theme.colorScheme.surfaceContainerLow,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  dense: true,
                  title: Text(
                    l.planSelectedModels,
                    style: theme.textTheme.titleSmall,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AssistantTag('${selected.length}'),
                      Icon(
                        showSelected ? Icons.expand_less : Icons.expand_more,
                      ),
                    ],
                  ),
                  onTap: () => setState(() => showSelected = !showSelected),
                ),
                if (showSelected && active?.connected == true)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                    child: selected.isEmpty
                        ? Text(l.planNoSelected)
                        : Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              for (final e in selected.entries)
                                Chip(
                                  key: ValueKey('plan-selected-${e.key}'),
                                  avatar: const Icon(Icons.check, size: 16),
                                  label: Text(e.value),
                                ),
                            ],
                          ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (widget.embedded) {
      return Card(
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [header, const Divider(height: 1), body],
        ),
      );
    }
    final close = busy
        ? (cancel == null ? null : _cancelLogin)
        : () => Navigator.pop(context);
    return PopScope(
      canPop: !busy,
      child: Dialog(
        backgroundColor: theme.colorScheme.surfaceContainerLowest,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 570),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              header,
              const Divider(height: 1),
              Flexible(child: SingleChildScrollView(child: body)),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: busy
                              ? null
                              : () => Navigator.pop(context, true),
                          label: Text(l.planManageHub),
                          icon: const Icon(Icons.tune, size: 16),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: close,
                      child: Text(busy ? l.cancel : l.close),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
