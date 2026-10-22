import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/assistant/agent_trace.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/generate/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('plana_write_failure_');
    addTearDown(() => root.deleteSync(recursive: true));
  });

  test(
    'workspace write failure blocks exit and latest draft can be retried',
    () async {
      final stores = await AppStores.open(rootOverride: root);
      final blocker = File('${root.path}/workspace')
        ..writeAsStringSync('block');
      stores.workspace.schedule(
        GenerateState.initial().copyWith(prompt: 'unsaved draft'),
        idSeq: 101,
      );

      await expectLater(
        stores.flushForExit(),
        throwsA(isA<FileSystemException>()),
      );
      expect(stores.saveError.value, contains('工作台保存失败'));
      blocker.deleteSync();
      await stores.flushForExit();

      final reopened = await AppStores.open(rootOverride: root);
      expect(reopened.workspace.initial?.prompt, 'unsaved draft');
    },
  );

  test(
    'assistant messages and traces survive failed writes for retry',
    () async {
      final stores = await AppStores.open(rootOverride: root);
      final blocker = File('${root.path}/assistant')
        ..writeAsStringSync('block');
      final trace = AgentTrace(
        startedAt: 1,
        route: AgentTrace.routeBackend,
        userText: 'hello',
      );
      await expectLater(
        stores.assistant.saveTraces([trace]),
        throwsA(isA<FileSystemException>()),
      );
      stores.assistant.schedule([
        const AssistantMsg(id: 'm1', role: MsgRole.user, text: 'hello', at: 1),
      ], const []);
      await expectLater(
        stores.flushForExit(),
        throwsA(isA<FileSystemException>()),
      );
      expect(stores.saveError.value, contains('助手会话保存失败'));

      blocker.deleteSync();
      await stores.flushForExit();
      final reopened = await AppStores.open(rootOverride: root);
      expect(reopened.assistant.initialCurrent.single.text, 'hello');
      expect(reopened.assistant.initialTraces.single.userText, 'hello');
    },
  );
}
