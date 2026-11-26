import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_info.dart';
import '../../../core/auth/auth_mode.dart';
import '../../../core/auth/bot_session_store.dart';
import '../../../core/auth/token_store.dart';
import '../../../core/net/network_proxy.dart';
import '../../../core/platform/desktop_directory.dart';
import '../../../core/platform/windows_diagnostics.dart';
import '../../../core/ui/setting_row.dart';
import '../../../l10n/l10n.dart';
import '../../assistant/custom_endpoint.dart';
import '../../generate/widgets/common.dart' show hintSnack;
import 'settings_ui.dart';

class DiagnosticSettings extends ConsumerWidget {
  const DiagnosticSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(windowsDiagnosticsProvider);
    final strings = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsLabel(strings.diagnosticLogs),
        SettingsCard(
          children: [
            ListenableBuilder(
              listenable: service,
              builder: (context, _) => SettingRow(
                icon: Icons.article_outlined,
                title: strings.writeDiagnosticLogs,
                desc: strings.writeDiagnosticLogsHint,
                value: service.enabled,
                enabled: !service.busy,
                onChanged: (value) async {
                  try {
                    await service.setEnabled(value);
                  } catch (_) {
                    if (context.mounted) {
                      hintSnack(context, strings.diagnosticWriteFailed);
                    }
                  }
                },
              ),
            ),
            SettingNavRow(
              icon: Icons.folder_open_outlined,
              title: strings.diagnosticDirectory,
              desc: strings.diagnosticDirectoryHint,
              value: strings.diagnosticOpen,
              onTap: () async {
                try {
                  final launcher = ref.read(desktopDirectoryLauncherProvider);
                  final directory = await service.logDirectory();
                  if (!context.mounted) return;
                  await launcher.open(
                    directory,
                    isCurrent: () => context.mounted,
                  );
                } catch (_) {
                  if (context.mounted) {
                    hintSnack(context, strings.diagnosticOpenFailed);
                  }
                }
              },
            ),
            SettingNavRow(
              icon: Icons.content_copy,
              title: strings.copyDiagnostics,
              desc: strings.copyDiagnosticsHint,
              value: strings.copy,
              onTap: () async {
                try {
                  final report = await _report(ref, service, strings);
                  if (!context.mounted) return;
                  await Clipboard.setData(ClipboardData(text: report));
                  if (context.mounted) {
                    hintSnack(context, strings.copied, icon: Icons.copy);
                  }
                } catch (_) {
                  if (context.mounted) {
                    hintSnack(context, strings.diagnosticCopyFailed);
                  }
                }
              },
            ),
          ],
        ),
      ],
    );
  }

  // Read configuration locally. Names, URLs, account identifiers and secrets
  // have no place in the clipboard report; project each result before formatting.
  Future<String> _report(
    WidgetRef ref,
    WindowsDiagnostics service,
    AppLocalizations strings,
  ) async {
    final values = <String, Future<String>>{
      strings.diagnosticDisplayAdapters: service.displayAdapters().then(
        (adapters) => adapters.isEmpty ? strings.unknown : adapters.join(', '),
      ),
      strings.diagnosticAccountMode: ref
          .read(authModeProvider.future)
          .then(
            (mode) => switch (mode) {
              AuthMode.bot => 'Bot',
              AuthMode.token => 'NovelAI Token',
              null => strings.notSet,
            },
          ),
      strings.diagnosticNaiAccount: ref
          .read(primaryNaiKeyProvider.future)
          .then(
            (key) =>
                key == null ? strings.notSet : strings.diagnosticConfigured,
          ),
      strings.diagnosticBotSession: ref
          .read(botSessionProvider.future)
          .then(
            (bot) => switch (bot) {
              null => strings.notSet,
              BotSession(expired: true) => strings.diagnosticExpired,
              _ => strings.diagnosticConfigured,
            },
          ),
      strings.diagnosticEnabledEndpoints: ref
          .read(customEndpointsProvider.future)
          .then(
            (endpoints) => endpoints
                .where((endpoint) => endpoint.enabled)
                .length
                .toString(),
          ),
    };
    final proxy = ref.read(networkProxyProvider).enabled;
    final lines = await Future.wait(
      values.entries.map((entry) async {
        try {
          final value = await entry.value.timeout(const Duration(seconds: 3));
          return '${entry.key} = $value';
        } catch (_) {
          return '${entry.key} = ${strings.unknown}';
        }
      }),
    );
    return [
      '$kAppName $kAppVersion (build $kAppBuild)',
      '${strings.diagnosticTimestamp} = ${DateTime.now().toUtc().toIso8601String()}',
      '${strings.diagnosticOperatingSystem} = ${Platform.operatingSystemVersion} (${Abi.current()})',
      ...lines,
      '${strings.diagnosticHttpProxy} = ${proxy ? strings.on : strings.off}',
      '${strings.writeDiagnosticLogs} = ${service.enabled ? strings.on : strings.off}',
    ].join('\n');
  }
}
