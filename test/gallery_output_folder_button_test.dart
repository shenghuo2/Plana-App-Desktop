import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop_directory.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/desktop_output_store.dart';
import 'package:plana_app/features/desktop/desktop_gallery_browser.dart';
import 'package:plana_app/features/gallery/gallery_output_folder.dart';
import 'package:plana_app/features/gallery/widgets/gallery_output_folder_button.dart';
import 'package:plana_app/features/gallery/widgets/gallery_toolbar_button.dart';

class _Launcher extends DesktopDirectoryLauncher {
  final requests = <Completer<void>>[];
  final roots = <String>[];
  var opened = 0;
  @override
  Future<void> open(
    Directory directory, {
    required bool Function() isCurrent,
  }) async {
    final request = Completer<void>();
    requests.add(request);
    roots.add(directory.path);
    await request.future;
    if (isCurrent()) opened++;
  }
}

class _MigratingOutput extends DesktopOutputStore {
  _MigratingOutput(super.root);
  final pending = Completer<DesktopOutputMigrationReport>();
  var calls = 0;
  @override
  Future<DesktopOutputMigrationReport> migrateLegacy() {
    calls++;
    return pending.future;
  }
}

class _OutputStores implements AppStores {
  _OutputStores(this.desktopOutput);
  @override
  final DesktopOutputStore desktopOutput;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer container;
  late _Launcher launcher;
  late StateSetter updatePage;
  var page = 0;
  final folder = find.byKey(const ValueKey('desktop-gallery-folder'));

  setUp(() {
    stores = AppStores.ephemeral();
    launcher = _Launcher();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopDirectoryLauncherProvider.overrideWithValue(launcher),
      ],
    );
    page = 0;
  });
  tearDown(() {
    for (final pending in launcher.requests) {
      if (!pending.isCompleted) pending.complete();
    }
    container.dispose();
    stores.desktopOutput.root.parent.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                updatePage = setState;
                return IndexedStack(
                  index: page,
                  children: [
                    TickerMode(
                      enabled: page == 0,
                      child: const DesktopGalleryBrowser(),
                    ),
                    const Text('其他页面'),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'opening remains single flight across hidden overview and album',
    (tester) async {
      await mount(tester);
      await tester.tap(folder);
      await tester.pump();
      expect(launcher.requests, hasLength(1));
      updatePage(() => page = 1);
      await tester.pump();
      updatePage(() => page = 0);
      await tester.pump();
      container.read(desktopGalleryLocationProvider.notifier).open(null);
      await tester.pumpAndSettle();
      expect(
        tester.widget<GalleryToolbarButton>(folder).onPressed,
        isNull,
        reason: 'The album must share the overview opening operation.',
      );
      // Also guard a rapid second call before the disabled control rebuilds.
      await container.read(galleryOutputFolderProvider.notifier).open();
      expect(launcher.requests, hasLength(1));
      launcher.requests.single.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<GalleryToolbarButton>(folder).onPressed, isNotNull);
      expect(find.text('作品文件夹'), findsOneWidget);
      await tester.tap(folder);
      expect(launcher.requests, hasLength(2));
      launcher.requests.last.complete();
      await tester.pumpAndSettle();
      expect(launcher.opened, 2);
      expect(launcher.roots.toSet(), {stores.desktopOutput.root.path});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'hidden page failure clears busy state without a stray snackbar',
    (tester) async {
      await mount(tester);
      await tester.tap(folder);
      updatePage(() => page = 1);
      await tester.pump();
      launcher.requests.single.completeError(
        const FileSystemException('offline'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      updatePage(() => page = 0);
      await tester.pumpAndSettle();
      expect(tester.widget<GalleryToolbarButton>(folder).onPressed, isNotNull);
      await tester.tap(folder);
      launcher.requests.last.complete();
      await tester.pumpAndSettle();
      expect(launcher.opened, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'timeout permits retry and late completion cannot reset new work',
    (tester) async {
      await mount(tester);
      await tester.tap(folder);
      await tester.pump(const Duration(seconds: 11));
      expect(find.text('打开作品文件夹超时，请稍后重试'), findsOneWidget);
      expect(tester.widget<GalleryToolbarButton>(folder).onPressed, isNotNull);
      await tester.tap(folder);
      await tester.pump();
      launcher.requests.first.complete();
      await tester.pump();
      expect(
        launcher.opened,
        0,
        reason: 'Expired preparation cannot open a window.',
      );
      expect(tester.widget<GalleryToolbarButton>(folder).onPressed, isNull);
      launcher.requests.last.complete();
      await tester.pumpAndSettle();
      expect(launcher.opened, 1);
      expect(tester.widget<GalleryToolbarButton>(folder).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('unmounting all buttons does not strand the shared operation', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(folder);
    await tester.pumpWidget(const SizedBox.shrink());
    launcher.requests.single.completeError(
      const ProcessException('explorer', []),
    );
    await tester.pump();
    expect(container.read(galleryOutputFolderProvider), isFalse);
    await mount(tester);
    expect(tester.widget<GalleryToolbarButton>(folder).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('opening does not wait for or restart background migration', (
    tester,
  ) async {
    final output = _MigratingOutput(stores.desktopOutput.root);
    unawaited(output.migrateLegacy());
    final isolated = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(_OutputStores(output)),
        desktopDirectoryLauncherProvider.overrideWithValue(launcher),
      ],
    );
    addTearDown(() {
      output.pending.complete(const DesktopOutputMigrationReport());
      isolated.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: isolated,
        child: const MaterialApp(
          home: Scaffold(body: Center(child: GalleryOutputFolderButton())),
        ),
      ),
    );
    await tester.tap(folder);
    expect(launcher.requests, hasLength(1));
    launcher.requests.single.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<GalleryToolbarButton>(folder).onPressed, isNotNull);
    expect(output.pending.isCompleted, isFalse);
    expect(output.calls, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
