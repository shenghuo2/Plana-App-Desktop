import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'presets/default_rules.dart';
import 'presets/preset_rule.dart';
export 'presets/default_rules.dart';
export 'presets/preset_rule.dart' hide renderRules;
export 'presets/rules_library.dart';
export 'presets/rules_file.dart';

String _imageModelOf(RulesFamily f) =>
    f == RulesFamily.nai5 ? 'nai_v5_full' : 'nai_v45_full';
List<PresetRule> withToolLayer(List<PresetRule> rules, String toolLayer) {
  final body = [
    for (final r in rules)
      if (r.name != kToolLayerName) r,
  ];
  if (toolLayer.trim().isEmpty) return body;
  final layer = PresetRule(name: kToolLayerName, content: toolLayer.trim());
  final i = body.indexWhere((r) => r.name == 'role');
  // 别写成 `i < 0 ? [...] : [...]..insert(...)`:级联 `..` 的优先级比三元低,
  // 会作用在整个三元的结果上,没有 role 时工具层被插两遍
  if (i < 0) return [...body, layer];
  return [...body]..insert(i + 1, layer);
}

String? _toolLayerCache;
String? _outputFormatCache;

/// app 自带的工具层:怎么调工具、系统塞进来的数据块怎么读。
Future<String> appToolLayer() async => _toolLayerCache ??=
    (await rootBundle.loadString('assets/prompts/tool_layer.md')).trim();

/// 出图代码块的格式。**只给自定义接口那条用** —— 服务端那条由后端代码自己发一份
/// 同样的说明;自定义接口没有后端外壳,预设里又不再讲这个,不补上模型写不出能解析的块。
Future<String> appOutputFormat() async => _outputFormatCache ??=
    (await rootBundle.loadString('assets/prompts/output_format.md')).trim();

// ---- 规则文件 ----
//
// 用 YAML,而且段落写法与服务端预设文件一致(name / when / content: |)。你改服务端
// 预设用的就是这种写法,两边的段可以直接互相复制;导入时也认一整份服务端预设文件,
// 只取其中 group: rules 那段。

final _defaultCache = <RulesFamily, ({DefaultRules value, DateTime at})>{};
const _defaultTtl = Duration(minutes: 10);

Future<DefaultRules> fetchDefaultRules(
  RulesFamily f, {
  required String backendBase,
  required String sessionId,
  bool fresh = false,
  http.Client? client,
}) async {
  final hit = _defaultCache[f];
  if (!fresh &&
      hit != null &&
      DateTime.now().difference(hit.at) < _defaultTtl) {
    return hit.value;
  }
  // 没有 Bot 授权也照样取:服务端对这个端点不要求会话(自定义接口那条要它当系统提示)
  if (backendBase.isNotEmpty) {
    final c = client ?? http.Client();
    try {
      final r = await c
          .get(
            Uri.parse(
              '$backendBase/api/agent/preset-rules?image_model=${_imageModelOf(f)}',
            ),
            headers: sessionId.isEmpty
                ? const {}
                : {'Authorization': 'Bearer $sessionId'},
          )
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        final got = DefaultRules.fromJson(
          jsonDecode(utf8.decode(r.bodyBytes)),
          f,
        );
        if (got != null) {
          _defaultCache[f] = (value: got, at: DateTime.now());
          return got;
        }
      }
    } catch (_) {
      // 老后端没有这个端点、或者网络抖了:落到下面
    } finally {
      if (client == null) c.close();
    }
  }
  // 取不到新的:手上有旧的就先用旧的,比包里那份新
  return hit?.value ?? bundledDefaultRules(f);
}

/// 只要规则内容的简写。
Future<List<PresetRule>> defaultRules(
  RulesFamily f, {
  required String backendBase,
  required String sessionId,
  bool fresh = false,
}) async => (await fetchDefaultRules(
  f,
  backendBase: backendBase,
  sessionId: sessionId,
  fresh: fresh,
)).rules;

String renderRules(
  List<PresetRule> rules,
  List<String>? modes, {
  List<String> chosen = const [],
}) => [
  for (final r in rules)
    if (r.enabled && _whenWanted(r.when, modes, chosen)) r.content,
].join('\n\n');

bool _whenWanted(String when, List<String>? modes, List<String> chosen) {
  if (when.isEmpty) return true;
  if (when.startsWith(kWhenNotPrefix)) {
    final key = when.substring(kWhenNotPrefix.length).trim();
    return !chosen.contains(key) && !(modes?.contains(key) ?? false);
  }
  if (chosen.contains(when)) return true;
  if (when.startsWith(kModeWhenPrefix)) return false;
  return modes == null || modes.contains(when);
}
