import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plana_app/core/store/desktop_output_store.dart';
import 'package:plana_app/features/gallery/models.dart';

void main() {
  test(
    'WebP output migrates and deletes its owned pair beside a private PNG',
    () async {
      final temp = await Directory.systemTemp.createTemp('plana-webp-output-');
      addTearDown(() => temp.delete(recursive: true));
      final old = Directory(p.join(temp.path, 'old')),
          next = Directory(p.join(temp.path, 'new'));
      final bytes = await File('test/fixtures/nai_sample.webp').readAsBytes();
      final result = ResultImage(
        id: 'gen7',
        createdAt: 1000,
        width: 64,
        height: 64,
        seed: 1,
        bytes: bytes,
      );
      final file = await DesktopOutputStore(old).save(result);
      expect(p.extension(file.path), '.webp');
      expect(
        jsonDecode(
          await File(p.setExtension(file.path, '.json')).readAsString(),
        )['format'],
        'webp',
      );
      final other = File(p.setExtension(file.path, '.png'));
      await other.writeAsString('private');
      final store = DesktopOutputStore(next, legacyRoots: [old]);
      expect((await store.migrateLegacy()).migrated, 1);
      final migrated = File(
        p.join(next.path, p.relative(file.path, from: old.path)),
      );
      expect(await migrated.readAsBytes(), bytes);
      expect(await store.deleteResults([result]), {'gen7'});
      expect(await migrated.exists(), false);
      expect(await other.readAsString(), 'private');
    },
  );
}
