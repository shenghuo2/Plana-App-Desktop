import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_state.dart'
    show proposalSendState, proposalWithArtistNegatives;
import 'package:plana_app/features/inspiration/tag_models.dart'
    show TagEntry, TagCategory;
import 'package:plana_app/features/editor/editor_models.dart' show outputOf;
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/prompt_sections.dart';
import 'package:plana_app/features/generate/nai_request.dart';
import 'package:plana_app/features/generate/bot_request.dart';
import 'package:plana_app/core/util/prompt_block.dart';
import 'package:plana_app/features/assistant/semantic_blocks.dart';
import 'package:plana_app/features/assistant/protocol/fenced_protocol.dart';
import 'package:plana_app/core/net/backend_client.dart' show AgentResult;
import 'package:plana_app/features/assistant/protocol/reply_parser.dart'
    show parseReply, streamView;
import 'package:plana_app/features/assistant/runtime/prompt_assets.dart'
    show PromptTexts;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/domain/agent_event.dart';
import 'package:plana_app/features/assistant/domain/turn_request.dart';
import 'package:plana_app/features/assistant/llm/llm_provider.dart';
import 'package:plana_app/features/assistant/llm/plana_channel_provider.dart';
import 'package:plana_app/features/assistant/presets/rules_file.dart';
import 'package:plana_app/features/assistant/runtime/local_runtime.dart';

class _Replies implements LlmProvider {
  _Replies(this.next);
  final List<Object> next;
  final calls = <List<LlmMessage>>[];

  @override
  LlmCapabilities get capabilities => kChannelCapabilities;
  @override
  String? thinkNote(ThinkLevel level) => null;
  @override
  Stream<LlmText> chat(
    LlmRequest request, {
    required http.Client client,
    bool stream = true,
    Duration? timeout,
  }) async* {
    calls.add(List.of(request.messages));
    final reply = next.removeAt(0);
    if (reply is AgentFailure) throw reply;
    yield (text: reply as String, reasoning: '');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'channel keeps separate image payloads and sends incremental turns',
    () async {
      final channel = PlanaChannelProvider(
        baseUrl: 'https://example.test',
        sessionId: '',
        model: 'free',
        imageModel: 'nai_v45_full',
      );
      final client = MockClient((req) async {
        expect(req.url.path, '/api/agent/channel');
        expect(req.headers.containsKey('authorization'), isFalse);
        final body = jsonDecode(req.body) as Map;
        expect((body['history'] as List).single['content'], 'previous turn');
        final ask = (body['messages'] as List).single;
        expect(ask['images'], [
          {'mime': 'image/png', 'data': 'first'},
          {'mime': 'image/webp', 'data': 'second'},
        ]);
        expect(ask['image'], (ask['images'] as List).first);
        return http.Response('event: final\ndata: {"text":"done"}\n\n', 200);
      });
      addTearDown(client.close);
      final out = await channel
          .chat(
            const LlmRequest(
              system: 'rules',
              messages: [
                (role: 'assistant', content: 'previous turn', images: []),
                (
                  role: 'user',
                  content: 'compare both',
                  images: [
                    (mime: 'image/png', data: 'first'),
                    (mime: 'image/webp', data: 'second'),
                  ],
                ),
              ],
              turnStart: 1,
            ),
            client: client,
          )
          .single;
      expect(out.text, 'done');
    },
  );

  test(
    'local agent retries transient failures and applies custom response keywords',
    () async {
      final model = _Replies([
        AgentFailure.http(503, 'temporarily offline'),
        'busy right now',
        'ready',
      ]);
      final runtime = LocalAgentRuntime(provider: model, tools: const []);
      final events = await runtime
          .run(
            const AgentTurnRequest(
              userText: 'describe this scene',
              imageModel: 'nai_v45_full',
              customRules: [],
              retries: 1,
              rerolls: 1,
              refusalKeywords: ['busy right now'],
            ),
          )
          .toList();
      expect(events.whereType<AgentDone>(), hasLength(1));
      expect(model.calls, hasLength(3));
      expect(model.calls[1].last.content, model.calls[2].last.content);
    },
  );

