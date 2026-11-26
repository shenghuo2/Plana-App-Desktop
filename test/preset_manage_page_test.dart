import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/ui/image_drop.dart';
import 'package:plana_app/features/generate/preset_file.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/preset_manage_page.dart';
import 'package:plana_app/features/generate/prompt_presets.dart';
import 'support/pump_until.dart';

class _Picker extends FilePicker {
  String? text;
  List<PlatformFile>? files;
  int calls = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    expect(type, FileType.custom);
    expect(allowedExtensions, ['json']);
    expect(withData, isFalse);
    expect(allowMultiple, isTrue);
    if (files != null) return FilePickerResult(files!);
    final bytes = text == null ? null : Uint8List.fromList(utf8.encode(text!));
    return bytes == null
        ? null
        : FilePickerResult([
            PlatformFile(
              name: 'presets.json',
              size: bytes.length,
              bytes: bytes,
            ),
          ]);
  }
}

class _MemoryPresets extends PromptPresetsNotifier {
  int activations = 0;
  int reorders = 0;
  final imported = <List<PromptPreset>>[];
  PromptPresetsState get current => state.requireValue;
  String get activeId =>
      selectedPromptPresetId(ref.read(generateProvider), state.requireValue);

  @override
  Future<PromptPresetsState> build() async => const PromptPresetsState(
    presets: [
      PromptPreset(id: 'a', name: 'Alpha', positive: 'a', negative: ''),
      PromptPreset(id: 'b', name: 'Beta', positive: 'b', negative: ''),
      PromptPreset(id: 'c', name: 'Gamma', positive: 'c', negative: ''),
    ],
  );

  @override
  Future<void> setActive(String id) async {
    activations++;
    ref.read(generateProvider.notifier).setPromptPreset(id);
  }

  @override
  Future<void> reorder(int from, int to) async {
    reorders++;
    final old = state.requireValue;
    final next = [...old.presets];
    next.insert(to, next.removeAt(from));
    state = AsyncData(PromptPresetsState(presets: next));
  }

