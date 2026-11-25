import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plana_app/features/profile/manual/manual_library.dart';

void main() {
  late Directory temp;
  late ManualLibrary library;
  Map<String, dynamic> page() => {
    'id': 'guide',
    'section': 'advanced',
    'title': '使用说明',
    'summary': '画布入门',
    'blocks': <Map<String, dynamic>>[
      {'type': 'h2', 'id': 'intro', 'text': '开始'},
      {'type': 'p', 'text': '先打开创作页'},
    ],
  };

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('plana-manual-test-');
    library = ManualLibrary(Directory(p.join(temp.path, 'manual')));
    await library.prepare();
  });
  tearDown(() async {
    await library.close();
    await temp.delete(recursive: true);
  });

  test(
    'committed media and edits survive reopening while unused draft media is discarded',
    () async {
      final source = File(p.join(temp.path, '带标注的截图.PNG'));
      await source.writeAsBytes([1, 2, 3]);
      final used = await library.stage(source);
      final unused = await library.stage(source);
      final article = page();
      (article['blocks'] as List).add(used);
      final saved = await library.save(article);
      await library.close();
      final reopened = ManualLibrary(library.root);
      final data = await reopened.load();
      expect(data['pages'], [saved]);
      expect(data['unreadable'], isEmpty);
      expect(
        await File(p.join(reopened.media.path, used['file'])).readAsBytes(),
        [1, 2, 3],
      );
      expect(
        await File(p.join(reopened.media.path, unused['file'])).exists(),
        isFalse,
      );
      expect(await source.exists(), isTrue);
    },
  );

  test('a stale edit cannot overwrite a newer revision', () async {
    final first = await library.save(page());
    final latest = await library.save({...first, 'title': '新版'});
    await expectLater(
      library.save({...first, 'title': '旧版'}),
      throwsFormatException,
    );
    expect((await library.load())['pages'], [latest]);
  });

  test('page links and section links survive saving and reopening', () async {
    final article = page();
    final cards = [
      {'target': 'guide', 'title': '读整页', 'desc': ''},
      {'target': 'guide', 'title': '#guide/intro', 'desc': '旧版链接'},
      {'target': 'guide', 'heading': 'intro', 'title': '从这里开始', 'desc': ''},
      {'target': 'guide', 'heading': '', 'title': '返回页首', 'desc': ''},
    ];
    (article['blocks'] as List).add({'type': 'cards', 'items': cards});
    final saved = await library.save(article);
    final reopened = ManualLibrary(library.root);
    expect((await reopened.load())['pages'], [saved]);
    cards.last['heading'] = '../unknown';
    await expectLater(
      library.save({...article, 'revision': saved['revision']}),
      throwsFormatException,
    );
    await reopened.close();
  });

  test(
    'refuses missing media and invalid paths and reports individual damaged pages',
    () async {
      final saved = await library.save(page());
      final invalid = {
        ...saved,
        'blocks': [
          {
            'type': 'video',
            'file': 'm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.webm',
            'caption': '',
          },
        ],
      };
      await expectLater(library.save(invalid), throwsFormatException);
      await expectLater(
        library.save({...saved, 'id': '../outside'}),
        throwsFormatException,
      );
      await File(
        p.join(library.pages.path, 'damaged.json'),
      ).writeAsString(jsonEncode({}));
      final loaded = await library.load();
      expect(loaded['pages'], [saved]);
      expect(loaded['unreadable'], ['damaged.json']);
    },
  );
}
