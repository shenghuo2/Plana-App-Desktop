import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/net/backend_config.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/preset_rules.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/prompt_sections.dart';
import 'package:plana_app/features/generate/prompt_import_binding.dart';
import 'package:plana_app/features/generate/gen_modules.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';

class _Session extends BotSessionNotifier {
  @override
  Future<BotSession?> build() async =>
      const BotSession(sessionId: 'local-test');
}

class _Backend extends BackendBaseNotifier {
  _Backend(this.base);
  final String base;
  @override
  Future<String> build() async => base;
}

class _Library extends TagLibrary {
  @override
  Future<TagLibraryState> build() async => const TagLibraryState(
    entries: [
      TagEntry(
        id: 'cat',
        category: TagCategory.character,
        name: '礼服猫',
        positive: '1.4::blue hair, silver eyes::, {ribbon}, [boots]',
      ),
      TagEntry(
        id: 'a',
        name: 'A',
        category: TagCategory.artist,
        positive: 'artist:foo',
        negative: 'local negative',
      ),
      TagEntry(
        id: 'unused',
        name: 'Unused',
        category: TagCategory.artist,
        positive: 'artist:unused',
        negative: 'unused negative',
      ),
    ],
  );
  void change() => state = const AsyncData(
    TagLibraryState(
      entries: [
        TagEntry(
          id: 'a',
          name: 'A',
          category: TagCategory.artist,
          positive: 'artist:foo',
          negative: 'edited during request',
        ),
      ],
    ),
  );
}

class _Rules extends RulesLibraryNotifier {
  @override
  Future<RulesLibrary> build() async => const RulesLibrary();
}

class _LocalHttp extends HttpOverrides {}