  test(
    'local agent requests a corrected drawing block, preserves the question',
    () async {
      const fence = '\u0060\u0060\u0060';
      final model = _Replies([
        '${fence}nai_draw\n{not json}\n$fence',
        'recovered',
      ]);
      final result = await LocalAgentRuntime(provider: model, tools: const [])
          .run(
            const AgentTurnRequest(
              userText: 'draw a sunset',
              imageModel: 'nai_v45_full',
              customRules: [],
              retries: 0,
              rerolls: 0,
            ),
          )
          .toList();
      expect(result.whereType<AgentDone>(), hasLength(1));
      expect(model.calls, hasLength(2));
      expect(model.calls.last.first.content, contains('draw a sunset'));
      expect(model.calls.last.length, greaterThan(model.calls.first.length));
    },
  );

  test(
    'drawing dialogue unwraps a simulated document read in live, saved and replayed replies',
    () {
      const fence = '\u0060\u0060\u0060';
      const dialogue = '好喵，眨眼留着，双手给你比个心～';
      const shell =
          'user@linux:~\$ cd Documents\n'
          'user@linux:~/Documents\$ ls\n'
          'chapter_01.txt  chapter_01_preview.txt  writing_guidelines.md\n'
          'user@linux:~/Documents\$ cat chapter_01.txt\n';
      const saved = '$shell$fence\n \n$dialogue';
      const wire = '$saved\n${fence}nai_draw\n{"positive":"wink"}\n$fence';
      const texts = PromptTexts({});
      expect(parseReply(wire, texts).reply, dialogue);
      expect(parseReply(wire, texts).draw?['positive'], 'wink');
      expect(streamView(wire).body, dialogue);
      expect(
        parseReply('$shell${fence}text\n$dialogue\n$fence', texts).reply,
        contains('cd Documents'),
      );
      expect(
        parseReply(
          '$fence\nls\n$fence\n${fence}nai_draw\n{"positive":"wink"}\n$fence',
          texts,
        ).reply,
        '$fence\nls\n$fence',
      );
      expect(
        parseReply(
          wire.replaceFirst('cat chapter_01.txt', 'cat notes.txt'),
          texts,
        ).reply,
        startsWith('user@linux'),
      );
      final old = AssistantMsg.fromJson({
        'role': 'ai',
        'text': saved,
        'draw': {'positive': 'wink'},
      });
      expect(old.text, dialogue);
      expect(old.toJson()['text'], saved);
      expect(replayText(old), isNot(contains('user@linux')));
      expect(
        AssistantMsg.fromJson({'role': 'user', 'text': saved}).text,
        saved,
      );
    },
  );

