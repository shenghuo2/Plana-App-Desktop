import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/external_image_push_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/settings_scaffold.dart';
import '../../core/util/haptics.dart';
import '../generate/widgets/common.dart' show confirmDialog, hintSnack;
import 'widgets/settings_ui.dart';

/// Configuration for pushing original gallery images to a pic-manager server.
class CloudStoragePage extends ConsumerStatefulWidget {
  const CloudStoragePage({super.key});

  @override
  ConsumerState<CloudStoragePage> createState() => _CloudStoragePageState();
}

class _CloudStoragePageState extends ConsumerState<CloudStoragePage> {
  final _endpoint = TextEditingController();
  final _token = TextEditingController();
  final _sourceName = TextEditingController();

  bool _seeded = false;
  bool _seeding = false;
  bool _obscure = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _endpoint.addListener(_onChanged);
    _token.addListener(_onChanged);
    _sourceName.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted && !_seeding) setState(() {});
  }

  @override
  void dispose() {
    _endpoint
      ..removeListener(_onChanged)
      ..dispose();
    _token
      ..removeListener(_onChanged)
      ..dispose();
    _sourceName
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final parsed = splitExternalImagePushTokenInput(_token.text);
      var sourceName = _sourceName.text;
      if (parsed.sourceName != null &&
          (sourceName.trim().isEmpty ||
              sourceName.trim() == kDefaultExternalImagePushSourceName)) {
        sourceName = parsed.sourceName!;
        _sourceName.text = sourceName;
      }
      await ref
          .read(externalImagePushSettingsProvider.notifier)
          .save(
            endpoint: _endpoint.text,
            sourceName: sourceName,
            token: parsed.token.isEmpty ? null : parsed.token,
          );
      if (!mounted) return;
      _token.clear(); // Never leave a raw token visible after persistence.
      FocusScope.of(context).unfocus();
      Haptics.selection();
      hintSnack(context, '云存储配置已保存', icon: Icons.check_circle_outline);
    } on ExternalImagePushConfigException catch (e) {
      if (mounted) hintSnack(context, e.message, icon: Icons.error_outline);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearToken() async {
    if (_saving) return;
    final ok = await confirmDialog(
      context,
      title: '清除云存储 Token',
      message: '将从本机删除已保存的 Token,图库上传会停止直到重新填写。',
      confirmLabel: '清除',
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      await ref.read(externalImagePushSettingsProvider.notifier).clearToken();
      if (!mounted) return;
      _token.clear();
      Haptics.medium();
      hintSnack(context, '已清除云存储 Token', icon: Icons.check_circle_outline);
    } on ExternalImagePushConfigException catch (e) {
      if (mounted) hintSnack(context, e.message, icon: Icons.error_outline);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setAutoUpload(bool value) async {
    if (_saving) return;
    if (value &&
        ref.read(externalImagePushSettingsProvider).value?.isConfigured !=
            true) {
      hintSnack(context, '请先保存 API 地址和 Token', icon: Icons.error_outline);
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(favoriteAutoUploadProvider.notifier).set(value);
    } on ExternalImagePushConfigException catch (e) {
      if (mounted) hintSnack(context, e.message, icon: Icons.error_outline);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(externalImagePushSettingsProvider);
    final settings = async.value;
    if (!_seeded && settings != null) {
      _seeding = true;
      _endpoint.text = settings.endpoint;
      _sourceName.text = settings.sourceName;
      _seeded = true;
      _seeding = false;
    }

    final hasToken = settings?.hasToken ?? false;
    final isConfigured = settings?.isConfigured ?? false;
    final autoUpload = ref.watch(favoriteAutoUploadProvider);
    final canSave =
        _endpoint.text.trim().isNotEmpty &&
        _sourceName.text.trim().isNotEmpty &&
        (hasToken || _token.text.trim().isNotEmpty) &&
        !async.isLoading &&
        !_saving;

    return SettingsScaffold(
      appBar: AppBar(title: const Text('远端上传')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: [
          const SettingsPageHeader(),
          const SettingsLabel('上传方式'),
          SettingsCard(
            children: [
              SwitchListTile(
                key: const ValueKey('favorite-auto-upload'),
                title: const Text('收藏自动上传'),
                subtitle: const Text('开启后，按钮栏显示收藏。新收藏的图片会自动上传原图，取消收藏不会删除远端图片。'),
                secondary: const Icon(Icons.star_outline),
                value: autoUpload,
                onChanged: _saving || async.isLoading ? null : _setAutoUpload,
              ),
            ],
          ),
          const SizedBox(height: 16),
          const SettingsLabel('连接'),
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 13, 16, 8),
                child: TextField(
                  key: const ValueKey('remote-api-endpoint'),
                  enabled: !async.isLoading && !_saving,
                  controller: _endpoint,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'API 地址',
                    hintText: 'http://host:3210 或 .../api/v1/assets',
                    prefixIcon: Icon(Icons.link),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 15),
                child: TextField(
                  key: const ValueKey('remote-source-name'),
                  enabled: !async.isLoading && !_saving,
                  controller: _sourceName,
                  textInputAction: TextInputAction.next,
                  maxLength: 64,
                  decoration: const InputDecoration(
                    labelText: '来源名称',
                    prefixIcon: Icon(Icons.sell_outlined),
                  ),
                ),
              ),
              SettingsRow(
                icon: isConfigured
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off_outlined,
                title: '连接状态',
                value: isConfigured ? '已配置' : '待填写',
                valueColor: isConfigured
                    ? context.scheme.primary
                    : context.scheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 16),
          const SettingsLabel('凭据'),
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 13, 16, 14),
                child: TextField(
                  key: const ValueKey('remote-token-input'),
                  enabled: !async.isLoading && !_saving,
                  controller: _token,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    if (canSave) unawaited(_save());
                  },
                  decoration: InputDecoration(
                    labelText: hasToken ? 'Token (已保存)' : 'Token',
                    prefixIcon: const Icon(Icons.key_outlined),
                    suffixIcon: IconButton(
                      tooltip: _obscure ? '显示 Token' : '隐藏 Token',
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off,
                      ),
                    ),
                  ),
                ),
              ),
              if (hasToken)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _saving ? null : _clearToken,
                      icon: const Icon(Icons.key_off_outlined),
                      label: const Text('清除 Token'),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const ValueKey('save-remote-config'),
            onPressed: canSave ? _save : null,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(_saving ? '保存中' : '保存配置'),
          ),
        ],
      ),
    );
  }
}