class _SemanticRules extends RulesLibraryNotifier {
  @override
  Future<RulesLibrary> build() async => const RulesLibrary(
    active: {RulesFamily.nai45: 'test', RulesFamily.nai5: 'test'},
    apiSupplements: {RulesFamily.nai45: 'palette', RulesFamily.nai5: 'palette'},
    presets: [
      RulesPreset(
        id: 'palette',
        name: '色彩',
        author: '',
        models: {RulesFamily.nai45, RulesFamily.nai5},
        localOnly: true,
        rules: [PresetRule(name: 'palette', content: '画面偏暖色')],
      ),
      RulesPreset(
        id: 'test',
        name: '测试',
        author: '',
        models: {RulesFamily.nai45, RulesFamily.nai5},
        rules: [PresetRule(name: 'semantic_blocks', content: '按行标注分块')],
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final legacy in [false, true]) {
    test(
      'Bot backend honors OC placeholders and imports only library spans (legacy: $legacy)',
      () async {
        const oc = '1.4::blue hair, silver eyes::, {ribbon}, [boots]';
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final payloads = <String>[];
        server.listen((req) async {
          final channel = req.uri.path == '/api/agent/channel';
          if (legacy && channel) {
            req.response.statusCode = HttpStatus.notFound;
          } else {
            payloads.add(await utf8.decoder.bind(req).join());
            final drawing = {
              'positive': channel
                  ? 'garden'
                  : '<<artist:A:artist:foo>>, garden',
              'characters': [
                {'name': '主角', 'positive': 'standing, __OC_礼服猫__, waving'},
              ],
              'blocks': {
                'positive': ['场景·整张图'],
              },
              if (!channel)
                'resources': {
                  'artist': {'A': 'artist:foo'},
                },
            };
            final result = channel
                ? {'text': '```nai_draw\n${jsonEncode(drawing)}\n```'}
                : drawing;
            req.response.headers.contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
            );
            req.response.write('event: final\ndata: ${jsonEncode(result)}\n\n');
          }
          await req.response.close();
        });
        final stores = AppStores.ephemeral();
        final c = ProviderContainer(
          overrides: [
            appStoresProvider.overrideWithValue(stores),
            botSessionProvider.overrideWith(_Session.new),
            backendBaseProvider.overrideWith(
              () => _Backend('http://127.0.0.1:${server.port}'),
            ),
            assistantEndpointProvider.overrideWithValue(null),
            agentModelsProvider.overrideWith(
              (_) async => const AgentModelList(),
            ),
            rulesLibraryProvider.overrideWith(_Rules.new),
            tagLibraryProvider.overrideWith(_Library.new),
          ],
        );
        try {
          await c.read(backendBaseProvider.future);
          await c.read(assistantSettingsProvider.future);
          await c
              .read(assistantSettingsProvider.notifier)
              .patch(
                (s) => s.copyWith(
                  libraryScope: LibraryScope.local,
                  autoImport: true,
                  autoGenerate: false,
                  ocPlaceholders: true,
                  allowEditNegative: false,
                ),
              );
          final done = Completer<void>();
          final sub = c.listen(assistantProvider, (before, after) {
            if (before?.running == true &&
                !after.running &&
                !done.isCompleted) {
              done.complete();
            }
          });
          await HttpOverrides.runWithHttpOverrides(
            () => c.read(assistantProvider.notifier).send('用礼服猫'),
            _LocalHttp(),
          );
          await done.future.timeout(const Duration(seconds: 10));
          sub.close();
          expect(payloads.single, contains('__OC_礼服猫__'));
          expect(payloads.single, isNot(contains('silver eyes')));
          final draw = c.read(assistantProvider).msgs.last.draw!;
          expect(draw.blocks.map((b) => b.name), [if (legacy) 'A', '礼服猫']);
          final role = c.read(generateProvider).characters.single;
          expect(role.foldLinks.single.positiveBody, oc);
          expect(role.positive, 'standing, $oc, waving');
        } finally {
          c.dispose();
          await stores.flushForExit();
          await server.close(force: true);
        }
      },
    );
  }
  for (final mode in [SectionImport.aiSection, SectionImport.appendMain]) {
    test(
      'automatic and manual turns share the persisted destination and quoted labels in $mode',
      () async {
        final requests = <Map<String, dynamic>>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          if (request.uri.path == '/api/agent/channel') {
            request.response.statusCode = HttpStatus.notFound;
          } else {
            final body =
                jsonDecode(await utf8.decoder.bind(request).join())
                    as Map<String, dynamic>;
            requests.add(body);
            final first = requests.length == 1;
            final label = first ? '池边' : '窗光';
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
            );
            request.response.write(
              'event: final\ndata: ${jsonEncode({
                'positive': first ? 'artist:foo,\nmoonlight' : 'artist:foo,\nsunlight',
                'section': first ? '池边小景' : '教堂',
                'negative': 'model exclusion',
                'blocks': {
                  'positive': ['画风·画师·Brush', '场景·$label·Moon'],
                },
              })}\n\n',
            );
          }
          await request.response.close();
        });
        final stores = AppStores.ephemeral();
        final c = ProviderContainer(
          overrides: [
            appStoresProvider.overrideWithValue(stores),
            botSessionProvider.overrideWith(_Session.new),
            backendBaseProvider.overrideWith(
              () => _Backend('http://127.0.0.1:${server.port}'),
            ),
            assistantEndpointProvider.overrideWithValue(null),
            agentModelsProvider.overrideWith(
              (_) async => const AgentModelList(),
            ),
            rulesLibraryProvider.overrideWith(_SemanticRules.new),
            tagLibraryProvider.overrideWith(_Library.new),
          ],
        );
        try {
          await c.read(backendBaseProvider.future);
          await c.read(assistantSettingsProvider.future);
          final settings = c.read(assistantSettingsProvider.notifier);
          await settings.patch(
            (s) => s.copyWith(autoImport: true, importTo: mode),
          );
          final gen = c.read(generateProvider.notifier);
          gen.setPrompts(positive: 'handwritten', negative: 'fixed exclusion');
          final assistant = c.read(assistantProvider.notifier);
          Future<AssistantMsg> turn(String ask, {bool quote = false}) async {
            final done = Completer<void>();
            final sub = c.listen(assistantProvider, (old, next) {
              if (old?.running == true && !next.running && !done.isCompleted) {
                done.complete();
              }
            });
            try {
              await HttpOverrides.runWithHttpOverrides(
                () => assistant.send(ask, withCanvas: quote),
                _LocalHttp(),
              );
              await done.future.timeout(const Duration(seconds: 10));
              final msg = c.read(assistantProvider).msgs.last;
              expect(msg.role, MsgRole.ai, reason: msg.text);
              return msg;
            } finally {
              sub.close();
            }
          }

          final first = await turn('画一张');
          expect(first.change, isNotNull);
          expect(
            first.draw!.negative,
            'model exclusion',
            reason: 'locked imports skip the artist supplement',
          );
          expect(requests.first['user_request'], contains('全局负面提示词已锁定'));
          expect(requests.first['user_request'], endsWith('画面偏暖色'));
          expect(
            requests.first['preset_rules'].toString(),
            isNot(contains('画面偏暖色')),
          );
          final original = c.read(generateProvider);
          expect(composeSections(original).negativePrompt, 'fixed exclusion');
          if (mode == SectionImport.aiSection) {
            gen.updateSection(original.sections.last.id, name: '手改分区名');
          }
          await settings.patch((s) => s.copyWith(autoImport: false));
          final next = await turn('把第二块改名窗光', quote: true);
          expect(next.change, isNull);
          expect(requests.last['user_request'], contains('池边'));
          if (mode == SectionImport.aiSection) {
            expect(requests.last['user_request'], contains('手改分区名'));
          }
          final preview = assistant.previewSendState(next.id)!;
          expect(assistant.applyProposal(next.id), true);
          final actual = c.read(generateProvider);
          expect(preview.prompt, composeSections(actual).prompt);
          expect(preview.negativePrompt, 'fixed exclusion');
          expect(actual.sections.length, original.sections.length);
          final links = mode == SectionImport.aiSection
              ? actual.sections.last.foldLinks
              : actual.promptFoldLinks;
          expect(
            links.map((l) => l.positiveName).join(),
            allOf(contains('窗光'), isNot(contains('池边'))),
          );
          expect(actual.negativePrompt, 'fixed exclusion');
          expect(assistant.undo(next.id), true);
        } finally {
          c.dispose();
          await stores.flushForExit();
          await server.close(force: true);
        }
      },
    );
  }
  for (final mode in SectionImport.values) {
    test(
      'inactive canvas ${mode.name} import matches preview and fully undoes',
      () async {
        final stores = AppStores.ephemeral();
        stores.assistant.initialCurrent = const [
          AssistantMsg(
            id: 'r',
            role: MsgRole.ai,
            text: '',
            at: 1,
            draw: DrawProposal(
              positive: 'new scene, watercolor',
              negative: 'lowres, blurry',
            ),
          ),
        ];
        final c = ProviderContainer(
          overrides: [appStoresProvider.overrideWithValue(stores)],
        );
        try {
          await c.read(assistantSettingsProvider.future);
          await c
              .read(assistantSettingsProvider.notifier)
              .patch((s) => s.copyWith(importTo: mode));
          c.invalidate(assistantSettingsProvider);
          expect(
            (await c.read(assistantSettingsProvider.future)).importTo,
            mode,
          );
          final gen = c.read(generateProvider.notifier);
          final original = GenerateState.initial().copyWith(
            prompt: 'forest',
            promptRaw: '<#scene: forest#>',
            negativePrompt: 'lowres',
            sections: const [
              PromptSection.main(),
              PromptSection(
                id: 's',
                name: '风格',
                positive: 'watercolor',
                negative: 'blurry',
                positiveRaw: '<#style: watercolor#>',
                negativeRaw: '<#negative: blurry#>',
              ),
            ],
          );
          gen.applyCanvas(CanvasPrompts.of(original), force: true);
          final canvases = c.read(canvasWorkspaceProvider.notifier);
          final source = c.read(canvasWorkspaceProvider).activeId;
          final other = canvases.create();
          gen.setPrompts(positive: 'leave me alone');
          final assistant = c.read(assistantProvider.notifier);
          final preview = assistant.previewSendState('r', canvasId: source)!;
          expect(assistant.applyProposal('r', canvasId: source), isTrue);
          expect(c.read(canvasWorkspaceProvider).activeId, other);
          expect(c.read(generateProvider).prompt, 'leave me alone');
          final changed = c
              .read(canvasWorkspaceProvider)
              .find(source)!
              .prompts
              .applyTo(original);
          final sent = stripHiddenModules(changed, const GenModuleSettings());
          expect(sent.prompt, preview.prompt);
          expect(sent.negativePrompt, preview.negativePrompt);
          expect(changed.sections.length, switch (mode) {
            SectionImport.main || SectionImport.appendMain => 2,
            SectionImport.newSection || SectionImport.aiSection => 3,
            SectionImport.clear => 2, // Locked exclusions retain their rows.
          });
          if (mode != SectionImport.clear) {
            expect(
              changed.sections[1].positiveRaw,
              original.sections[1].positiveRaw,
            );
          }
          expect(assistant.undo('r'), isTrue);
          canvases.select(source);
          expect(
            PromptSnapshot.of(
              c.read(generateProvider),
            ).sameAs(PromptSnapshot.of(original)),
            isTrue,
          );
        } finally {
          c.dispose();
          await stores.flushForExit();
        }
      },
    );
  }

  test(
    'new import preferences use the dedicated section and retain saved choices',
    () {
      expect(
        AssistantSettings.fromJson({'importTo': 'main'}).importTo,
        SectionImport.main,
      );
      expect(AssistantSettings.fromJson({}).allowEditNegative, false);
      expect(AssistantSettings.fromJson({}).importTo, SectionImport.aiSection);
      expect(
        AssistantSettings.fromJson({'importTo': 'future-choice'}).importTo,
        SectionImport.aiSection,
      );
    },
  );
  test(
    'import dedup never removes members of disabled, folded or weighted groups',
    () {
      const sections = [PromptSection(id: 's', name: 's', positive: 'middle')];
      for (final group in [
        '~first, middle, last~',
        '<#fold: first, middle, last#>',
        '1.2::first, middle, last::',
        '{first, middle, last}',
        '[first, middle, last]',
      ]) {
        expect(
          dropSectionWords('$group, middle', sections, '', positive: true),
          group,
        );
        expect(
          dropSectionWords(
            'middle',
            [PromptSection(id: 's', name: 's', positive: group)],
            '',
            positive: true,
          ),
          'middle',
        );
      }
    },
  );
  test(
    'artist negatives ignore name prefixes and disabled strings but accept weights',
    () {
      const artist = TagEntry(
        id: 'a',
        name: 'a',
        category: TagCategory.artist,
        positive: 'artist:foo',
        negative: 'blurry',
      );
      for (final text in [
        'artist:foobar',
        'artist:foo (alternate)',
        '~artist:foo~',
      ]) {
        expect(
          withArtistNegatives(DrawProposal(positive: text), [artist]),
          isEmpty,
        );
      }
      expect(
        withArtistNegatives(
          const DrawProposal(positive: '1.3::artist:foo::, forest'),
          [artist],
        ),
        'blurry',
      );
    },
  );

  test(
    'first use seeds intact weighted defaults and revisions keep deletions',
    () {
      const style = TagEntry(
        id: 'style',
        name: 'Style',
        category: TagCategory.artist,
        positive: 'artist:sample',
        negative: '2::little dolls, extra fingers, chibi::, 5::mouse ears::',
      );
      final initial = proposalWithArtistNegatives(
        const DrawProposal(positive: 'artist:sample', negative: 'chibi'),
        [style],
      );
      expect(
        initial.negative,
        'chibi, 2::little dolls, extra fingers::, 5::mouse ears::',
      );
      final revision = proposalWithArtistNegatives(
        const DrawProposal(
          positive: 'artist:sample',
          negative: '2::little dolls, extra fingers::, cat tail',
        ),
        [style],
        previousPositives: [initial.positive],
      );
      expect(revision.negative, '2::little dolls, extra fingers::, cat tail');
      const newStyle = TagEntry(
        id: 'other',
        name: 'Other',
        category: TagCategory.artist,
        positive: 'artist:other',
        negative: 'watermark',
      );
      expect(
        proposalWithArtistNegatives(
          const DrawProposal(positive: 'artist:sample, artist:other'),
          [style, newStyle],
          previousPositives: [revision.positive],
        ).negative,
        'watermark',
      );
    },
  );

  test(
    'explicit empty revision removes only the owned negative and survives reopening',
    () {
      const prior = DrawProposal(positive: 'portrait', negative: 'cat tail');
      final empty = DrawProposal.fromJson(
        const DrawProposal(positive: 'portrait', clearNegative: true).toJson(),
      );
      for (final mode in [SectionImport.aiSection, SectionImport.appendMain]) {
        var i = 0;
        String nextId() => 'test${i++}';
        var binding = const PromptImportBinding();
        final c = GenerateState.initial().copyWith(
          negativePrompt: 'handwritten',
        );
        final first = proposalSendState(
          c,
          prior,
          mode,
          newId: nextId,
          allowEditNegative: true,
          onBinding: (value) => binding = value,
        );
        final keep = proposalSendState(
          first,
          const DrawProposal(positive: 'portrait'),
          mode,
          binding: binding,
          newId: nextId,
          allowEditNegative: true,
        );
        expect(composeSections(keep).negativePrompt, contains('cat tail'));
        final locked = proposalSendState(
          first,
          empty,
          mode,
          binding: binding,
          newId: nextId,
        );
        expect(composeSections(locked).negativePrompt, contains('cat tail'));
        final cleared = proposalSendState(
          first,
          empty,
          mode,
          binding: binding,
          newId: nextId,
          allowEditNegative: true,
        );
        expect(composeSections(cleared).negativePrompt, 'handwritten');
      }
    },
  );

  test(
    'assistant can edit and then clear the same artist across actual turns',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final replies = [
        {'positive': 'artist:foo'},
        {
          'positive': 'artist:foo',
          'negative': '2::local negative::, new exclusion',
        },
        {'positive': 'artist:foo, portrait'},
        {'positive': 'artist:foo', 'negative': 'cat tail'},
        {'positive': 'artist:foo', 'negative': ''},
      ].iterator;
      server.listen((request) async {
        if (request.uri.path == '/api/agent/channel') {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          await request.drain<void>();
          if (!replies.moveNext()) {
            throw StateError('unexpected assistant request');
          }
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'event: final\ndata: ${jsonEncode(replies.current)}\n\n',
          );
        }
        await request.response.close();
      });
      final stores = AppStores.ephemeral();
      final c = ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          botSessionProvider.overrideWith(_Session.new),
          backendBaseProvider.overrideWith(
            () => _Backend('http://127.0.0.1:${server.port}'),
          ),
          assistantEndpointProvider.overrideWithValue(null),
          agentModelsProvider.overrideWith((_) async => const AgentModelList()),
          rulesLibraryProvider.overrideWith(_Rules.new),
          tagLibraryProvider.overrideWith(_Library.new),
        ],
      );
      try {
        await c.read(backendBaseProvider.future);
        await c.read(assistantSettingsProvider.future);
        await c
            .read(assistantSettingsProvider.notifier)
            .patch(
              (s) => s.copyWith(
                libraryScope: LibraryScope.local,
                importTo: SectionImport.aiSection,
                allowEditNegative: true,
                autoImport: false,
                stream: false,
              ),
            );
        for (final (question, expected) in [
          ('use A', 'local negative'),
          (
            'change the weight and add an exclusion',
            '2::local negative::, new exclusion',
          ),
          ('only edit the positive', '2::local negative::, new exclusion'),
          ('replace its exclusion', 'cat tail'),
          ('remove the last exclusion', ''),
        ]) {
          final done = Completer<void>();
          final sub = c.listen(assistantProvider, (before, after) {
            if (before?.running == true &&
                !after.running &&
                !done.isCompleted) {
              done.complete();
            }
          });
          try {
            await HttpOverrides.runWithHttpOverrides(
              () => c.read(assistantProvider.notifier).send(question),
              _LocalHttp(),
            );
            await done.future.timeout(const Duration(seconds: 10));
            final reply = c.read(assistantProvider).msgs.last;
            expect(reply.draw?.negative, expected, reason: reply.text);
            expect(reply.draw!.clearNegative, expected.isEmpty);
            if (expected.startsWith('2::')) {
              final draw = reply.draw!;
              final owner = draw.blocks.singleWhere((b) => !b.negative);
              expect(
                owner.counterpartIn(draw.blocks)?.text,
                '2::local negative::',
              );
            }
          } finally {
            sub.close();
          }
        }
      } finally {
        c.dispose();
        await stores.assistant.idle;
        await server.close(force: true);
      }
    },
  );

  for (final (scope, publicFailure) in [
    for (final s in LibraryScope.values) (s, false),
    (LibraryScope.all, true),
  ]) {
    test(
      'artist negative scope ${scope.name} (public failure: $publicFailure) uses the request library and retains source sections',
      () async {
        final received = Completer<void>(), release = Completer<void>();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final stores = AppStores.ephemeral();
        var publicLoads = 0;
        Map<String, dynamic>? body;
        server.listen((request) async {
          if (request.uri.path == '/api/agent/channel') {
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
            return;
          }
          body =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>;
          received.complete();
          await release.future;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'event: final\ndata: {"positive":"<<artist:A:artist:foo>>, artist:public"}\n\n',
          );
          await request.response.close();
        });
        final c = ProviderContainer(
          overrides: [
            appStoresProvider.overrideWithValue(stores),
            botSessionProvider.overrideWith(_Session.new),
            backendBaseProvider.overrideWith(
              () => _Backend('http://127.0.0.1:${server.port}'),
            ),
            assistantEndpointProvider.overrideWithValue(null),
            agentModelsProvider.overrideWith(
              (_) async => const AgentModelList(),
            ),
            rulesLibraryProvider.overrideWith(_Rules.new),
            tagLibraryProvider.overrideWith(_Library.new),
            publicTagsProvider.overrideWith((ref, category) async {
              publicLoads++;
              await Future<void>.delayed(const Duration(milliseconds: 20));
              if (publicFailure) throw StateError('Public library unavailable');
              return const [
                TagEntry(
                  id: 'p',
                  name: 'p',
                  category: TagCategory.artist,
                  positive: 'artist:public',
                  negative: 'public negative',
                ),
              ];
            }),
          ],
        );
        final done = Completer<void>();
        final listener = c.listen(assistantProvider, (previous, next) {
          if (previous?.running == true && !next.running && !done.isCompleted) {
            done.complete();
          }
        });
        try {
          await c.read(backendBaseProvider.future);
          await c.read(assistantSettingsProvider.future);
          await c
              .read(assistantSettingsProvider.notifier)
              .patch(
                (s) => s.copyWith(
                  libraryScope: scope,
                  importTo: SectionImport.main,
                  allowEditNegative: true,
                  autoImport: true,
                  stream: false,
                ),
              );
          final gen = c.read(generateProvider.notifier);
          gen.applyCanvas(
            CanvasPrompts.of(
              GenerateState.initial().copyWith(
                sections: const [
                  PromptSection.main(),
                  PromptSection(
                    id: 'style',
                    name: 'style',
                    positive: 'watercolor',
                  ),
                ],
              ),
            ),
            force: true,
          );
          final source = c.read(canvasWorkspaceProvider).activeId;
          final assistant = c.read(assistantProvider.notifier);
          await HttpOverrides.runWithHttpOverrides(
            () => assistant.send('draw', withCanvas: true),
            _LocalHttp(),
          );
          await received.future.timeout(const Duration(seconds: 10));
          if (scope != LibraryScope.none) {
            (c.read(tagLibraryProvider.notifier) as _Library).change();
          }
          await c
              .read(assistantSettingsProvider.notifier)
              .patch((s) => s.copyWith(libraryScope: LibraryScope.none));
          final other = c.read(canvasWorkspaceProvider.notifier).create();
          gen.setPrompts(positive: 'other canvas');
          release.complete();
          await done.future.timeout(const Duration(seconds: 10));
          final reply = c.read(assistantProvider).msgs.last;
          expect(reply.role, MsgRole.ai, reason: reply.text);
          expect(reply.draw!.negative, switch (scope) {
            LibraryScope.none => '',
            LibraryScope.local => 'local negative',
            LibraryScope.all =>
              publicFailure
                  ? 'local negative'
                  : 'local negative, public negative',
          });
          expect(publicLoads, scope == LibraryScope.all ? 2 : 0);
          expect(body!['current_positive'], 'watercolor');
          expect(reply.change!.canvasId, source);
          expect(c.read(canvasWorkspaceProvider).activeId, other);
          expect(c.read(generateProvider).prompt, 'other canvas');
          expect(
            c
                .read(canvasWorkspaceProvider)
                .find(source)!
                .prompts
                .sections
                .last
                .positive,
            'watercolor',
          );
        } finally {
          if (!release.isCompleted) release.complete();
          listener.close();
          c.dispose();
          await stores.flushForExit();
          await server.close(force: true);
        }
      },
    );
  }
  test(
    'default assistant import keeps sections and undo targets the original canvas',
    () async {
      final stores = AppStores.ephemeral();
      stores.assistant.initialCurrent = const [
        AssistantMsg(
          id: 'reply',
          role: MsgRole.ai,
          text: 'reply',
          at: 1,
          draw: DrawProposal(
            positive: 'new scene, watercolor',
            negative: 'lowres, blurry',
          ),
        ),
      ];
      final c = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      try {
        final gen = c.read(generateProvider.notifier);
        gen.applyCanvas(
          CanvasPrompts.of(
            GenerateState.initial().copyWith(
              prompt: 'old scene',
              negativePrompt: 'lowres',
              sections: const [
                PromptSection.main(),
                PromptSection(
                  id: 'style',
                  name: '画风',
                  positive: 'watercolor',
                  negative: 'blurry',
                  positiveRaw: '<#style: watercolor#>',
                  artist: true,
                ),
              ],
            ),
          ),
          force: true,
        );
        final source = c.read(canvasWorkspaceProvider).activeId;
        final before = PromptSnapshot.of(c.read(generateProvider));
        final assistant = c.read(assistantProvider.notifier);
        expect(assistant.applyProposal('reply'), isTrue);
        final after = c.read(generateProvider);
        expect(after.prompt, 'old scene');
        expect(after.sections.last.positive, 'new scene');
        expect(after.sections[1].positiveRaw, '<#style: watercolor#>');
        expect(composeSections(after).negativePrompt, 'lowres, blurry');
        final other = c.read(canvasWorkspaceProvider.notifier).create();
        gen.setPrompts(positive: 'keep this canvas');
        expect(assistant.undo('reply'), isTrue);
        expect(c.read(canvasWorkspaceProvider).activeId, other);
        expect(c.read(generateProvider).prompt, 'keep this canvas');
        c.read(canvasWorkspaceProvider.notifier).select(source);
        expect(
          PromptSnapshot.of(c.read(generateProvider)).sameAs(before),
          isTrue,
        );
      } finally {
        c.dispose();
        await stores.flushForExit();
      }
    },
  );

  test(
    'stopping during public library loading never starts the AI request',
    () async {
      final loading = Completer<void>();
      final public = Completer<List<TagEntry>>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((r) async {
        requests++;
        r.response.statusCode = 500;
        await r.response.close();
      });
      final stores = AppStores.ephemeral();
      final c = ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          botSessionProvider.overrideWith(_Session.new),
          backendBaseProvider.overrideWith(
            () => _Backend('http://127.0.0.1:${server.port}'),
          ),
          assistantEndpointProvider.overrideWithValue(null),
          agentModelsProvider.overrideWith((_) async => const AgentModelList()),
          rulesLibraryProvider.overrideWith(_Rules.new),
          tagLibraryProvider.overrideWith(_Library.new),
          publicTagsProvider.overrideWith((ref, category) {
            loading.complete();
            return public.future;
          }),
        ],
      );
      try {
        await c.read(backendBaseProvider.future);
        await c.read(assistantSettingsProvider.future);
        await c
            .read(assistantSettingsProvider.notifier)
            .patch((s) => s.copyWith(libraryScope: LibraryScope.all));
        final assistant = c.read(assistantProvider.notifier);
        final send = HttpOverrides.runWithHttpOverrides(
          () => assistant.send('draw', withCanvas: false),
          _LocalHttp(),
        );
        await loading.future.timeout(const Duration(seconds: 10));
        assistant.stop();
        public.complete(const []);
        await send;
        expect(requests, 0);
        expect(c.read(assistantProvider).running, isFalse);
        expect(
          c.read(assistantProvider).msgs.where((m) => m.draw != null),
          isEmpty,
        );
      } finally {
        if (!public.isCompleted) public.complete(const []);
        c.dispose();
        await stores.flushForExit();
        await server.close(force: true);
      }
    },
  );
}
