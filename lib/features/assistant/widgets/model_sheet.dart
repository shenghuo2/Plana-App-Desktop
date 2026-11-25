/// 选 AI 助手用哪个模型:Plana Bot 的渠道,或者自己填的接口。图像模型和对话模型混在
/// 同一组里(图标不同),选了就不走对话模型,发的话直接交给它出图。
/// 没有 Bot 授权时 Plana Bot 那组只列免费模型,图像模型显示暂未开放。
///
/// 两组共用**同一种行**:左边一个图标、中间完整型号名、右边留给「编辑」。
/// 不写 `short_label`(「GLM」「豆包」这种简称看不出是哪一代),也不写线路说明
/// (commandcode / vertex / 火山方舟)—— 选哪条线不是用户的决定。
///
/// 「推荐」是后端标的([AgentModelChoice.recommended]),不在 app 里写死 ——
/// 哪个渠道当下稳、当下便宜只有后端知道,写死就得跟着发版。
///
/// **选中态是整行染色**,右边空出来给「编辑」。选中标记挤在右边的话,想选中却点到
/// 编辑是迟早的事 —— 而这个弹层九成时候是来选的,不是来改配置的。
///
/// 后端渠道(对话和图像)出问题时图标右下角挂一个小点([ModelHealth]):不稳琥珀、不可用红,
/// 正常和没数据都不挂;弹层打开时重取一次列表,开着时定时再取。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_skin.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/setting_row.dart';
import '../../generate/widgets/common.dart' show dropFocusSoon;
import '../agent_model.dart';
import '../subscription/plan_accounts.dart';
import 'plan_accounts_dialog.dart';
import '../custom_endpoint.dart';
import 'assistant_tag.dart';
import '../endpoints_page.dart';
import '../image_gen/image_models.dart'
    show
        ImageModelChoice,
        imageModelChoicesProvider,
        planaImageChannelsProvider;
import '../../../l10n/l10n.dart';

class AssistantModelDropdown extends ConsumerStatefulWidget {
  const AssistantModelDropdown({
    super.key,
    this.compact = false,
    this.onManage,
  });

  final bool compact;
  final ValueChanged<String>? onManage;

  @override
  ConsumerState<AssistantModelDropdown> createState() =>
      _AssistantModelDropdownState();
}

