import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/features/inspiration/external/oc_source_page.dart';
import 'package:plana_app/features/profile/backup_page.dart';

import 'support/pump_until.dart';

void main() {
  testWidgets(
    'backup import opens the private source manager and its URL or file dialog',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStoresProvider.overrideWithValue(AppStores.ephemeral()),
            desktopModeProvider.overrideWithValue(true),
          ],
          child: const MaterialApp(home: BackupPage()),
        ),
      );
      final open = find.byKey(const ValueKey('backup-external-oc'));
      await tester.scrollUntilVisible(
        open,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(open);
      await pumpUntil(
        tester,
        () =>
            find.byType(OcSourcePage).evaluate().isNotEmpty &&
            find
                .descendant(
                  of: find.byType(OcSourcePage),
                  matching: find.byType(LinearProgressIndicator),
                )
                .evaluate()
                .isEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.byType(OcSourcePage), findsOneWidget);
      await tester.tap(find.byIcon(Icons.add).first);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNWidgets(3));
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .where((f) => f.obscureText),
        hasLength(1),
      );
      expect(find.byIcon(Icons.folder_open), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
  testWidgets('Drive advanced settings expand without adding a border', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStoresProvider.overrideWithValue(AppStores.ephemeral())],
        child: const MaterialApp(home: BackupPage()),
      ),
    );
    final tile = find.byType(ExpansionTile);
    final importIcon = find.descendant(
      of: tile,
      matching: find.byIcon(Icons.file_open_outlined),
    );
    await tester.ensureVisible(tile);
    final settings = tester.widget<ExpansionTile>(tile);
    expect(settings.collapsedShape, const Border());
    expect(importIcon, findsNothing);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(settings.shape, const Border());
    expect(importIcon, findsOneWidget);

    await tester.tap(
      find.descendant(of: tile, matching: find.byType(ListTile)).first,
    );
    await tester.pumpAndSettle();
    expect(importIcon, findsNothing);
  });
}
