import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/ui/expand_body.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';
import 'package:plana_app/features/inspiration/tag_editor_page.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

import 'support/desktop_capture.dart';
import 'support/pump_until.dart';

class _StyleBackend extends BackendClient {
  _StyleBackend() : super('https://example.invalid');

  final covers = <String?>[];
  Completer<void>? pending;

  @override
  Future<({String id, String name})> createPublicArtist({
    required String sessionId,
    required String artistString,
    String? name,
    String negative = '',
    String? previewBase64,
    String? addedBy,
    List<String>? models,
    Map<String, dynamic>? recipe,
  }) async {
    covers.add(previewBase64);
    await pending?.future;
    return (id: 'new-public-style', name: name!);
  }

  @override
  Future<void> updatePublicArtist({
    required String sessionId,
    required String id,
    String? artistString,
    String? negative,
    String? previewBase64,
    String? addedBy,
    List<String>? models,
    Map<String, dynamic>? recipe,
  }) async {
    covers.add(previewBase64);
    await pending?.future;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const saved = TagEntry(
    id: 'artist-fixture',
    category: TagCategory.artist,
    name: '测试画风',
    positive: 'artist:test, soft color',
    negative: 'bad anatomy, worst quality',
    createdAt: 1,
  );
  late Directory temp;
  late File libraryFile;
  late AppStores stores;
  late ProviderContainer container;
  late _StyleBackend backend;
  final capture = GlobalKey();

  setUpAll(loadDesktopCaptureFonts);

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('plana_artist_negative_');
    libraryFile = File('${temp.path}/tag_library.json')
      ..writeAsStringSync(jsonEncode({'entries': []}));
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => temp.path,
    );
    stores = AppStores.ephemeral();
    backend = _StyleBackend();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        backendClientProvider.overrideWithValue(backend),
        publicTagsProvider.overrideWith((ref, cat) async => []),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    expect(temp.parent.absolute.path, Directory.systemTemp.absolute.path);
    temp.deleteSync(recursive: true);
  });

  Finder key(String value) => find.byKey(ValueKey(value));
  Finder field(String hint) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.hintText == hint,
  );
  Finder nameField() => field('给画风起个名字');
  Finder positiveField() => field('例如: wlop, rurudo');
  Finder negativeField() => field('例如: bad anatomy, worst quality');
  String textIn(WidgetTester tester, Finder input) =>
      tester.widget<TextField>(input).controller!.text;
  bool negativeOpen(WidgetTester tester) => tester
      .widget<ExpandBody>(
        find
            .ancestor(of: negativeField(), matching: find.byType(ExpandBody))
            .first,
      )
      .expanded;

  List<TagEntry> diskEntries() => [
    for (final raw
        in (jsonDecode(libraryFile.readAsStringSync()) as Map)['entries']
            as List)
      TagEntry.fromJson(Map<String, dynamic>.from(raw as Map))!,
  ];

  Future<void> mount(WidgetTester tester, {TagEntry? initial}) async {
    if (initial != null) {
      libraryFile.writeAsStringSync(
        jsonEncode({
          'entries': [initial.toJson()],
        }),
      );
    }
    await tester.runAsync(() => container.read(tagLibraryProvider.future));
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            theme: AppTheme.light().copyWith(
              textTheme: AppTheme.light().textTheme.apply(
                fontFamily: 'Microsoft YaHei',
              ),
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        key: const ValueKey('new-artist'),
                        onPressed: () =>
                            showTagEditor(context, cat: TagCategory.artist),
                        child: const Text('新建测试画风'),
                      ),
                      TextButton(
                        key: const ValueKey('edit-artist'),
                        onPressed: () => showTagEditor(
                          context,
                          cat: TagCategory.artist,
                          edit: container
                              .read(tagLibraryProvider)
                              .requireValue
                              .entries
                              .single,
                        ),
                        child: const Text('打开测试画风'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, Finder finder, String value) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.enterText(finder, value);
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, {bool create = false}) async {
    await tap(tester, key(create ? 'new-artist' : 'edit-artist'));
    expect(key('tag-editor-dialog'), findsOneWidget);
  }

  Future<void> save(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pump();
    await pumpUntil(
      tester,
      () => key('tag-editor-dialog').evaluate().isEmpty,
      reason: 'Artist save must finish before closing its editor',
    );
    await tester.pumpAndSettle();
    expect(key('tag-editor-dialog'), findsNothing);
  }

  Future<void> reloadLibrary(WidgetTester tester) async {
    container.invalidate(tagLibraryProvider);
    await tester.runAsync(() => container.read(tagLibraryProvider.future));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'saving and publishing keeps the edited local original through a failed publication',
    (tester) async {
      final bytes = img.encodePng(img.Image(width: 96, height: 64));
      stores.gallery.initialResults = [
        ResultImage(
          id: 'publish-cover',
          width: 96,
          height: 64,
          seed: 2,
          bytes: bytes,
        ),
      ];
      await mount(tester, initial: saved);
      await container.read(botSessionProvider.future);
      await container
          .read(botSessionProvider.notifier)
          .save(const BotSession(sessionId: 'test'));
      await open(tester);
      await tap(tester, find.text('历史'));
      await tap(tester, key('quick-gallery-image-publish-cover'));
      await tap(tester, find.text('保存并发布'));
      backend.pending = Completer<void>();
      await tester.tap(find.text('我已确认,发布'));
      await pumpUntil(tester, () => backend.covers.isNotEmpty);
      final local = diskEntries().single;
      expect(local.id, saved.id);
      expect(local.origin, TagOrigin.local);
      expect(File(local.previewUrl!).readAsBytesSync(), orderedEquals(bytes));
      backend.pending!.completeError(BackendException('测试发布失败'));
      await pumpUntil(
        tester,
        () => key('tag-editor-dialog').evaluate().isEmpty,
      );
      backend.pending = null;

      await open(tester);
      await tap(tester, find.text('保存并发布'));
      await tester.tap(find.text('我已确认,发布'));
      await pumpUntil(
        tester,
        () => key('tag-editor-dialog').evaluate().isEmpty,
      );
      final published = diskEntries().single;
      expect(published.id, local.id);
      expect(published.publicId, 'new-public-style');
      expect(published.origin, TagOrigin.created);
      expect(published.previewUrl, local.previewUrl);
      expect(backend.covers, [base64Encode(bytes), base64Encode(bytes)]);
      await finish(tester);
    },
  );

  testWidgets(
    'gallery replaces one style slot and its saved cover survives failed sync and retry',
    (tester) async {
      final original = File('assets/app_icon.png').readAsBytesSync();
      final first = File('${temp.path}/first.png')..writeAsBytesSync(original);
      final second = File('${temp.path}/second.png')
        ..writeAsBytesSync(original);
      final bytes = img.encodePng(img.Image(width: 80, height: 40));
      stores.gallery.initialResults = [
        ResultImage(id: 'wide', width: 80, height: 40, seed: 92, bytes: bytes),
      ];
      final entry = saved.copyWith(
        origin: TagOrigin.created,
        publicId: 'style',
        previews: [first.path, second.path],
      );
      await mount(tester, initial: entry);
      await container.read(botSessionProvider.future);
      await container
          .read(botSessionProvider.notifier)
          .save(const BotSession(sessionId: 'test'));

      await open(tester);
      await tap(tester, key('tag-preview-slot-drop-1'));
      await tap(tester, find.widgetWithText(ListTile, '从图库选取'));
      await tap(tester, key('quick-gallery-image-wide'));
      await save(tester, '保存到本地');
      final slots = diskEntries().single.previews;
      expect(slots.first, first.path);
      expect(File(slots[1]).readAsBytesSync(), orderedEquals(bytes));
      expect(backend.covers, isEmpty);

      await open(tester);
      await tap(tester, key('tag-preview-slot-drop-1'));
      await tap(tester, find.text('设为封面'));
      backend.pending = Completer<void>();
      await tester.tap(find.text('保存并同步'));
      await pumpUntil(tester, () => backend.covers.isNotEmpty);
      expect(diskEntries().single.previews, slots.reversed.toList());
      expect(backend.covers.single, base64Encode(bytes));
      backend.pending!.completeError(BackendException('测试离线'));
      await pumpUntil(
        tester,
        () => key('tag-editor-dialog').evaluate().isEmpty,
      );
      expect(find.textContaining('公共库同步失败'), findsOneWidget);

      backend.pending = null;
      await reloadLibrary(tester);
      await open(tester);
      await save(tester, '保存并同步');
      expect(backend.covers, [base64Encode(bytes), base64Encode(bytes)]);
      expect(diskEntries().single.previews, slots.reversed.toList());
      await finish(tester);
    },
  );

  testWidgets(
    'new artist starts folded, saves entered negative, and reopens it expanded from disk',
    (tester) async {
      await mount(tester);
      await open(tester, create: true);
      expect(find.text('负面提示词'), findsOneWidget);
      expect(negativeOpen(tester), isFalse);
      await enter(tester, nameField(), '新画风');
      await enter(tester, positiveField(), 'artist:test, light colors');
      await tap(tester, find.text('负面提示词'));
      expect(negativeOpen(tester), isTrue);
      await enter(tester, negativeField(), '  bad hands, bad eyes  ');
      await tap(tester, find.text('负面提示词'));
      expect(negativeOpen(tester), isFalse);
      await tap(tester, find.text('负面提示词'));
      expect(textIn(tester, negativeField()), '  bad hands, bad eyes  ');
      await save(tester, '保存到本地');
      expect(diskEntries().single.negative, 'bad hands, bad eyes');
      expect(diskEntries().single.positive, 'artist:test, light colors');
      await reloadLibrary(tester);
      await open(tester);
      expect(negativeOpen(tester), isTrue);
      expect(textIn(tester, negativeField()), 'bad hands, bad eyes');
      await captureDesktop(
        tester,
        capture,
        'windows40-artist-negative-expanded',
      );
      await finish(tester);
    },
  );

  testWidgets(
    'existing artist negative can be modified and then cleared persistently',
    (tester) async {
      await mount(tester, initial: saved);
      await open(tester);
      expect(negativeOpen(tester), isTrue);
      expect(textIn(tester, negativeField()), saved.negative);
      await enter(tester, negativeField(), '  edited exclusion  ');
      await save(tester, '保存修改');
      expect(diskEntries().single.negative, 'edited exclusion');
      expect(diskEntries().single.id, saved.id);
      await reloadLibrary(tester);
      await open(tester);
      expect(textIn(tester, negativeField()), 'edited exclusion');
      await enter(tester, negativeField(), '');
      await save(tester, '保存修改');
      expect(diskEntries().single.negative, isEmpty);
      expect(diskEntries().single.positive, saved.positive);
      await reloadLibrary(tester);
      await open(tester);
      expect(negativeOpen(tester), isFalse);
      expect(textIn(tester, negativeField()), isEmpty);
      await finish(tester);
    },
  );

  for (final create in [false, true]) {
    testWidgets(
      'cancelling ${create ? 'new' : 'existing'} artist discards negative edits without touching the library',
      (tester) async {
        await mount(tester, initial: saved);
        final before = libraryFile.readAsStringSync();
        await open(tester, create: create);
        if (create) {
          await enter(tester, nameField(), '未保存');
          await enter(tester, positiveField(), 'uncommitted positive');
          await tap(tester, find.text('负面提示词'));
        }
        await enter(tester, negativeField(), 'uncommitted exclusion');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(key('tag-editor-dialog'), findsNothing);
        expect(libraryFile.readAsStringSync(), before);
        expect(
          container
              .read(tagLibraryProvider)
              .requireValue
              .entries
              .single
              .negative,
          saved.negative,
        );
        await open(tester);
        expect(textIn(tester, negativeField()), saved.negative);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'importing main positive preserves the independently edited artist negative',
    (tester) async {
      container
          .read(generateProvider.notifier)
          .setPrompts(
            positive: 'imported artist, imported color',
            negative: 'global negative should not replace style',
          );
      await mount(tester, initial: saved);
      await open(tester);
      await tap(tester, find.text('导入主提示词'));
      expect(
        textIn(tester, positiveField()),
        'imported artist, imported color',
      );
      expect(textIn(tester, negativeField()), saved.negative);
      await enter(tester, negativeField(), 'my edited style negative');
      await tap(tester, find.text('导入主提示词'));
      expect(textIn(tester, negativeField()), 'my edited style negative');
      await save(tester, '保存修改');
      expect(diskEntries().single.negative, 'my edited style negative');
      expect(diskEntries().single.positive, 'imported artist, imported color');
      await finish(tester);
    },
  );

  testWidgets(
    'favorited public artist shows negative read-only and tag-only save preserves source text',
    (tester) async {
      final favorite = saved.copyWith(
        origin: TagOrigin.favorited,
        publicId: 'public-test',
      );
      container
          .read(generateProvider.notifier)
          .setPrompts(positive: 'available import', negative: 'other');
      await mount(tester, initial: favorite);
      await open(tester);
      expect(negativeOpen(tester), isTrue);
      expect(textIn(tester, negativeField()), saved.negative);
      expect(tester.widget<TextField>(negativeField()).readOnly, isTrue);
      expect(tester.widget<TextField>(positiveField()).readOnly, isTrue);
      expect(tester.widget<TextField>(nameField()).readOnly, isTrue);
      expect(find.text('导入主提示词'), findsNothing);
      expect(find.text('粘贴'), findsNothing);
      expect(find.text('保存修改'), findsNothing);
      expect(find.text('保存并发布'), findsNothing);
      await save(tester, '保存标签修改');
      final result = diskEntries().single;
      expect(result.negative, saved.negative);
      expect(result.positive, saved.positive);
      expect(result.origin, TagOrigin.favorited);
      expect(result.publicId, 'public-test');
      await finish(tester);
    },
  );
}