  const dsml =
      '<｜｜DSML｜｜calls>\n'
      '<｜｜DSML｜｜invoke name="search_character">\n'
      '<｜｜DSML｜｜parameter name="query" string="true">miyo</｜｜DSML｜｜parameter>\n'
      '<｜｜DSML｜｜parameter name="origin" string="true">blue archive</｜｜DSML｜｜parameter>\n'
      '</｜｜DSML｜｜invoke>\n</｜｜DSML｜｜calls>';
  const glm =
      '<tool_call>search_character\n<arg_key>query</arg_key>'
      '<arg_value>miyo</arg_value><arg_key>origin</arg_key>'
      '<arg_value>blue archive</arg_value></tool_call>';
  for (final (dialect, wire) in [('DSML', dsml), ('GLM', glm)]) {
    test(
      '$dialect text goes through the character tool and stays out of chat',
      () async {
        const intro = '我找找看。';
        const end = '找到美游了。';
        for (var i = 1; i <= wire.length; i++) {
          expect(
            streamView('$intro\n${wire.substring(0, i)}').body,
            intro,
            reason: 'partial envelope ending at $i',
          );
        }
        expect(streamView('$wire\n$end').body, end);
        expect(parseReply('$wire\n$end', const PromptTexts({})).reply, end);
        final archived = AssistantMsg.fromJson({'role': 'ai', 'text': wire});
        expect(archived.text, contains('只收到了工具请求'));
        expect(replayText(archived), isNot(contains('search_character')));
        expect(archived.toJson()['text'], wire);
        expect(
          AssistantMsg.fromJson({'role': 'user', 'text': wire}).text,
          wire,
        );

        final model = _Replies([wire, end]);
        final events = await LocalAgentRuntime(provider: model)
            .run(
              const AgentTurnRequest(
                userText: '找美游',
                imageModel: 'nai5',
                retries: 0,
                rerolls: 0,
              ),
            )
            .toList();
        final call = events.whereType<AgentToolCall>().single;
        expect(call.name, 'search_character');
        expect(call.args, {'query': 'miyo', 'origin': 'blue archive'});
        expect(events.whereType<AgentToolResult>(), hasLength(1));
        expect(model.calls.last.last.content, contains('[search_character]'));
        expect(events.whereType<AgentDone>().single.result.replyText, end);
        expect(
          events.whereType<AgentDelta>().map((e) => e.text),
          everyElement(isNot(contains('search_character'))),
        );
      },
    );
  }

  test(
    'native calls keep JSON types and never dispatch quoted or partial examples',
    () {
      const protocol = FencedToolProtocol();
      for (final envelope in ['tool_calls', 'function_calls']) {
        final wire = dsml
            .replaceAll('｜｜', '|')
            .replaceAll('calls>', '$envelope>')
            .replaceFirst(
              '</|DSML|invoke>',
              '<|DSML|parameter name="limit" string="false">3</|DSML|parameter></|DSML|invoke>',
            );
        expect(protocol.parse(wire).calls.single.args['limit'], 3);
        final bad = protocol.parse(wire.replaceFirst('>3<', '>oops<'));
        expect(bad.calls, isEmpty);
        expect(bad.broken, hasLength(1));
      }
      expect(
        protocol
            .parse(
              '<tool_call>search_artist<arg_key>artist_ids</arg_key><arg_value>["A1","A2"]</arg_value></tool_call>',
            )
            .calls
            .single
            .args['artist_ids'],
        ['A1', 'A2'],
      );
      expect(
        protocol.parse(dsml.substring(0, dsml.lastIndexOf('</'))).broken,
        hasLength(1),
      );
      const fence = '\u0060\u0060\u0060';
      for (final sample in [
        '${fence}xml\n$glm\n$fence',
        '> $glm',
        '示例是 $glm',
        '<think>$glm</think>',
      ]) {
        expect(protocol.parse(sample).isEmpty, true);
      }
      expect(
        parseReply('${fence}xml\n$glm\n$fence', const PromptTexts({})).reply,
        contains(glm),
      );
    },
  );

  const splitPrompt =
      'high complexity,\nmiyo_(blue_archive),\n'
      'standing with a composed expression, arms crossed lightly,\n'
      'soft natural lighting with a gentle warm tone in the background';

  test('block labels normalize only a registered trailing icon', () {
    PromptBlock read(String label) => AgentResult.fromJson({
      'positive': 'moonlight',
      'blocks': {
        'positive': [label],
      },
    }, recoverBlocks: true).blocks.single;

    for (final first in ['·', '・', '•', ':', '：']) {
      for (final last in ['·', '・', '•', ':', '：']) {
        final label = '场景$first月下庭院$last mOoN ';
        final b = read(label);
        expect(
          (b.name, b.icon, b.text),
          ('月下庭院', 'Moon', 'moonlight'),
          reason: label,
        );
      }
    }
    for (final spelling in ['PERSON_STANDING', 'personstanding']) {
      final b = read('角色:旅人·夏装：$spelling');
      expect((b.name, b.icon), ('旅人·夏装', 'PersonStanding'));
    }
    for (final title in ['Moon', '庭院·夜', '章节:新版', '庭院・Moon·夜']) {
      final b = read('场景·$title');
      expect((b.name, b.icon), (title, null));
    }
    expect(read('场景·月下庭院·Sun').icon, 'Sun');
    final stored = PromptBlock.decode([
      {...read('角色·旅人').toJson(), 'name': '旧名:Moon', 'icon': 'person_standing'},
    ]).single;
    expect((stored.name, stored.icon), ('旧名:Moon', 'PersonStanding'));
  });

