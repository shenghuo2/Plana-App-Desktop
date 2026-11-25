import '../../l10n/l10n.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/nai_proxy.dart';
import '../../core/net/nai_endpoint.dart';
import '../../core/net/network_proxy.dart';
import '../../core/net/proxy_import.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/image_drop.dart';
import '../../core/ui/settings_scaffold.dart';
import '../../core/util/image_pick.dart';

class NetworkSettingsPage extends ConsumerStatefulWidget {
  const NetworkSettingsPage({super.key});

  @override
  ConsumerState<NetworkSettingsPage> createState() =>
      _NetworkSettingsPageState();
}

class _NetworkSettingsPageState extends ConsumerState<NetworkSettingsPage> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _address;
  late bool _bypassLocal;
  late ProxySoftware _software;
  bool _expanded = false;
  bool _toggling = false;
  String? _toggleError;
  bool _importing = false;
  int _importGeneration = 0;
  String? _importMessage;
  bool _saving = false;
  bool _testing = false;
  String? _saveMessage;
  String? _testMessage;
  int _probeGeneration = 0;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(networkProxyProvider);
    _address = TextEditingController(text: saved.address);
    _bypassLocal = saved.bypassLocal;
    _software = saved.software;
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  NetworkProxySettings get _draft => NetworkProxySettings(
    enabled: ref.read(networkProxyProvider).enabled,
    address: _address.text,
    bypassLocal: _bypassLocal,
    software: _software,
  );

  void _changed() {
    _importGeneration++;
    _importMessage = null;
    _probeGeneration++;
    _testMessage = null;
    _saveMessage = null;
  }

  Future<void> _setEnabled(bool enabled) async {
    if (_toggling || _saving) return;
    setState(() {
      _toggling = true;
      _toggleError = null;
    });
    try {
      await ref.read(networkProxyProvider.notifier).setEnabled(enabled);
    } catch (_) {
      if (mounted) {
        setState(() {
          _toggleError = '开关已在本次运行生效，但保存失败，重启可能丢失。请检查磁盘后重试。';
        });
      }
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final next = _draft;
    setState(() {
      _saving = true;
      _saveMessage = null;
    });
    try {
      await ref
          .read(networkProxyProvider.notifier)
          .saveConfiguration(
            address: next.address,
            bypassLocal: next.bypassLocal,
            software: next.software,
          );
      ref.invalidate(detectedProxySoftwareProvider(next.address));
      if (!mounted) return;
      setState(() {
        _address.text = ref.read(networkProxyProvider).address;
        _toggleError = null;
        _saveMessage = '已保存并应用。新请求使用当前设置，进行中的任务和连接不会被重启。';
      });
      _form.currentState!.validate();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saveMessage = '已在本次运行生效，但保存失败，重启可能丢失。请检查磁盘后重新保存。';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<List<ProxyAddressCandidate>> _recognize(Uint8List bytes) async =>
      parseProxyAddresses(await ref.read(proxyImageRecognizerProvider)(bytes));

  Future<void> _import(
    Future<List<ProxyAddressCandidate>?> Function() read,
  ) async {
    if (_importing || _saving) return;
    final generation = ++_importGeneration;
    setState(() {
      _expanded = true;
      _importing = true;
      _importMessage = null;
    });
    try {
      final candidates = await read();
      if (!mounted || generation != _importGeneration || candidates == null) {
        return;
      }
      if (candidates.isEmpty) {
        throw const FormatException(
          '未找到 HTTP / Mixed 代理地址。请截取端口设置区域，或复制完整地址后粘贴。',
        );
      }
      final selected = candidates.length == 1
          ? candidates.single
          : await showDialog<ProxyAddressCandidate>(
              context: context,
              builder: (context) => SimpleDialog(
                title: Text(l10nNow.desktopChooseADetectedProxyAddress),
                children: [
                  for (final candidate in candidates)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, candidate),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(candidate.address),
                            Text(
                              candidate.source,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l10nNow.cancel),
                  ),
                ],
              ),
            );
      if (!mounted || generation != _importGeneration || selected == null) {
        return;
      }
      setState(() {
        _address.text = selected.address;
        _software = ProxySoftware.auto;
        _changed();
        _importMessage = '已填入 ${selected.address}，确认后点「保存并应用」。';
      });
      _form.currentState?.validate();
    } on FormatException catch (e) {
      if (mounted && generation == _importGeneration) {
        setState(() => _importMessage = e.message);
      }
    } catch (_) {
      if (mounted && generation == _importGeneration) {
        setState(() => _importMessage = '读取失败，请重新复制截图或代理地址后重试');
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _paste() => _import(() async {
    final content = await ref.read(proxyClipboardReaderProvider)();
    if (content.hasImage) return _recognize(await proxyClipboardImage(content));
    if (content.hasText) return parseProxyAddresses(content.text!);
    throw const FormatException('剪贴板中没有截图或文字地址，请先复制代理设置截图或地址');
  });

  Future<void> _pickScreenshot() => _import(() async {
    final picked = await pickImageFile(context);
    return picked == null ? null : _recognize(picked.bytes);
  });

  Future<void> _test() async {
    if (!_form.currentState!.validate()) return;
    final generation = ++_probeGeneration;
    final draft = _draft;
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    String result;
    try {
      result = await ref.read(networkProxyProbeProvider)(draft);
    } catch (_) {
      result = '测试未完成，请检查代理地址后重试。';
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      if (generation == _probeGeneration) _testMessage = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Desktop settings retain nested pages. Follow changes from another entry
    // only while this form is untouched; never replace an unsaved draft.
    ref.listen(networkProxyProvider, (previous, next) {
      if (!_saving &&
          previous != null &&
          (previous.address != next.address ||
              previous.bypassLocal != next.bypassLocal ||
              previous.software != next.software) &&
          _address.text == previous.address &&
          _bypassLocal == previous.bypassLocal &&
          _software == previous.software) {
        setState(() {
          _address.text = next.address;
          _bypassLocal = next.bypassLocal;
          _software = next.software;
          _changed();
        });
      }
    });
    final saved = ref.watch(networkProxyProvider);
    final relay = ref.watch(naiProxyProvider);
    final detected = saved.enabled && saved.software == ProxySoftware.auto
        ? ref.watch(detectedProxySoftwareProvider(saved.address)).value ??
              ProxySoftware.auto
        : saved.software;
    final environmentProxy =
        !saved.enabled &&
        HttpClient.findProxyFromEnvironment(
              Uri.parse(relay ? kNaiProxyBase : kNaiOfficialBase),
            ) !=
            'DIRECT';
    final dirty =
        saved.address != _address.text ||
        saved.bypassLocal != _bypassLocal ||
        saved.software != _software;
    final small = context.texts.bodySmall!.copyWith(
      color: context.scheme.onSurfaceVariant,
    );
    return SettingsScaffold(
      appBar: AppBar(title: Text(l10nNow.desktopNetworkAndProxy)),
      body: ImageDropRegion(
        label: l10nNow.desktopReadProxySettingsFromAScreenshot,
        acceptInternal: false,
        acceptPaste: true,
        // Keep claiming repeated pastes during OCR, so they cannot fall through
        // to the workspace's generic artwork importer.
        onDrop: (images, _) async {
          unawaited(_import(() => _recognize(images.single.bytes)));
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
          children: [
            const SettingsPageHeader(),
            _NetworkCard(
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      button: true,
                      expanded: _expanded,
                      child: InkWell(
                        key: const ValueKey('network-proxy-expand'),
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => setState(() => _expanded = !_expanded),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  l10nNow.desktopLocalProxy,
                                  style: context.texts.titleMedium,
                                ),
                              ),
                              Tooltip(
                                message: _expanded
                                    ? context.l10n.proxyCollapseDetails
                                    : context.l10n.proxyExpandDetails,
                                preferBelow: false,
                                excludeFromSemantics: true,
                                child: SizedBox.square(
                                  dimension: 40,
                                  child: Icon(
                                    _expanded
                                        ? Icons.expand_less
                                        : Icons.expand_more,
                                    color: context.scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10nNow.desktopConnectThroughClashOrAnotherProxyAppStart,
                      style: small,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10nNow.desktopUseLocalHTTPProxy),
                      subtitle: Text(
                        l10nNow
                            .desktopTakesEffectImmediatelyUsingTheSavedAddress,
                      ),
                      value: saved.enabled,
                      onChanged: _saving || _toggling ? null : _setEnabled,
                    ),
                    if (_toggleError != null) ...[
                      Text(_toggleError!, style: small),
                      TextButton(
                        onPressed: _saving || _toggling
                            ? null
                            : () => _setEnabled(
                                ref.read(networkProxyProvider).enabled,
                              ),
                        child: Text(l10nNow.desktopRetrySavingProxyToggle),
                      ),
                    ],
                    TextFormField(
                      key: const ValueKey('network-proxy-address'),
                      controller: _address,
                      enabled: !_saving,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: l10nNow.desktopHTTPOrMixedProxyAddress,
                        hintText: kDefaultNetworkProxyAddress,
                        border: OutlineInputBorder(),
                        errorMaxLines: 3,
                      ),
                      validator: (value) {
                        try {
                          NetworkProxySettings.normalizeAddress(value ?? '');
                          return null;
                        } on FormatException catch (e) {
                          return e.message;
                        }
                      },
                      onChanged: (_) => setState(() {
                        _expanded = true;
                        _changed();
                      }),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10nNow.desktop7890IsAnExampleUseYourProxyApp,
                      style: small,
                    ),
                    if (!_expanded && dirty)
                      TextButton(
                        onPressed: () => setState(() => _expanded = true),
                        child: Text(l10nNow.desktopUnsavedChangesExpandToSave),
                      ),
                    if (_expanded) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _saving || _importing ? null : _paste,
                            icon: const Icon(Icons.content_paste, size: 18),
                            label: Text(_importing ? '识别中…' : '粘贴识别'),
                          ),
                          TextButton.icon(
                            onPressed: _saving || _importing
                                ? null
                                : _pickScreenshot,
                            icon: const Icon(Icons.image_search, size: 18),
                            label: Text(l10nNow.desktopSelectScreenshot),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10nNow.desktopCopyAScreenshotOrAddressThenChoosePaste,
                        style: small,
                      ),
                      if (_importMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(_importMessage!),
                        ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<ProxySoftware>(
                        key: ValueKey('proxy-software-${_software.name}'),
                        initialValue: _software,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: l10nNow.desktopAppNameForTheConnectionPath,
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: ProxySoftware.auto,
                            child: Text(l10nNow.autoDetect),
                          ),
                          DropdownMenuItem(
                            value: ProxySoftware.clash,
                            child: Text('Clash'),
                          ),
                          DropdownMenuItem(
                            value: ProxySoftware.other,
                            child: Text(l10nNow.desktopProxyApplication),
                          ),
                        ],
                        onChanged: _saving
                            ? null
                            : (value) => setState(() {
                                _software = value!;
                                _changed();
                              }),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(
                          l10nNow.desktopConnectDirectlyToLocalNetworkAddresses,
                        ),
                        subtitle: Text(
                          l10nNow
                              .desktopBypassLocalhostLocalNamesAndPrivateIPAddresses,
                        ),
                        value: _bypassLocal,
                        onChanged: _saving
                            ? null
                            : (v) => setState(() {
                                _bypassLocal = v!;
                                _changed();
                              }),
                      ),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          FilledButton.icon(
                            onPressed: _saving || _importing || _toggling
                                ? null
                                : _save,
                            icon: const Icon(Icons.check, size: 18),
                            label: Text(_saving ? '保存中…' : '保存并应用'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _saving || _testing || _importing
                                ? null
                                : _test,
                            icon: const Icon(Icons.network_check, size: 18),
                            label: Text(_testing ? '测试中…' : '测试代理'),
                          ),
                          if (dirty)
                            Text(l10nNow.desktopUnappliedChanges, style: small),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        l10nNow.desktopSaveAndApplyUpdatesTheAddressAppName,
                        style: small,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10nNow
                            .desktopTestTheEnteredProxyWithNovelAITestingDoes,
                        style: small,
                      ),
                      if (_saveMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(_saveMessage!),
                        ),
                      if (_testMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(_testMessage!),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            const NaiRelayCard(),
            const SizedBox(height: 12),
            _NetworkCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10nNow.desktopActiveConnectionPath,
                    style: context.texts.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    appliedProxyRoute(
                      saved,
                      relay: relay,
                      detected: detected,
                      environmentProxy: environmentProxy,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    saved.enabled
                        ? '已启用本机代理：${saved.address}'
                        : relay
                        ? '当前通过 Cloudflare 云端转发访问 NovelAI 官方接口。'
                        : environmentProxy
                        ? '当前正使用运行环境提供的系统代理。'
                        : '当前为直连模式（未启用应用内本机代理与云端转发）。',
                    style: small,
                  ),
                  if (saved.enabled)
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          saved.software != ProxySoftware.auto
                              ? '显示名称：已手动指定'
                              : detected == ProxySoftware.auto
                              ? '未识别出具体代理软件，暂显示为「代理软件」'
                              : '已自动识别为 ${proxySoftwareLabel(detected)}',
                          style: small,
                        ),
                        if (saved.software == ProxySoftware.auto)
                          TextButton(
                            onPressed: () => ref.invalidate(
                              detectedProxySoftwareProvider(saved.address),
                            ),
                            child: Text(l10nNow.desktopDetectAgain),
                          ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  Text(
                    l10nNow.desktopTheLocalProxyAppliesToPlanaNetworkRequests,
                    style: small,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10nNow.desktopThePathAboveIsForOfficialNovelAIRequests,
                    style: small,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NaiRelayCard extends ConsumerWidget {
  const NaiRelayCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => _NetworkCard(
    child: SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(kNaiProxyTitle, style: context.texts.titleSmall),
      subtitle: const Text(kNaiProxyHint),
      value: ref.watch(naiProxyProvider),
      onChanged: (value) => ref.read(naiProxyProvider.notifier).set(value),
    ),
  );
}

class _NetworkCard extends StatelessWidget {
  const _NetworkCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: context.scheme.surfaceContainerLow,
    borderRadius: BorderRadius.circular(16),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
}