class _AssistantModelDropdownState
    extends ConsumerState<AssistantModelDropdown> {
  final menu = MenuController();

  @override
  Widget build(BuildContext context) {
    final models = ref.watch(agentModelsProvider);
    final current = ref.watch(assistantModelProvider);
    final plans = ref.watch(planAccountsProvider).value;
    final login = widget.onManage == null && plans?.profiles.isEmpty == true;
    final endpointState = ref.watch(customEndpointsProvider);
    final endpoints = (endpointState.value ?? const <CustomEndpoint>[]).where(
      (e) => e.enabled,
    );
    final images = ref.watch(imageModelChoicesProvider);
    final authorized = ref.watch(assistantBotAuthorizedProvider);
    final imageLive = !ref.watch(planaImageChannelsProvider).hasError;
    final hostedImages = images.where((m) => m.endpoint == null && m.available);
    void manage(String id) {
      menu.close();
      if (widget.onManage case final select?) {
        select(id);
      } else {
        openEndpointsPage(context, editId: id);
      }
    }

    void edit(CustomEndpoint endpoint) => manage(endpoint.id);

    Widget choice(
      String key,
      String name, {
      String? subtitle,
      bool recommended = false,
      bool image = false,
      ModelHealth health = ModelHealth.unknown,
    }) => MenuItemButton(
      key: ValueKey('assistant-model-$key'),
      autofocus: current?.key == key,
      leadingIcon: _LeadingIcon(
        icon: current?.key == key ? Icons.check : Icons.smart_toy_outlined,
        color: null,
        dot: _healthDot(health, context.scheme),
        ringColor: context.scheme.surface,
      ),
      onPressed: () => ref.read(assistantModelPrefProvider.notifier).set(key),
      child: SizedBox(
        width: 232,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: current?.key == key
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (image) ...[
                    const SizedBox(width: 6),
                    AssistantTag(context.l10n.imageModelField),
                  ],
                ],
              ),
              if (subtitle != null || recommended)
                Text(
                  subtitle ?? '推荐',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: context.scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    return MenuAnchor(
      key: const ValueKey('assistant-model-dropdown'),
      controller: menu,
      consumeOutsideTap: true,
      style: MenuStyle(
        maximumSize: const WidgetStatePropertyAll(Size(340, 480)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      menuChildren: [
        if (authorized ||
            (models.value?.free.isNotEmpty ?? false) ||
            hostedImages.isNotEmpty) ...[
          settingSection(context, context.l10n.planaBackend),
          ...switch (models) {
            AsyncData(:final value) when value.choices.isNotEmpty => [
              for (final c in authorized ? value.choices : value.free)
                choice(
                  c.key,
                  c.name,
                  recommended: c.recommended,
                  health: models.hasError ? ModelHealth.unknown : c.health,
                ),
            ],
            AsyncData() when hostedImages.isNotEmpty => <Widget>[],
            AsyncLoading() => [
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ],
            _ => [
              MenuItemButton(
                leadingIcon: const Icon(Icons.refresh, size: 18),
                onPressed: () => ref.invalidate(agentModelsProvider),
                child: Text(l10nNow.desktopCouldNotLoadModelsClickToRetry),
              ),
            ],
          },
          for (final image in hostedImages)
            choice(
              '$kImageKeyPrefix${image.key}',
              image.name,
              image: true,
              health: imageLive ? image.health : ModelHealth.unknown,
            ),
          const Divider(height: 12),
        ],
        settingSection(context, l10nNow.myEndpoints),
        if (endpointState.hasError)
          MenuItemButton(
            leadingIcon: const Icon(Icons.refresh, size: 18),
            onPressed: () => ref.invalidate(customEndpointsProvider),
            child: Text(l10nNow.desktopCouldNotReadEndpointsClickToReload),
          )
        else if (endpointState.isLoading && !endpointState.hasValue)
          Padding(
            padding: EdgeInsets.all(20),
            child: Text(l10nNow.desktopLoadingEndpoints),
          ),
        for (final e in endpoints) ...[
          if (e.usable)
            for (final model in e.allModels)
              choice(
                customModelKey(e.id, model),
                model,
                subtitle: e.displayName,
              ),
          if (!e.usable && !e.canDraw)
            MenuItemButton(
              onPressed: () => edit(e),
              leadingIcon: const Icon(Icons.edit_outlined, size: 17),
              child: Text('${e.displayName} · 待完善'),
            ),
          for (final image in images.where(
            (m) => m.endpoint?.id == e.id && m.available,
          ))
            choice(
              '$kImageKeyPrefix${image.key}',
              image.name,
              image: true,
              subtitle: e.displayName,
            ),
        ],
        if (plans?.active case final p?
            when plans!.enabled &&
                p.connected &&
                p.selectedModels.isNotEmpty) ...[
          settingSection(context, context.l10n.planSection),
          for (final m in p.selectedModels.entries)
            choice(planModelKey(p.id, m.key), m.value, subtitle: p.label),
        ],
        if (endpoints.any((e) => e.usable || e.canDraw))
          SubmenuButton(
            leadingIcon: const Icon(Icons.tune, size: 17),
            menuChildren: [
              for (final e in endpoints)
                MenuItemButton(
                  onPressed: () => edit(e),
                  child: Text(e.displayName),
                ),
            ],
            child: Text(l10nNow.desktopEditEndpoints),
          ),
        MenuItemButton(
          onPressed: () => manage(planHubId),
          autofocus: current == null,
          leadingIcon: const Icon(Icons.tune, size: 18),
          child: Text(context.l10n.planManageHub),
        ),
        MenuItemButton(
          key: const ValueKey('assistant-chatgpt-accounts'),
          leadingIcon: Image.asset(
            'assets/assistant/providers/openai.png',
            width: 18,
            height: 18,
            color: context.scheme.onSurface,
          ),
          onPressed: () {
            menu.close();
            openPlanAccounts(
              context,
              login: login,
              onManage: widget.onManage == null
                  ? null
                  : () => widget.onManage!(planHubId),
            );
          },
          child: Text(
            login ? context.l10n.planLogin : context.l10n.planQuickSwitch,
          ),
        ),
      ],
      builder: (context, controller, _) => TextButton(
        key: const ValueKey('assistant-model-button'),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        ),
        child: Row(
          mainAxisSize: widget.compact ? MainAxisSize.min : MainAxisSize.max,
          children: [
            Flexible(
              fit: widget.compact ? FlexFit.loose : FlexFit.tight,
              child: Text(
                current?.name ?? '选择模型',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            if (imageChoiceKeyOf(current?.key ?? '') != null) ...[
              const SizedBox(width: 6),
              AssistantTag(context.l10n.imageModelField),
            ],
            const SizedBox(width: 6),
            const Icon(Icons.expand_more, size: 16),
          ],
        ),
      ),
    );
  }
}

Future<void> showModelSheet(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // 抓手、圆角、关闭都由 SettingSheet 自己画(与编辑器/助手设置同一套)
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .18),
    builder: (_) => const _ModelSheet(),
  );
  // 只是来看一眼模型,别顺手把软键盘顶出来
  dropFocusSoon();
}

class _ModelSheet extends ConsumerStatefulWidget {
  const _ModelSheet();

  @override
  ConsumerState<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends ConsumerState<_ModelSheet> {
  /// 开着时隔多久重取一次列表。
  static const _refreshEvery = Duration(seconds: 30);

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    Future.microtask(_refresh);
    _timer = Timer.periodic(_refreshEvery, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    ref.invalidate(agentModelsProvider);
    ref.invalidate(planaImageChannelsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(agentModelsProvider);
    // 重取失败时列表照旧显示,近况不再可信,颜色撤掉
    final live = !async.hasError;
    final currentKey = ref.watch(assistantModelProvider)?.key ?? '';
    final plans = ref.watch(planAccountsProvider).value;
    final endpointState = ref.watch(customEndpointsProvider);
    final endpoints = (endpointState.value ?? const <CustomEndpoint>[]).where(
      (e) => e.enabled,
    );
    // 没有 Bot 授权时只列免费的;后端一条免费的都没有就整组不列
    final authorized = ref.watch(assistantBotAuthorizedProvider);
    List<AgentModelChoice> shown(AgentModelList l) =>
        authorized ? l.choices : l.free;
    final hidden = !authorized && async.hasValue && shown(async.value!).isEmpty;
    final images = ref.watch(imageModelChoicesProvider);
    final imageLive = !ref.watch(planaImageChannelsProvider).hasError;
    String imageKey(ImageModelChoice m) => '$kImageKeyPrefix${m.key}';
    Widget imageRow(ImageModelChoice m) => _row(
      context,
      icon: Icons.image_outlined,
      title: m.name,
      badge: context.l10n.imageModelField,
      // 没授权的后端渠道只说暂未开放,不引导去授权
      subtitle:
          m.endpoint?.displayName ??
          (m.available ? null : context.l10n.notAvailableYet),
      dim: !m.available,
      health: m.available && imageLive ? m.health : ModelHealth.unknown,
      selected: imageKey(m) == currentKey,
      onTap: m.available ? () => _pick(context, ref, imageKey(m)) : () {},
      onEdit: m.endpoint == null
          ? null
          : () => openEndpointsPage(context, editId: m.endpoint!.id),
    );

    return SettingSheet(
      title: context.l10n.selectModel,
      children: [
        if (!hidden) ...[
          settingSection(
            context,
            authorized ? context.l10n.planaBackend : context.l10n.freeModels,
          ),
          // 重取期间沿用上一份,不闪转圈
          switch (async) {
            AsyncValue(:final value?) when shown(value).isNotEmpty => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in shown(value))
                  _row(
                    context,
                    icon: Icons.bolt_outlined,
                    title: c.name,
                    badge: c.recommended ? '推荐' : null,
                    health: live ? c.health : ModelHealth.unknown,
                    selected: c.key == currentKey,
                    onTap: () => _pick(context, ref, c.key),
                  ),
              ],
            ),
            AsyncError(:final error) => _note(
              context,
              '拿不到渠道列表:$error',
              onRetry: () => ref.invalidate(agentModelsProvider),
            ),
            AsyncValue(hasValue: true) => _note(
              context,
              '后端没配可选渠道。',
              onRetry: () => ref.invalidate(agentModelsProvider),
            ),
            _ => const Padding(
              padding: EdgeInsets.symmetric(vertical: 26),
              child: Center(child: CircularProgressIndicator()),
            ),
          },
          for (final m in images)
            if (m.endpoint == null) imageRow(m),
        ],
        settingSection(context, context.l10n.myEndpoints),
        if (endpointState.hasError)
          _note(
            context,
            '读取接口失败',
            onRetry: () => ref.invalidate(customEndpointsProvider),
            retryLabel: '重新加载接口',
          )
        else if (endpointState.isLoading && !endpointState.hasValue)
          Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Text(l10nNow.desktopLoadingEndpoints),
          ),
        // 一个接口下的每个模型各一行(对话模型在前、出图模型在后),副行写是哪个接口
        for (final e in endpoints) ...[
          if (e.usable)
            for (final m in e.allModels)
              _row(
                context,
                icon: Icons.bolt_outlined,
                title: m,
                subtitle: e.displayName,
                selected: customModelKey(e.id, m) == currentKey,
                onTap: () => _pick(context, ref, customModelKey(e.id, m)),
                onEdit: () => openEndpointsPage(context, editId: e.id),
              ),
          for (final m in images)
            if (m.endpoint?.id == e.id) imageRow(m),
          // 只填了出图模型的接口不是没填完,只是不拿来对话
          if (!e.usable && !e.canDraw)
            _row(
              context,
              icon: Icons.bolt_outlined,
              title: e.displayName,
              subtitle: context.l10n.incompleteTapToFix,
              dim: true,
              onTap: () => openEndpointsPage(context, editId: e.id),
              onEdit: () => openEndpointsPage(context, editId: e.id),
            ),
        ],
        if (plans?.active case final p?
            when plans!.enabled &&
                p.connected &&
                p.selectedModels.isNotEmpty) ...[
          settingSection(context, context.l10n.planSection),
          for (final m in p.selectedModels.entries)
            _row(
              context,
              icon: Icons.chat_outlined,
              title: m.value,
              subtitle: p.label,
              selected: planModelKey(p.id, m.key) == currentKey,
              onTap: () => _pick(context, ref, planModelKey(p.id, m.key)),
            ),
        ],
        _row(
          context,
          icon: Icons.tune,
          title: context.l10n.planManageHub,
          onTap: () => openEndpointsPage(context, editId: planHubId),
        ),
        _row(
          context,
          icon: Icons.account_circle_outlined,
          title: plans?.profiles.isEmpty == true
              ? context.l10n.planLogin
              : context.l10n.planQuickSwitch,
          onTap: () =>
              openPlanAccounts(context, login: plans?.profiles.isEmpty == true),
        ),
      ],
    );
  }

  void _pick(BuildContext context, WidgetRef ref, String key) {
    ref.read(assistantModelPrefProvider.notifier).set(key);
    Navigator.pop(context);
  }

  /// 一行。选中时整行染色、标题加粗,图标不换。
  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    String? subtitle,
    String? badge,
    ModelHealth health = ModelHealth.unknown,
    bool selected = false,
    bool dim = false,
    VoidCallback? onEdit,
  }) {
    final scheme = context.scheme;
    final solid = selected && context.skin.float;
    final fg = solid
        ? scheme.onPrimary
        : selected
        ? scheme.primary
        : (dim ? scheme.outline : null);
    final titleStyle = context.texts.bodyLarge!.copyWith(
      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      color: fg,
    );
    final dot = _healthDot(health, scheme);
    final sheetBg = context.raisedFill(scheme.surfaceContainer);
    final selectedBg = context.skin.float
        ? scheme.primary
        : scheme.primaryContainer.withValues(alpha: .35);
    final ringColor = selected
        ? (context.skin.float
              ? scheme.primary
              : Color.alphaBlend(selectedBg, sheetBg))
        : sheetBg;
    return ListTile(
      onTap: onTap,
      selected: selected,
      selectedTileColor: selectedBg,
      contentPadding: const EdgeInsets.only(left: 20, right: 8),
      leading: _LeadingIcon(
        icon: icon,
        color: selected ? fg : (dim ? scheme.outline : fg),
        dot: dot,
        ringColor: ringColor,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          ),
          if (badge != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: solid
                    ? scheme.onPrimary.withValues(alpha: .2)
                    : scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                badge,
                style: context.texts.labelSmall!.copyWith(
                  color: solid ? scheme.onPrimary : scheme.onSecondaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.labelSmall!.copyWith(
                color: solid
                    ? scheme.onPrimary.withValues(alpha: .8)
                    : scheme.outline,
              ),
            ),
      trailing: onEdit == null
          ? null
          : IconButton(
              tooltip: context.l10n.edit,
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.edit_outlined,
                size: 18,
                color: solid ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
              onPressed: onEdit,
            ),
    );
  }

  Widget _note(
    BuildContext context,
    String text, {
    required VoidCallback onRetry,
    String? retryLabel,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: context.texts.bodySmall!.copyWith(
              color: context.scheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
        ),
        TextButton(
          onPressed: onRetry,
          child: Text(retryLabel ?? context.l10n.retry),
        ),
      ],
    ),
  );
}

/// 行首图标(对话闪电 / 图像图标);渠道异常时在右下角挂一枚带行底色描边的小圆点。
Color? _healthDot(ModelHealth health, ColorScheme scheme) => switch (health) {
  ModelHealth.degraded => const Color(0xFFF59E0B),
  ModelHealth.down => scheme.error,
  _ => null,
};

class _LeadingIcon extends StatelessWidget {
  const _LeadingIcon({
    required this.icon,
    required this.color,
    required this.dot,
    required this.ringColor,
  });

  final IconData icon;
  final Color? color;
  final Color? dot;
  final Color ringColor;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(icon, size: 21, color: color);
    if (dot == null) return glyph;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        glyph,
        Positioned(
          right: -2,
          bottom: -2,
          child: Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: dot,
              shape: BoxShape.circle,
              border: Border.all(color: ringColor, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