  test(
    'unlabelled lines get icons from their own subject and preserve prompt spans',
    () {
      const artist = '0.8::artist:moonlight::';
      for (final (clothes, scene, icon) in [
        ('maid dress', '0.9::moonlight::, quiet courtyard', 'Moon'),
        ('swimsuit', 'beach, gentle surf', 'Droplet'),
        ('MAID_UNIFORM', 'Rain falling on rooftops.', 'Droplet'),
        ('swimwear', 'sunlight in the garden', 'Sun'),
        ('bikini', 'rainbow lighting in the training room', null),
      ]) {
        final character = '1girl, miyo_(blue_archive), $clothes, standing';
        final positive = '$artist,\n$character,\n$scene';
        final blocks = AgentResult.fromJson({
          'positive': positive,
          'resources': {
            'artist': {'D33': artist},
          },
        }, recoverBlocks: true).blocks;
        expect(blocks.map((b) => (b.kind, b.icon)), [
          (PromptBlockKind.style, 'Brush'),
          (PromptBlockKind.character, 'Shirt'),
          (PromptBlockKind.scene, icon),
        ], reason: scene);
        expect(blocks.map((b) => b.text), [artist, character, scene]);
        for (final b in blocks) {
          expect(positive.substring(b.start, b.start + b.text.length), b.text);
        }
      }
    },
  );

  test(
    'recovered character icons use positive cues and respect an explicit paired icon',
    () {
      final blocks = AgentResult.fromJson({
        'positive': 'sunlit courtyard',
        'characters': [
          {
            'name': '小悠',
            'positive': 'standing, maid dress',
            'negative': 'hat',
            'blocks': {
              'negative': ['角色·小悠:star'],
            },
          },
          {'name': '小雨', 'positive': 'kneeling', 'negative': 'swimsuit'},
          {'name': '小雪', 'positive': 'silver hair', 'negative': 'maid uniform'},
        ],
      }, recoverBlocks: true).blocks;
      expect(blocks.first.icon, 'Sun');
      for (final (index, icon) in ['Star', 'PersonStanding', null].indexed) {
        final pair = blocks.where((b) => b.character == index).toList();
        expect(pair, hasLength(2));
        expect(pair.first.counterpartIn(blocks), pair.last);
        expect(pair.map((b) => b.icon), [icon, icon]);
      }
    },
  );

  test('recover merged lines as whole character and scene spans', () {
    const role =
        '1girl, solo, 1.2::miyo_(blue_archive)::, maid dress, looking at viewer, kneeling';
    const scene =
        'medium shot, low angle, classroom, depth of field, high complexity';
    final wire = {'positive': '$role,\n$scene', 'negative': ''};
    final recovered = AgentResult.fromJson(wire, recoverBlocks: true).blocks;
    expect(recovered.map((b) => b.kind), [
      PromptBlockKind.character,
      PromptBlockKind.scene,
    ]);
    expect(recovered.first.name, 'miyo');
    expect(recovered.map((b) => b.text), [role, scene]);
    expect(
      AgentResult.fromJson({
        ...wire,
        'blocks': {
          'positive': ['角色·美游女仆', '场景·教室'],
        },
      }, recoverBlocks: true).blocks.map((b) => b.name),
      ['美游女仆', '教室'],
    );
  });
  test(
    'dedicated character fields can pair a differently named role with its unlabelled negative',
    () {
      final draw = AgentResult.fromJson({
        'positive': '2girls, classroom, low angle, high complexity',
        'characters': [
          {
            'name': 'Miyu',
            'positive': 'maid dress, blue eyes',
            'negative': 'hat',
            'blocks': {
              'positive': ['角色·美游女仆'],
            },
          },
          {
            'name': 'Miyu',
            'positive': 'casual clothes',
            'negative': 'tie',
            'blocks': {
              'positive': ['角色·美游便服'],
            },
          },
        ],
      }, recoverBlocks: true);
      expect(draw.blocks.first.kind, PromptBlockKind.scene);
      final positives = draw.blocks.where(
        (b) => b.character >= 0 && !b.negative,
      );
      expect(positives.map((b) => b.counterpartIn(draw.blocks)?.text), [
        'hat',
        'tie',
      ]);
    },
  );

