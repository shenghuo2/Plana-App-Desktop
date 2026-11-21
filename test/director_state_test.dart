import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/director/director_models.dart';
import 'package:plana_app/features/director/director_service.dart';
import 'package:plana_app/features/director/director_state.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/generate/generate_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer c;
  late Completer<List<DirectorOutput>> response;
  late Uint8List bytes;
  late int calls;
  late DirectorInput sentSource;
  late DirectorOptions sentOptions;
  late String album;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('plana_director_');
    stores = await AppStores.open(rootOverride: root);
    bytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 32, height: 48, numChannels: 4)),
    );
    response = Completer<List<DirectorOutput>>();
    calls = 0;
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(false),
        directorAccessProvider.overrideWithValue(
          const DirectorAccess(
            key: NaiKey(id: 'one', token: 'test-only'),
          ),
        ),
        directorRunnerProvider.overrideWithValue((source, options, access) {
          calls++;
          sentSource = source;
          sentOptions = options;
          return response.future;
        }),
      ],
    );
    album = await c.read(albumsProvider.notifier).create('test');
    c.read(albumsProvider.notifier).setSave(album);
  });
  tearDown(() async {
    c.dispose();
    await stores.flushForExit();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<ResultImage> original() => c
      .read(galleryProvider.notifier)
      .addResultToGallery(
        bytes: bytes,
        width: 32,
        height: 48,
        seed: 123,
        target: GallerySaveTarget.album(album),
      );

  test(
    'history input copies are independent and removal never touches gallery or prompts',
    () async {
      final image = await original();
      c
          .read(generateProvider.notifier)
          .setPrompts(positive: 'keep prompt', negative: 'keep negative');
      final director = c.read(directorProvider.notifier);
      await director.addHistory(image);
      await director.addHistory(image);
      expect(c.read(directorProvider).inputs.length, 2);
      final ids = c.read(directorProvider).inputs.map((e) => e.id).toSet();
      expect(ids.length, 2);
      director.selectPreview(image);
      director.removeInput(ids.first);
      expect(c.read(directorProvider).inputs.length, 1);
      expect(c.read(galleryProvider).results.length, 1);
      expect(await stores.gallery.readImage(image.id), bytes);
      expect(c.read(generateProvider).prompt, 'keep prompt');
    },
  );

  test(
    'in-flight request snapshots source options and album without selecting main canvas',
    () async {
      final source = await original();
      final director = c.read(directorProvider.notifier);
      await director.addHistory(source);
      director.options(
        const DirectorOptions(
          tool: DirectorTool.emotion,
          emotion: 'happy',
          defry: 3,
        ),
      );
      final pending = director.transform();
      await director.transform(); // Double click is ignored.
      expect(calls, 1);
      await director.addInput('next.png', bytes);
      director.options(const DirectorOptions(tool: DirectorTool.sketch));
      final other = await c.read(albumsProvider.notifier).create('later');
      c.read(albumsProvider.notifier).setSave(other);
      c.read(albumsProvider.notifier).browse(album);
      response.complete([DirectorOutput(bytes, 32, 48)]);
      await pending;
      final state = c.read(directorProvider);
      expect(sentSource.galleryId, source.id);
      expect(sentOptions.emotion, 'happy');
      expect(sentOptions.defry, 3);
      expect(state.source!.name, 'next.png');
      expect(state.options.tool, DirectorTool.sketch);
      expect(state.busy, false);
      expect(state.failed, false);
      expect(c.read(galleryProvider).selectedId, source.id);
      final result = state.preview!;
      expect(result.operation!.tool, 'emotion');
      expect(result.seed, -1);
      expect(result.hasInput, false);
      expect(c.read(albumsProvider).ofImage(result.id), {album});
      expect(result.operation!.sourceId, source.id);
      expect(await stores.gallery.readImage(result.id), isNotNull);
      await stores.flushForExit();
      final reopened = await AppStores.open(rootOverride: root);
      final restored = reopened.gallery.initialResults.firstWhere(
        (e) => e.id == result.id,
      );
      expect(restored.operation!.toJson(), result.operation!.toJson());
      expect(
        restored
            .stripped()
            .withFavorite(true)
            .withCreatedAt(99)
            .operation!
            .jobId,
        result.operation!.jobId,
      );
      await reopened.flushForExit();
    },
  );

  test(
    'deleted target falls back to all works and multi-image result keeps every variant',
    () async {
      final source = await original();
      final director = c.read(directorProvider.notifier);
      await director.addHistory(source);
      final pending = director.transform();
      await c.read(albumsProvider.notifier).delete(album);
      response.complete([
        for (final variant in ['masked', 'generated', 'blend'])
          DirectorOutput(bytes, 32, 48, variant: variant),
      ]);
      await pending;
      final state = c.read(directorProvider);
      expect(state.latest.map((e) => e.operation!.variant), [
        'masked',
        'generated',
        'blend',
      ]);
      expect(state.preview!.operation!.variant, 'blend');
      for (final result in state.latest) {
        expect(c.read(albumsProvider).ofImage(result.id), isEmpty);
        expect(result.badge, ResultBadge.director);
      }
      expect(c.read(galleryProvider).selectedId, source.id);
    },
  );

  test(
    'failed conversion preserves previous preview and never retries automatically',
    () async {
      final source = await original();
      final director = c.read(directorProvider.notifier);
      await director.addHistory(source);
      director.selectPreview(source);
      final pending = director.transform();
      response.completeError(const FormatException('接口未返回图片'));
      await pending;
      expect(calls, 1);
      expect(c.read(directorProvider).failed, true);
      expect(c.read(directorProvider).preview!.id, source.id);
      expect(c.read(directorProvider).source!.galleryId, source.id);
      expect(c.read(galleryProvider).results.length, 1);
    },
  );

  test(
    'disk write failure retries the same result without another API request',
    () async {
      final director = c.read(directorProvider.notifier);
      await director.addInput('source.png', bytes);
      // A temporary test-only directory obstructs the next atomic output file.
      final blocker = Directory('${root.path}/gallery/images/gen0.png');
      await blocker.create();
      final pending = director.transform();
      response.complete([DirectorOutput(bytes, 32, 48)]);
      await pending;
      expect(c.read(directorProvider).hasPendingSave, true);
      expect(c.read(directorProvider).failed, true);
      expect(c.read(galleryProvider).results.length, 1);
      await blocker.delete();
      await director.retrySave();
      expect(calls, 1);
      expect(c.read(directorProvider).hasPendingSave, false);
      expect(c.read(directorProvider).failed, false);
      expect(c.read(galleryProvider).results.length, 1);
      expect(await stores.gallery.readImage('gen0'), isNotNull);
      expect(c.read(albumsProvider).ofImage('gen0'), {album});
    },
  );
}
