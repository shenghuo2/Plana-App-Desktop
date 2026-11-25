import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/inspiration/widgets/tag_filter_sheet.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plana_app/features/inspiration/external/oc_catalog.dart';
import 'package:plana_app/features/inspiration/external/oc_browser.dart';
import 'package:plana_app/features/inspiration/widgets/tag_filter_chips.dart';
import 'package:plana_app/features/inspiration/external/oc_sources.dart';
import 'package:plana_app/features/assistant/runtime/reference_library.dart';
import 'package:plana_app/features/assistant/tools/my_library.dart';
import 'package:plana_app/features/inspiration/widgets/sidebar_inspiration.dart';

class _Network extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Map<String, String> secret;
  late OcRepository repo;
  OcRepository open({DateTime Function() clock = DateTime.now}) => OcRepository(
    Directory('${dir.path}/libraries'),
    now: clock,
    readSecret: (k) async => secret[k],
    saveSecret: (k, v) async {
      secret[k] = v;
    },
    deleteSecret: (k) async {
      secret.remove(k);
    },
  );
  setUp(() {
    dir = Directory.systemTemp.createTempSync('plana-oc-test');
    secret = {};
    repo = open();
  });
  tearDown(() async {
    repo.close();
    await dir.delete(recursive: true);
  });
  test(
    'author counts match grouped cards across libraries, search, tags and favorites',
    () async {
      final file = File('${dir.path}/counts.json');
      await file.writeAsString(
        jsonEncode({
          'characters': [
            for (var i = 0; i < 29; i++)
              {
                'name': 'Actor $i',
                'author': 'Author',
                'forms': [
                  {
                    'name': 'Dawn',
                    'prompt': 'day',
                    'tags': ['day'],
                  },
                  {
                    'name': 'Morning',
                    'prompt': 'day',
                    'tags': ['sun'],
                  },
                  {
                    'name': 'Night',
                    'prompt': 'day',
                    'negativePrompt': 'sun',
                    'tags': ['night'],
                  },
                ],
              },
            {'name': 'Solo', 'author': 'Other', 'prompt': 'solo'},
          ],
        }),
      );
      final source = await repo.connect(file.uri);
      final file2 = File('${dir.path}/more.json');
      await file2.writeAsString(
        jsonEncode({
          'characters': [
            {'name': 'Solo 2', 'author': 'Author', 'prompt': 'solo'},
          ],
        }),
      );
      final second = await repo.connect(file2.uri);
      final entries = await repo.referenceEntries(source);
      final fav = {entries.first.id, entries[3].id};
      Future<Map<String, int>> counts(
        InspirationTagFilter filter, {
        String query = '',
        bool any = false,
        bool all = false,
        Map<String, List<String>> tagOverrides = const {},
      }) async {
        final items = matchingOcCharacters(
          [source, if (all) second],
          search: query,
          author: null,
          filter: filter,
          matchAny: any,
          favorites: fav,
          tagOverrides: tagOverrides,
        );
        final result = <String, int>{};
        for (final author in items.map((i) => i.character.author).toSet()) {
          final n = await countMatchingOcCards(
            items.where((i) => i.character.author == author).toList(),
            repo,
            search: query,
            filter: filter,
            matchAny: any,
            favorites: fav,
            tagOverrides: tagOverrides,
          );
          if (n > 0) result[author] = n;
        }
        return result;
      }

      final overrides = {
        entries.first.id: ['edited'],
        entries.last.id: ['edited'],
      };
      expect(
        await counts(
          const InspirationTagFilter(tags: {'edited'}),
          tagOverrides: overrides,
        ),
        {'Author': 1, 'Other': 1},
      );
      expect(
        await counts(
          const InspirationTagFilter(),
          query: 'Actor 0 edited',
          tagOverrides: overrides,
        ),
        {'Author': 1},
      );
      expect(
        await counts(
          const InspirationTagFilter(tags: {'sun'}),
          tagOverrides: overrides,
        ),
        {'Author': 28},
      );
      expect(await counts(const InspirationTagFilter(), all: true), {
        'Author': 59,
        'Other': 1,
      });
      expect(await counts(const InspirationTagFilter(), query: 'Night'), {
        'Author': 29,
      });
      expect(await counts(const InspirationTagFilter(tags: {'day', 'sun'})), {
        'Author': 29,
      });
      expect(
        await counts(const InspirationTagFilter(tags: {'day', 'night'})),
        isEmpty,
      );
      expect(
        await counts(
          const InspirationTagFilter(tags: {'day', 'night'}),
          any: true,
        ),
        {'Author': 58},
      );
      expect(
        await counts(
          const InspirationTagFilter(favorites: true, tags: {'night'}),
        ),
        {'Author': 1},
      );
    },
  );

  testWidgets(
    'unavailable form details leave only their own author pending and retryable',
    (tester) async {
      var attempts = 0;
      var fetchedCachedAuthor = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                child: const Text('Open'),
                onPressed: () => showTagFilterSheet(
                  context,
                  authors: const [
                    TagAuthor(id: 'Cache miss'),
                    TagAuthor(id: 'Cached'),
                  ],
                  current: (author: null, model: null),
                  hasModels: false,
                  loadCount: (author) async {
                    if (author == 'Cached') {
                      fetchedCachedAuthor++;
                      return 58;
                    }
                    if (++attempts == 1) throw const FormatException();
                    return 3;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('58'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      expect(find.text('3'), findsOneWidget);
      expect(fetchedCachedAuthor, 1);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'external form names stay distinct through search, prefetch and placeholders',
    () async {
      final file = File('${dir.path}/forms.json');
      await file.writeAsString(
        jsonEncode({
          'characters': [
            {
              'name': '星星',
              'forms': [
                {'id': 'base', 'name': '星星', 'prompt': 'base'},
                {
                  'id': 'dress',
                  'name': '星星（礼服）',
                  'prompt': 'dress',
                  'image': 'dress.png',
                },
                {'id': 'summer', 'name': '水着', 'prompt': 'beach'},
                {'id': 'winter', 'name': '星星（冬季常服）', 'prompt': 'winter'},
              ],
            },
          ],
        }),
      );
      final source = await repo.connect(file.uri);
      final character = source.catalog.characters.single;
      final entries = await repo.character(source, character);
      expect(entries.map((e) => e.name), [
        '星星',
        '星星（礼服）',
        '星星 · 水着',
        '星星（冬季常服）',
      ]);
      final ocs = [
        for (final e in entries)
          LibOc(
            enName: e.id,
            zhName: e.name,
            aliases: e.aliases,
            tagGroup: e.positive,
          ),
      ];
      for (final query in ['星星 礼服', '礼服 星星', '礼服星星', '星星（礼服）']) {
        expect(character.matchesSearch(query), true);
        final result = await externalOcReferences(
          repo,
          [source],
          query: query,
          search: true,
        );
        expect(result[source.id]!.map((e) => e.id), contains(entries[1].id));
        expect(searchOcs(ocs, query).map((e) => e.tagGroup), ['dress']);
        expect(matchOcs(query, ocs), [('星星（礼服）', 'dress')]);
      }
      expect(searchOcs(ocs, '星星 常服').single.tagGroup, 'winter');
      expect(matchOcs('常服 星星', ocs), [('星星（冬季常服）', 'winter')]);
      expect(matchOcs('请画星星（礼服）', ocs), [('星星（礼服）', 'dress')]);
      expect(searchOcs(ocs, '星星'), hasLength(4));
      expect(searchOcs(ocs, '水着 礼服'), isEmpty);
      expect(character.matchesSearch('水着 礼服'), false);
      expect(entries[1].previews.single, endsWith('dress.png'));
      expect(compactLibraryLabel('全部外部库'), '全部外部库');
      expect(compactLibraryLabel('一👩‍🎨二三四五六'), '一👩‍🎨二三四…');
    },
  );

  test(
    'local JSON keeps an image with its positive and negative prompt and restores sources',
    () async {
      final file = File('${dir.path}/cards.json');
      await file.writeAsString(
        jsonEncode({
          'name': 'Library',
          'characters': [
            {
              'name': 'Iris',
              'owner': 'Author',
              'tags': ['portrait'],
              'forms': [
                {
                  'name': 'Day',
                  'prompt': ' amber eyes ',
                  'images': ['day.png'],
                  'tags': ['morning'],
                },
                {'name': 'Sun', 'prompt': 'amber eyes', 'image': 'sun.png'},
                {
                  'name': 'Night',
                  'prompt': 'amber eyes',
                  'negativePrompt': 'sun',
                  'image': 'night.png',
                },
                {'name': 'Snow', 'prompt': 'snowfall', 'image': 'snow.png'},
              ],
            },
          ],
        }),
      );
      final source = await repo.connect(file.uri);
      final cards = await repo.character(
        source,
        source.catalog.characters.single,
      );
      expect(cards.length, 3);
      expect(cards.first.previews, [
        for (final n in ['day.png', 'sun.png'])
          File.fromUri(file.uri.resolve(n)).path,
      ]);
      expect(cards.first.tags, containsAll(['portrait', 'morning']));
      expect(cards[1].negative, 'sun');
      expect(cards[1].previews.single, endsWith('night.png'));
      expect(cards[2].positive, 'snowfall');
      expect((await repo.sources()).single.label, 'Library');
      expect(secret, isEmpty);
      await file.writeAsString('{"invalid":true}');
      await expectLater(repo.connect(file.uri), throwsFormatException);
      expect(
        (await repo.sources()).single.catalog.characters.single.name,
        'Iris',
      );
      await repo.remove(source);
      expect(await repo.sources(), isEmpty);
      expect(await file.exists(), true);
    },
  );

  test(
    'visitor catalog signs in, loads per-form details lazily and sends the cookie only to its origin',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        repo.close();
        repo = open();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var detailCalls = 0, imageCalls = 0;
        final requests = <String>[];
        server.listen((r) async {
          requests.add(r.uri.path);
          final logged = r.cookies.any(
            (s) => s.name == 'visitor' && s.value == 'yes',
          );
          switch (r.uri.path) {
            case '/':
              await r.response.redirect(Uri.parse('/login'));
              return;
            case '/login':
              r.response.write('<html><body data-auth="guest"></body></html>');
            case '/api/session':
              r.response.write('{"csrfToken":"token"}');
            case '/api/session/guest':
              final auth = jsonDecode(await utf8.decoder.bind(r).join());
              if (auth['password'] != 'test-only' ||
                  r.headers.value('X-CSRF-Token') != 'token') {
                r.response.statusCode = 403;
              } else {
                r.response.cookies.add(Cookie('visitor', 'yes')..path = '/');
                r.response.write('{}');
              }
            case '/api/catalog':
              if (!logged) {
                r.response.statusCode = 401;
                break;
              }
              r.response.write(
                jsonEncode({
                  'releaseId': 'v1',
                  'characters': [
                    {
                      'id': 'oc',
                      'name': 'Test',
                      'formIds': ['a', 'b'],
                    },
                  ],
                  'entries': [
                    for (final id in ['a', 'b'])
                      {
                        'id': id,
                        'name': id,
                        'hasPrompt': true,
                        'image': '/image/$id',
                      },
                  ],
                }),
              );
            default:
              if (!logged) {
                r.response.statusCode = 401;
                break;
              }
              if (r.uri.path.startsWith('/api/forms/')) {
                detailCalls++;
                expect(r.uri.queryParameters['release'], 'v1');
                r.response.write(
                  jsonEncode({
                    'id': r.uri.pathSegments.last,
                    'prompt': 'same',
                    'negativePrompt': '',
                  }),
                );
              } else if (r.uri.path.startsWith('/image/')) {
                imageCalls++;
                r.response.headers.contentType = ContentType('image', 'png');
                r.response.add([1, 2, 3]);
              } else {
                r.response.statusCode = 404;
              }
          }
          await r.response.close();
        });
        final url = Uri.parse('http://127.0.0.1:${server.port}/');
        await expectLater(
          repo.connect(url, password: 'wrong'),
          throwsA(isA<OcAccessError>()),
        );
        expect(await repo.sources(), isEmpty);
        expect(secret, isEmpty);
        final src = await repo.connect(
          url,
          label: 'Visitor library',
          password: 'test-only',
        );
        expect(detailCalls, 0);
        expect(requests, contains('/api/catalog'));
        final snapshot = File('${repo.root.path}/${src.id}/source.json');
        expect(await snapshot.readAsString(), isNot(contains('test-only')));
        final fresh = open();
        addTearDown(fresh.close);
        final actual = (await fresh.sources()).single;
        final texts = await fresh.referenceEntries(actual);
        expect(texts.single.positive, 'same');
        expect(texts.single.previews, isEmpty);
        expect(detailCalls, 2);
        expect(imageCalls, 0);
        final results = await Future.wait([
          for (var i = 0; i < 2; i++)
            fresh.character(actual, actual.catalog.characters.single),
        ]);
        expect(results.first.single.previews.length, 2);
        expect(detailCalls, 2);
        expect(imageCalls, 2);
        await fresh.character(actual, actual.catalog.characters.single);
        expect(detailCalls, 2);
        expect(imageCalls, 2);
      }, _Network());
    },
  );

  test(
    'hourly atlas refresh resumes the issued session, coalesces a reset and keeps its cached catalog on failure',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        repo.close();
        final watch = Stopwatch()..start();
        var base = DateTime.utc(2026, 1, 1, 8, 59);
        DateTime clock() => base.add(watch.elapsed);
        repo = open(clock: clock);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var logins = 0, catalogCalls = 0;
        var expected = '', release = 'one', unavailable = false, deny = false;
        final rejected = Completer<void>(), slowReply = Completer<void>();
        final updated = Completer<void>();
        server.listen((r) async {
          final logged =
              expected.isNotEmpty &&
              r.cookies.any((c) => c.name == 'visitor' && c.value == expected);
          switch (r.uri.path) {
            case '/':
              await r.response.redirect(Uri.parse('/login'));
              return;
            case '/login':
              r.response.write('<html data-auth="guest"></html>');
            case '/api/session':
              r.response.write('{"csrfToken":"renew"}');
            case '/api/session/guest':
              logins++;
              final body = jsonDecode(await utf8.decoder.bind(r).join());
              if (body['password'] != 'fixture-pass' ||
                  deny ||
                  r.headers.value('X-CSRF-Token') != 'renew') {
                r.response.statusCode = 403;
                break;
              }
              expected = 'visitor-$logins';
              r.response.cookies.add(
                Cookie('visitor', expected)
                  ..path = '/'
                  ..maxAge = 3600,
              );
              r.response.cookies.add(
                Cookie('temporary', 'memory-only')..path = '/',
              );
              r.response.write('{}');
            case '/api/catalog':
              catalogCalls++;
              if (unavailable) {
                r.response.statusCode = 503;
              } else if (!logged) {
                r.response.statusCode = 401;
              } else {
                final ids = ['a', 'b', if (release == 'two') 'c'];
                r.response.write(
                  jsonEncode({
                    'releaseId': release,
                    'characters': [
                      for (final id in ids)
                        {
                          'id': id,
                          'name': id,
                          'formIds': [id],
                        },
                    ],
                    'entries': [
                      for (final id in ids) {'id': id, 'hasPrompt': true},
                    ],
                  }),
                );
                if (release == 'two' && !updated.isCompleted) {
                  updated.complete();
                }
              }
            case '/api/forms/a' || '/api/forms/b' || '/api/forms/c':
              if (!logged) {
                // One request returns its old 401 and deletion cookie only after
                // the parallel request has renewed and used the new login.
                if (r.uri.path.endsWith('/b')) {
                  if (!rejected.isCompleted) rejected.complete();
                  await slowReply.future;
                  r.response.cookies.add(
                    Cookie('visitor', '')
                      ..path = '/'
                      ..maxAge = 0,
                  );
                } else {
                  await rejected.future;
                }
                r.response.statusCode = 401;
              } else {
                r.response.write(
                  jsonEncode({
                    'id': r.uri.pathSegments.last,
                    'prompt': 'fixture prompt',
                  }),
                );
              }
            default:
              r.response.statusCode = 404;
          }
          await r.response.close();
        });
        final url = Uri.parse('http://127.0.0.1:${server.port}/');
        final original = await repo.connect(
          url,
          label: 'My group',
          password: 'fixture-pass',
        );
        expect(logins, 1);
        expect(secret['session_${original.id}'], contains('visitor-1'));
        expect(
          secret['session_${original.id}'],
          isNot(contains('memory-only')),
        );
        await repo.connect(url, label: original.label);
        expect(logins, 1);
        final snapshot = File('${repo.root.path}/${original.id}/source.json');
        expect(await snapshot.readAsString(), isNot(contains('visitor-1')));
        await expectLater(
          repo.connect(url, password: 'incorrect'),
          throwsA(isA<OcAccessError>()),
        );
        expect(secret[original.id], 'fixture-pass');
        expect(logins, 2);
        repo.close();
        repo = open(clock: clock);
        var current = await repo.connect(url, label: original.label);
        expect(
          logins,
          2,
          reason: 'a persisted, unexpired cookie survives a restart',
        );
        expected = 'server-reset';
        final first = repo.character(
          current,
          current.catalog.characters.first,
          withImages: false,
        );
        final second = repo.character(
          current,
          current.catalog.characters.last,
          withImages: false,
        );
        expect(
          (await first.timeout(const Duration(seconds: 6))).single.positive,
          'fixture prompt',
        );
        slowReply.complete();
        expect((await second).single.positive, 'fixture prompt');
        expect(logins, 3, reason: 'parallel expired replies share one login');
        final n = catalogCalls;
        await repo.refreshDue();
        expect(catalogCalls, n);
        release = 'two';
        // Enter the hour just before the upstream publication grace elapses.
        base = DateTime.utc(2026, 1, 1, 9, 0, 9, 600).subtract(watch.elapsed);
        final app = ProviderContainer(
          overrides: [ocRepositoryProvider.overrideWithValue(repo)],
        );
        addTearDown(app.dispose);
        await app.read(ocSourcesProvider.future);
        await updated.future.timeout(const Duration(seconds: 6));
        final seen = Completer<OcSource>();
        final subscription = app.listen(ocSourcesProvider, (_, next) {
          if (next.value?.singleOrNull case final src?
              when src.catalog.release == 'two') {
            if (!seen.isCompleted) seen.complete(src);
          }
        }, fireImmediately: true);
        current = await seen.future.timeout(const Duration(seconds: 6));
        subscription.close();
        expect(current.catalog.characters, hasLength(3));
        expect(current.label, 'My group');
        expect(catalogCalls, n + 1);
        expect(
          logins,
          3,
          reason: 'the catalog check keeps the authenticated session',
        );
        final snapshotBeforeError = await snapshot.readAsString();
        base = base.add(const Duration(hours: 1));
        unavailable = true;
        await repo.refreshDue();
        expect(await snapshot.readAsString(), snapshotBeforeError);
        expect(logins, 3);
        unavailable = false;
        deny = true;
        expected = 'server-reset-again';
        for (var i = 0; i < 2; i++) {
          await expectLater(repo.connect(url), throwsA(isA<OcAccessError>()));
        }
        expect(
          logins,
          4,
          reason: 'a rejected saved password does not cause a sign-in loop',
        );
        await repo.remove(current);
        expect(secret, isEmpty);
        await repo.refreshDue();
        expect(await repo.sources(), isEmpty);
      }, _Network());
    },
  );

  test(
    'refresh retains catalog order for undated imports and timestamps only newcomers',
    () async {
      final file = File('${dir.path}/dated.json');
      await file.writeAsString(
        jsonEncode({
          'entries': [
            {'name': 'A', 'prompt': 'alpha'},
            {
              'name': 'B',
              'prompt': 'beta',
              'updated_at': '2025-07-10T00:00:00Z',
            },
          ],
        }),
      );
      final initial = await repo.connect(file.uri);
      expect(initial.timeOf(initial.catalog.characters.first), 0);
      final bTime = initial.timeOf(initial.catalog.characters.last);
      expect(bTime, DateTime.utc(2025, 7, 10).millisecondsSinceEpoch);
      await file.writeAsString(
        jsonEncode({
          'entries': [
            {'name': 'A', 'prompt': 'alpha'},
            {'name': 'C', 'prompt': 'new'},
            {'name': 'B', 'prompt': 'beta', 'updated_at': bTime ~/ 1000},
          ],
        }),
      );
      final refresh = await repo.connect(file.uri);
      final saved = (await repo.sources()).single;
      expect(saved.catalog.characters.map(saved.timeOf), [
        0,
        refresh.added['/C'],
        bTime,
      ]);
      expect(saved.added['/C'], greaterThan(bTime));
    },
  );
  test('catalog parsing detects dangling form references', () {
    expect(
      () => OcCatalog.parse({
        'releaseId': 'r',
        'entries': [],
        'characters': [
          {
            'name': 'Test',
            'formIds': ['missing'],
          },
        ],
      }),
      throwsFormatException,
    );
  });
}