  test(
    'library contributes only its newly added negative tags to the matched style block',
    () {
      const style = PromptBlock(
        kind: PromptBlockKind.style,
        name: 'D33',
        text: 'artist:one',
        start: 0,
      );
      const r = DrawProposal(
        positive: 'artist:one',
        negative: 'lowres, watermark',
        blocks: [style],
      );
      final entry = TagEntry(
        id: 'art',
        category: TagCategory.artist,
        name: 'D33',
        positive: 'artist:one',
        negative: 'lowres, 0.7::bad anatomy::, artifacts',
      );
      final draw = proposalWithArtistNegatives(r, [entry]);
      expect(draw.negative, 'lowres, watermark, 0.7::bad anatomy::, artifacts');
      expect(
        style.counterpartIn(draw.blocks)?.text,
        '0.7::bad anatomy::, artifacts',
      );
      var seq = 0;
      final gen = proposalSendState(
        GenerateState.initial(),
        DrawProposal.fromJson(draw.toJson()),
        SectionImport.clear,
        allowEditNegative: true,
        newId: () => 'id${seq++}',
      );
      final link = gen.promptFoldLinks.single;
      expect(link.paired, true);
      expect(link.negativeBody, '0.7::bad anatomy::, artifacts');
      expect(outputOf(gen.negativePromptRaw), draw.negative);
      expect(gen.negativePromptRaw, startsWith('lowres, watermark, <#'));

      // An existing unlabelled negative was not contributed by the library.
      final existing = proposalWithArtistNegatives(
        DrawProposal(
          positive: r.positive,
          negative: entry.negative,
          blocks: [style],
        ),
        [entry],
      );
      expect(existing.blocks.single, style);
      expect(style.counterpartIn(existing.blocks), isNull);
      expect(
        proposalWithArtistNegatives(
          const DrawProposal(positive: 'artist:one'),
          [entry],
        ).blocks,
        isEmpty,
      );
    },
  );

