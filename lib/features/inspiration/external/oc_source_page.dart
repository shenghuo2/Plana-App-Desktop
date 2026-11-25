import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import 'oc_sources.dart';

class OcSourcePage extends ConsumerWidget {
  const OcSourcePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    Future<void> edit([OcSource? source]) => showDialog<void>(
      context: context,
      builder: (_) => _ConnectDialog(source: source),
    );
    final sources = ref.watch(ocSourcesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l.externalOcLibraries)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: () => edit(),
                  icon: const Icon(Icons.add),
                  label: Text(l.externalOcLibraries),
                ),
              ),
              const SizedBox(height: 12),
              ...sources.when(
                data: (items) => [
                  for (final source in items)
                    Card(
                      child: ListTile(
                        title: Text(source.label),
                        leading: Icon(
                          source.location.isScheme('file')
                              ? Icons.folder_outlined
                              : Icons.language,
                        ),
                        subtitle: Text(
                          source.location.isScheme('file')
                              ? source.location.toFilePath()
                              : source.location.host,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => edit(source),
                        trailing: Wrap(
                          children: [
                            IconButton(
                              tooltip: l.externalOcRefresh,
                              icon: const Icon(Icons.refresh),
                              onPressed: () => edit(source),
                            ),
                            IconButton(
                              tooltip: l.externalOcRemove,
                              icon: const Icon(Icons.link_off),
                              onPressed: () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text(l.externalOcRemove),
                                    content: Text(source.label),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: Text(l.cancel),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: Text(l.confirm),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed != true || !context.mounted) {
                                  return;
                                }
                                try {
                                  await ref
                                      .read(ocRepositoryProvider)
                                      .remove(source);
                                } catch (_) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('移除失败，请重试')),
                                    );
                                  }
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
                loading: () => [const LinearProgressIndicator()],
                error: (_, _) => [
                  TextButton(
                    onPressed: () => ref.invalidate(ocSourcesProvider),
                    child: Text(l.retry),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectDialog extends ConsumerStatefulWidget {
  const _ConnectDialog({this.source});
  final OcSource? source;
  @override
  ConsumerState<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends ConsumerState<_ConnectDialog> {
  late final _address = TextEditingController(
    text: widget.source?.location.toString(),
  );
  late final _name = TextEditingController(text: widget.source?.label);
  final _password = TextEditingController();
  late Uri? _file = widget.source?.location.isScheme('file') == true
      ? widget.source!.location
      : null;
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _address.dispose();
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final uri =
          widget.source?.location ?? _file ?? ocWebLocation(_address.text);
      await ref
          .read(ocRepositoryProvider)
          .connect(
            uri,
            label: _name.text,
            password: _password.text.isEmpty ? null : _password.text,
          );
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = switch (e) {
            OcAccessError() => e.message,
            FormatException() => '无法识别资料库格式，请检查 JSON 文件或链接。',
            FileSystemException() => '无法读取或保存本机文件。',
            _ => '连接失败，请检查网址、网络或访客口令再试。',
          };
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(
          widget.source == null ? l.externalOcLibraries : l.externalOcRefresh,
        ),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _address,
                  enabled: !_busy && widget.source == null,
                  onChanged: (_) {
                    if (_file != null) setState(() => _file = null);
                  },
                  decoration: InputDecoration(
                    labelText: _file == null
                        ? l.externalOcUrl
                        : l.externalOcFile,
                  ),
                ),
                if (widget.source == null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.folder_open),
                      label: Text(l.externalOcFile),
                      onPressed: _busy
                          ? null
                          : () async {
                              final picked = await FilePicker.platform
                                  .pickFiles(
                                    type: FileType.custom,
                                    allowedExtensions: ['json'],
                                  );
                              final path = picked?.files.singleOrNull?.path;
                              if (path != null && mounted) {
                                setState(() {
                                  _file = File(path).absolute.uri;
                                  _address.text = path;
                                });
                              }
                            },
                    ),
                  ),
                const SizedBox(height: 10),
                TextField(
                  controller: _name,
                  enabled: !_busy,
                  decoration: InputDecoration(labelText: l.externalOcName),
                ),
                if (_file == null) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l.externalOcPassword,
                    ),
                  ),
                ],
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('JSON'),
                  children: [
                    const SelectableText(
                      '{"characters":[{"name":"OC","owner":"Artist","forms":[{"name":"A","prompt":"silver hair","negativePrompt":"","images":["a.png","b.png"]}]}]}',
                    ),
                  ],
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_busy) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(l.externalOcConnect),
          ),
        ],
      ),
    );
  }
}