  @override
  Future<int> importPresets(
    List<PromptPreset> incoming, {
    String? activeId,
    bool requirePersistence = false,
  }) async {
    expect(requirePersistence, isTrue);
    imported.add(incoming);
    return incoming.length;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late _Picker picker;
  late FilePicker originalPicker;
  late _MemoryPresets presets;

  setUpAll(() => FilePicker.platform = _Picker());
  setUp(() {
    originalPicker = FilePicker.platform;
    picker = _Picker();
    FilePicker.platform = picker;
    presets = _MemoryPresets();
  });
  tearDown(() => FilePicker.platform = originalPicker);

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStoresProvider.overrideWithValue(AppStores.ephemeral()),
          desktopModeProvider.overrideWithValue(true),
          promptPresetsProvider.overrideWith(() => presets),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: const DesktopImageDropHost(child: PromptPresetManagePage()),
        ),
      ),
    );
    final scope = ProviderScope.containerOf(
      tester.element(find.byType(PromptPresetManagePage)),
    );
    scope.read(generateProvider.notifier).setPromptPreset('c');
    // The initial canvas save is debounced by 800 ms.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'file import supports cancel, rejects invalid files, and retains fields',
    (tester) async {
      await mount(tester);
      final import = find.byTooltip('导入预设（JSON）');
      await tester.tap(import);
      await tester.pumpAndSettle();
      expect(presets.imported, isEmpty);
      expect(find.byType(SnackBar), findsNothing);

      picker.text = '[{"positive":"valid"},{"positive":12}]';
      await tester.tap(import);
      await tester.pumpAndSettle();
      expect(presets.imported, isEmpty);
      expect(find.textContaining('导入失败'), findsOneWidget);

      picker.text = jsonEncode([
        {'id': 'repeat', 'positive': 'old'},
        {
          'id': 'repeat',
          'name': 'New',
          'positive': 'latest',
          'negative': 'bad',
          'scope': 'v5',
          'positivePlacement': 'suffix',
        },
      ]);
      await tester.tap(import);
      await tester.pumpAndSettle();
      final imported = presets.imported.single.single;
      expect(imported.id, 'repeat');
      expect(imported.positive, 'latest');
      expect(imported.negative, 'bad');
      expect(imported.scope, 'v5');
      expect(imported.suffixPositive, isTrue);
      expect(presets.activations, 0);
      expect(picker.calls, 3);
    },
  );

  testWidgets(
    'picker imports valid files together, skips errors and updates repeated IDs in order',
    (tester) async {
      await mount(tester);
      PlatformFile input(String name, String text) {
        final bytes = Uint8List.fromList(utf8.encode(text));
        return PlatformFile(name: name, size: bytes.length, bytes: bytes);
      }

      picker.files = [
        input('一.json', '{"id":"repeat","positive":"old"}'),
        input('坏.json', '[{"id":"partial","positive":"omit"},{"positive":12}]'),
        input(
          '二.JSON',
          '{"presets":[{"id":"second","negative":"rain"},{"id":"repeat","positive":"new"}]}',
        ),
      ];
      await tester.tap(find.byTooltip('导入预设（JSON）'));
      await tester.pumpAndSettle();
      final batch = presets.imported.single;
      expect(batch.map((p) => p.id), ['repeat', 'second']);
      expect(batch.first.positive, 'new');
      expect(batch.last.negative, 'rain');
      expect(find.textContaining('已导入 2 个预设'), findsOneWidget);
      expect(find.textContaining('坏.json'), findsOneWidget);
      expect(presets.activeId, 'c');
    },
  );

  testWidgets(
    'Explorer drop reads each JSON by path and reports rejected files without blocking later files',
    (tester) async {
      await mount(tester);
      final dir = Directory.systemTemp.createTempSync(
        'plana_prompt_preset_drop_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final first = File('${dir.path}/晨光.JSON')
        ..writeAsStringSync('{"id":"day","positive":"sunlight"}');
      final last = File('${dir.path}/星光.json')
        ..writeAsStringSync('{"id":"night","negative":"sun"}');
      final large = File('${dir.path}/过大.json');
      final handle = large.openSync(mode: FileMode.write);
      handle.truncateSync(5 * 1024 * 1024 + 1);
      handle.closeSync();
      final point = tester.getCenter(find.byType(ReorderableListView));
      final scale = tester.view.devicePixelRatio;
      Future<void> native(String method, List<String> paths) async {
        await tester.runAsync(() async {
          await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            DesktopImageDropHost.channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, {
                'x': point.dx * scale,
                'y': point.dy * scale,
                'paths': paths,
              }),
            ),
            (_) {},
          );
        });
        await tester.pump();
      }

      await native('over', []);
      expect(find.text('松开以导入预设（JSON）'), findsOneWidget);
      await native('drop', [
        first.path,
        '${dir.path}/图片.png',
        large.path,
        '${dir.path}/缺失.json',
        last.path,
      ]);
      await pumpUntil(tester, () => presets.imported.isNotEmpty);
      await tester.pumpAndSettle();
      expect(presets.imported.single.map((p) => p.id), ['day', 'night']);
      expect(presets.activations, 0);
      expect(find.textContaining('3 个文件无法导入'), findsOneWidget);
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      final details = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .data!;
      expect(
        details,
        allOf(
          contains('图片.png'),
          contains('过大.json'),
          contains('5 MB'),
          contains('缺失.json'),
        ),
      );
    },
  );

  testWidgets(
    'mouse movement reorders immediately without activating or editing',
    (tester) async {
      await mount(tester);
      final first = tester.getRect(find.byKey(const ValueKey('a')));
      final last = tester.getRect(find.byKey(const ValueKey('c')));
      final pointer = await tester.startGesture(
        first.center,
        kind: PointerDeviceKind.mouse,
      );
      await pointer.moveBy(const Offset(0, 25));
      await tester.pump(const Duration(milliseconds: 1));
      await pointer.moveTo(Offset(first.center.dx, last.bottom));
      await tester.pump(const Duration(milliseconds: 100));
      await pointer.up();
      await tester.pumpAndSettle();
      expect(presets.reorders, 1);
      expect(presets.current.presets.map((p) => p.id), ['b', 'a', 'c']);
      expect(presets.activations, 0);
      expect(presets.activeId, 'c');
      expect(find.text('编辑预设'), findsNothing);

      final click = await tester.startGesture(
        tester.getCenter(find.text('Alpha')),
        kind: PointerDeviceKind.mouse,
      );
      await click.moveBy(const Offset(.1, .1));
      await click.up();
      await tester.pumpAndSettle();
      expect(presets.activations, 1);
      expect(presets.reorders, 1);

      await tester.tap(find.byTooltip('编辑').first);
      await tester.pumpAndSettle();
      expect(find.text('编辑预设'), findsOneWidget);
      expect(presets.reorders, 1);
    },
  );

  testWidgets('touch still waits for long press before reordering on desktop', (
    tester,
  ) async {
    await mount(tester);
    final first = tester.getCenter(find.byKey(const ValueKey('a')));
    final short = await tester.startGesture(first);
    await short.moveBy(const Offset(0, 50));
    await short.up();
    await tester.pumpAndSettle();
    expect(presets.reorders, 0);
    expect(presets.activations, 0);

    final held = await tester.startGesture(first);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await held.moveTo(tester.getCenter(find.byKey(const ValueKey('c'))));
    await tester.pump(const Duration(milliseconds: 300));
    await held.up();
    await tester.pumpAndSettle();
    expect(presets.reorders, 1);
    expect(presets.activations, 0);
  });

  test(
    'failed concurrent imports can retry and merge without changing activation or order',
    () async {
      final fixture = Directory.systemTemp.createTempSync(
        'plana_presets_import_',
      );
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        paths,
        (_) async => fixture.path,
      );
      final stores = await AppStores.open(rootOverride: fixture);
      final container = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      try {
        await container.read(promptPresetsProvider.future);
        final notifier = container.read(promptPresetsProvider.notifier);
        final source = jsonEncode({
          'presets': [
            {
              'id': 'first',
              'positive': 'a',
              'negative': 'b',
              'scope': 'legacy',
              'positivePlacement': 'suffix',
            },
            {'name': 'without id', 'positive': 'c'},
          ],
        });
        final incoming = parsePresetFile(source);
        Future<int> importOne(PromptPreset preset) =>
            notifier.importPresets([preset], requirePersistence: true);
        // A directory at the target path prevents the file from being committed.
        final blockedTarget = Directory('${fixture.path}/prompt_presets.json');
        await blockedTarget.create();
        await Future.wait([
          for (final preset in incoming)
            expectLater(importOne(preset), throwsA(isA<FileSystemException>())),
        ]);
        expect(
          container.read(promptPresetsProvider).requireValue.presets,
          kDefaultPromptPresets,
        );
        await blockedTarget.delete();
        expect(await Future.wait(incoming.map(importOne)), [1, 1]);
        expect(
          container
              .read(promptPresetsProvider)
              .requireValue
              .presets
              .skip(kDefaultPromptPresets.length)
              .map((preset) => preset.id),
          incoming.map((preset) => preset.id),
        );
        await notifier.setActive('first');
        await notifier.reorder(5, 0);
        final orderBefore = container
            .read(promptPresetsProvider)
            .requireValue
            .presets
            .map((p) => p.id)
            .toList();
        await notifier.importPresets(parsePresetFile(source));
        final current = container.read(promptPresetsProvider).requireValue;
        expect(current.presets, hasLength(kDefaultPromptPresets.length + 2));
        expect(current.presets.map((p) => p.id), orderBefore);
        expect(container.read(activePromptPresetIdProvider), 'first');
        await stores.flushForExit();
        final restoredStores = await AppStores.open(rootOverride: fixture);
        final restoredContainer = ProviderContainer(
          overrides: [appStoresProvider.overrideWithValue(restoredStores)],
        );
        try {
          final restored = await restoredContainer.read(
            promptPresetsProvider.future,
          );
          expect(restored.presets.map((p) => p.id), orderBefore);
          expect(restored.presets.any((p) => p.id == 'first'), isTrue);
          expect(restoredContainer.read(activePromptPresetIdProvider), 'first');
          final first = restored.presets.firstWhere((p) => p.id == 'first');
          expect(first.positive, 'a');
          expect(first.negative, 'b');
          expect(first.scope, 'legacy');
          expect(first.suffixPositive, isTrue);
        } finally {
          restoredContainer.dispose();
        }
      } finally {
        container.dispose();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
        fixture.deleteSync(recursive: true);
      }
    },
  );
}