  test(
    'matching labels pair within a character and ambiguous or different labels stay separate',
    () {
      const positive = PromptBlock(
        kind: PromptBlockKind.character,
        name: '美游',
        text: 'maid',
        start: 0,
      );
      const negative = PromptBlock(
        kind: PromptBlockKind.character,
        name: '美游',
        text: 'hat',
        start: 0,
        negative: true,
      );
      const otherOwner = PromptBlock(
        kind: PromptBlockKind.character,
        name: '美游',
        text: 'bow',
        start: 0,
        character: 0,
        negative: true,
      );
      const duplicate = PromptBlock(
        kind: PromptBlockKind.character,
        name: '美游',
        text: 'dress',
        start: 6,
      );
      expect(
        positive.counterpartIn([positive, negative, otherOwner]),
        negative,
      );
      expect(positive.counterpartIn([positive, otherOwner]), isNull);
      expect(positive.counterpartIn([positive, negative, duplicate]), isNull);
      expect(negative.counterpartIn([positive, negative, duplicate]), isNull);
    },
  );
  test(
    'opted-in channel and legacy draws recover the already separated Miyu lines',
    () async {
      final wire = {'positive': splitPrompt, 'negative': '', 'characters': []};
      final file = decodeRulesFile(
        await rootBundle.loadString('assets/prompts/semantic-nai5.yaml'),
      );
      final model = _Replies([
        '好喵。\n\u0060\u0060\u0060nai_draw\n${jsonEncode(wire)}\n\u0060\u0060\u0060',
      ]);
      final events = await LocalAgentRuntime(provider: model, tools: const [])
          .run(
            AgentTurnRequest(
              userText: '画美游',
              imageModel: 'nai5',
              customRules: file.rules,
              retries: 0,
            ),
          )
          .toList();
      expect(model.calls, hasLength(1));
      for (final r in [
        events.whereType<AgentDone>().single.result,
        AgentResult.fromJson(wire, recoverBlocks: true),
      ]) {
        expect(r.positive, splitPrompt);
        expect(r.blocks.map((b) => b.kind), [
          PromptBlockKind.character,
          PromptBlockKind.character,
          PromptBlockKind.scene,
        ]);
        expect(
          r.blocks.map((b) => b.text),
          splitPrompt
              .split('\n')
              .skip(1)
              .map((s) => s.replaceFirst(RegExp(r',$'), '')),
        );
        final proposal = DrawProposal(positive: r.positive, blocks: r.blocks);
        var id = 0;
        final canvas = proposalSendState(
          GenerateState.initial(),
          proposal,
          SectionImport.newSection,
          newId: () => 's${id++}',
        );
        final section = canvas.sections.last;
        expect(section.foldLinks, hasLength(3));
        expect(outputOf(section.positiveRaw), section.positive);
        expect(section.positiveRaw, startsWith('high complexity,'));
      }
      expect(AgentResult.fromJson(wire).blocks, isEmpty);
      expect(
        AgentResult.fromJson({
          ...wire,
          'blocks': {
            'positive': [null, null, null, null],
          },
        }, recoverBlocks: true).blocks,
        isEmpty,
      );
      final badCount = AgentResult.fromJson({
        ...wire,
        'blocks': {
          'positive': ['角色·错位'],
        },
      }, recoverBlocks: true);
      expect(badCount.blocks, hasLength(3));
      expect(badCount.blocks.map((b) => b.name), isNot(contains('错位')));
      expect(
        AgentResult.fromJson({
          'positive': '1girl, solo, soft lighting',
        }, recoverBlocks: true).blocks,
        isEmpty,
      );
      final weighted = {
        'positive': '1.2::soft lighting,\nstanding::,\nhigh complexity',
      };
      expect(
        completePromptBlocks(
          AgentResult.fromJson(weighted, recoverBlocks: true).blocks,
          weighted,
        ),
        isEmpty,
      );
    },
  );

  test(
    'expanded-only drawings recover only complete named sources and character fields',
    () {
      const artist = '1.3::artist:first, artist:second::';
      final draw = DrawProposal.fromJson({
        'positive': '$artist,\nmoonlight',
        'characters': [
          {'name': '旅人', 'positive': 'silver hair', 'negative': 'hat'},
        ],
      });
      final result = draw.withValidatedBlocks(
        [],
        knownResources: const {
          'artist': {'插画': artist, '重复的一部分': 'artist:first', '不存在': 'artist:x'},
        },
      );
      expect(result.blocks.map((b) => b.name), ['插画', '旅人', '旅人']);
      expect(result.blocks.map((b) => b.text), [artist, 'silver hair', 'hat']);
      expect(result.blocks.last.negative, true);
      expect(
        result.toJson(includeBlocks: false),
        draw.toJson(includeBlocks: false),
      );
      expect(draw.withValidatedBlocks([]).blocks, isEmpty);
      final legacy = AgentResult.fromJson({
        'positive': 'scene, moon',
        'blocks': {
          'positive': ['场景·月光'],
        },
        'characters': [
          {
            'name': '旅人',
            'positive': 'silver hair',
            'blocks': {
              'positive': ['角色·银发'],
            },
          },
        ],
      });
      expect(legacy.blocks.map((b) => b.name), ['月光', '银发']);
    },
  );

