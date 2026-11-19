import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/profile/backup_page.dart';

void main() {
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