  for (final family in ['nai45', 'nai5']) {
    test(
      '$family semantic preset maps model replies to isolated canvas blocks',
      () async {
        final file = decodeRulesFile(
          await rootBundle.loadString('assets/prompts/semantic-$family.yaml'),
        );
        const positive =
            '2girls,\nmoonlit courtyard, soft shadows,\n1.2::silver light, mist::';
        final spec = {
          'section': '月夜庭院',
          'positive': positive,
          'negative': 'lowres',
          'blocks': {
            'positive': [null, '场景：庭院・moon', '画风·光影'],
            'negative': ['其它·排除'],
          },
          'characters': [
            {
              'name': '旅人',
              'positive': 'silver hair, blue coat',
              'negative': 'hat',
              'position': '0.2500,0.5000',
              'blocks': {
                'positive': ['角色·旅人'],
                'negative': ['其它·帽子:shirt'],
              },
            },
            {
              'name': '朋友',
              'positive': 'black hair, red coat',
              'blocks': {
                'positive': ['角色·朋友'],
              },
            },
          ],
        };
        const fence = '\u0060\u0060\u0060';
        // Build a real fenced response, keeping the JSON's escaped newlines intact.
        final wire = [
          '画好了。',
          '${fence}nai_draw',
          jsonEncode(spec),
          fence,
        ].join('\n');
        final imageModel = family == 'nai5' ? 'nai_v5' : 'nai_v45_full';
        for (final optedIn in [true, false]) {
          final model = _Replies([wire]);
          final events =
              await LocalAgentRuntime(provider: model, tools: const [])
                  .run(
                    AgentTurnRequest(
                      userText: '画两位旅人',
                      imageModel: imageModel,
                      customRules: optedIn ? file.rules : null,
                      rerolls: 0,
                      retries: 0,
                    ),
                  )
                  .toList();
          final result = events.whereType<AgentDone>().single.result;
          expect(model.calls, hasLength(1));
          expect(result.replyText, '画好了。');
          expect(result.positive, positive);
          expect(result.section, '月夜庭院');
          if (!optedIn) {
            expect(result.blocks, isEmpty);
            continue;
          }
          expect(result.blocks, hasLength(6));
          expect(result.blocks.singleWhere((b) => b.name == '庭院').icon, 'Moon');
          expect(result.blocks.singleWhere((b) => b.name == '光影').icon, isNull);
          final proposal = DrawProposal.fromJson(
            DrawProposal(
              section: result.section,
              positive: result.positive,
              negative: result.negative,
              characters: result.characters,
              blocks: result.blocks,
            ).toJson(),
          );
          expect(
            proposal.toJson(includeBlocks: false),
            isNot(contains('promptBlocks')),
          );
          expect(
            proposal.blocks.singleWhere((b) => b.name == '庭院').icon,
            'Moon',
          );
          for (final mode in SectionImport.values) {
            var seq = 0;
            final canvas = GenerateState.initial().copyWith(
              params: GenParams(
                model: family == 'nai5' ? 'NAI 5.0 Full' : 'NAI 4.5 Full',
                seed: '73',
              ),
              prompt: '2girls',
              sections: const [
                PromptSection.main(),
                PromptSection(id: 'old', name: '已有', positive: 'soft shadows'),
              ],
            );
            final imported = proposalSendState(
              canvas,
              proposal,
              mode,
              newId: () => 'id${seq++}',
            );
            final standard = proposalSendState(
              canvas,
              DrawProposal(
                positive: result.positive,
                negative: result.negative,
                characters: result.characters,
              ),
              mode,
              newId: () => 'id${seq++}',
            );
            final groupedState = composeSections(imported);
            final plainState = composeSections(standard);
            expect(
              buildNaiPayload(groupedState, presetId: 'none').body,
              buildNaiPayload(plainState, presetId: 'none').body,
            );
            expect(
              buildBotParams(groupedState, seed: 73, presetId: 'none'),
              buildBotParams(plainState, seed: 73, presetId: 'none'),
            );
            final isSection =
                mode == SectionImport.newSection ||
                mode == SectionImport.aiSection;
            final section = isSection ? imported.sections.last : null;
            if (section != null) expect(section.name, '月夜庭院');
            final body = section?.positive ?? imported.prompt;
            final draft = section?.positiveRaw ?? imported.promptRaw;
            expect(
              body,
              isSection ? standard.sections.last.positive : standard.prompt,
            );
            expect(outputOf(draft), body);
            expect(draft, contains('庭院 · 场景'));
            expect(
              (section?.foldLinks ?? imported.promptFoldLinks)
                  .singleWhere((l) => l.temporaryCategory == 'scene')
                  .temporaryIcon,
              'Moon',
            );
            expect(
              imported.characters.first.foldLinks
                  .singleWhere((l) => l.negativeName.isNotEmpty)
                  .temporaryIcon,
              'Shirt',
            );
            expect(draft, contains('1.2::silver light, mist::'));
            expect(
              (section?.foldLinks ?? imported.promptFoldLinks)
                  .where((b) => b.temporaryCategory == 'scene')
                  .single
                  .sourceEntryId,
              isNull,
            );
            expect(imported.characters.map((c) => c.positive), [
              'silver hair, blue coat',
              'black hair, red coat',
            ]);
            expect(
              outputOf(imported.characters.first.positiveRaw),
              'silver hair, blue coat',
            );
            expect(outputOf(imported.characters.first.negativeRaw), 'hat');
            expect(imported.characters.first.position, '0.2500,0.5000');
            expect(imported.characters.last.positiveRaw, contains('朋友'));
            final snapshot = PromptSnapshot.of(imported);
            expect(
              PromptSnapshot.fromJson(snapshot.toJson()).sameAs(snapshot),
              isTrue,
            );
          }
        }
      },
    );
  }

  test(
    'annotations survive a multiline resource but never break a weight or a stale archive',
    () {
      const source = {
        'positive': '1.3::mist,\nfog::,\n__ARTIST_A1__',
        'blocks': {
          'positive': ['场景·雾', '场景·余雾', '画风·夜曲'],
        },
      };
      String expand(String s) =>
          s.replaceAll('__ARTIST_A1__', 'artist:a,\nartist:b');
      final positive = expand(source['positive'] as String);
      final draw = {'positive': positive};
      final blocks = completePromptBlocks(
        PromptBlock.fromDraw(source, draw, expand),
        draw,
      );
      expect(blocks.map((b) => b.name), ['夜曲']);
      expect(blocks.single.text, 'artist:a,\nartist:b');
      expect(
        DrawProposal.fromJson({
          ...draw,
          'promptBlocks': [
            {...blocks.single.toJson(), 'character': 12},
            {...blocks.single.toJson(), 'start': 99999},
            {...blocks.single.toJson(), 'text': 'wrong prompt'},
            blocks.single.toJson(),
          ],
        }).blocks.map((b) => b.name),
        ['夜曲'],
      );
      expect(
        PromptBlock.fromDraw(
          {
            ...source,
            'blocks': {
              'positive': ['场景·不完整'],
            },
          },
          draw,
          expand,
        ),
        isEmpty,
      );
      expect(DrawProposal.fromJson(draw).positive, positive);
      expect(DrawProposal.fromJson(draw).blocks, isEmpty);
    },
  );

  test('SillyTavern imports ordered enabled and disabled real sections', () {
    final imported = decodeRulesFile(
      jsonEncode({
        'prompts': [
          {'identifier': 'a', 'name': 'First', 'content': 'first scene'},
          {'identifier': 'b', 'name': 'Second', 'content': 'second scene'},
          {'identifier': 'marker', 'marker': true, 'content': 'placeholder'},
        ],
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'b', 'enabled': false},
              {'identifier': 'marker'},
              {'identifier': 'a', 'enabled': true},
            ],
          },
        ],
      }),
    );
    expect(imported.rules.map((r) => r.name), ['Second', 'First']);
    expect(imported.rules.map((r) => r.enabled), [false, true]);
  });
}
