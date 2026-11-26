import 'dart:convert';

import 'tool_protocol.dart';

// Some gateways return the model's serialized call inside the text channel.
// Both DeepSeek encodings and GLM delimit arguments without XML escaping them.
const _bar = r'[|｜][ \t]*(?:[|｜][ \t]*)?';
const _dsml = '${_bar}DSML[ \\t]*$_bar';
final _token = RegExp(
  '`+|<\\s*(Think|thinking_process|Reference_Example)\\s*>|'
  '<[ \\t]*(?:$_dsml(tool_calls|function_calls|calls)|(tool_call))[ \\t]*>',
  caseSensitive: false,
);
final _dsmlEnd = {
  for (final tag in ['tool_calls', 'function_calls', 'calls'])
    tag: RegExp('</[ \\t]*$_dsml$tag[ \\t]*>', caseSensitive: false),
};
final _glmEnd = RegExp(r'</tool_call\s*>', caseSensitive: false);
final _invoke = RegExp(
  '<[ \\t]*${_dsml}invoke\\s+name="([\\w.-]+)"\\s*>(.*?)'
  '</[ \\t]*${_dsml}invoke\\s*>',
  caseSensitive: false,
  dotAll: true,
);
final _dsmlParameter = RegExp(
  '<[ \\t]*${_dsml}parameter\\s+name="([\\w.-]+)"\\s+string="(true|false)"\\s*>'
  '(.*?)</[ \\t]*${_dsml}parameter\\s*>',
  caseSensitive: false,
  dotAll: true,
);
final _glmName = RegExp(r'^[\w.-]+');
final _glmParameter = RegExp(
  r'<arg_key>\s*([\w.-]+)\s*</arg_key>\s*<arg_value>(.*?)</arg_value>',
  caseSensitive: false,
  dotAll: true,
);

class NativeToolBlock {
  const NativeToolBlock(
    this.start,
    this.end,
    this.body,
    this.dsml,
    this.closed,
  );
  final int start, end;
  final String body;
  final bool dsml, closed;

  List<ToolCall> decode() {
    if (!closed) throw const FormatException('工具调用没有收尾');
    final calls = <ToolCall>[];
    var rest = body.trim();
    if (dsml) {
      while (rest.isNotEmpty) {
        final invoke = _invoke.matchAsPrefix(rest);
        if (invoke == null) throw const FormatException('工具名称或调用格式有误');
        calls.add(ToolCall(invoke[1]!, _arguments(invoke[2]!)));
        rest = rest.substring(invoke.end).trimLeft();
      }
    } else {
      final name = _glmName.matchAsPrefix(rest);
      if (name != null) {
        calls.add(ToolCall(name[0]!, _arguments(rest.substring(name.end))));
      }
    }
    if (calls.isEmpty) throw const FormatException('缺少工具调用');
    return calls;
  }

  Map<String, dynamic> _arguments(String body) {
    final args = <String, dynamic>{};
    var rest = body.trim();
    final parameter = dsml ? _dsmlParameter : _glmParameter;
    while (rest.isNotEmpty) {
      final m = parameter.matchAsPrefix(rest);
      if (m == null) throw const FormatException('工具参数格式有误');
      final key = m[1]!;
      if (args.containsKey(key)) throw const FormatException('工具参数重名');
      final value = dsml ? m[3]! : m[2]!;
      final structured = dsml
          ? m[2]!.toLowerCase() == 'false'
          : value.trimLeft().startsWith('[');
      args[key] = structured ? jsonDecode(value) : value;
      rest = rest.substring(m.end).trimLeft();
    }
    return args;
  }
}

/// Finds actual call envelopes, skipping Markdown examples and reasoning.
/// An unfinished envelope is still hidden from the chat, but cannot execute.
Iterable<NativeToolBlock> nativeToolBlocks(String text) sync* {
  if (!text.contains('<')) return;
  var pos = 0;
  var lastControlEnd = -1;
  while (pos < text.length) {
    final t = _token.allMatches(text, pos).firstOrNull;
    if (t == null) return;
    pos = t.end;
    final token = t[0]!;
    if (token.startsWith('`')) {
      final closing = text.indexOf(token, pos);
      if (closing >= 0) {
        pos = closing + token.length;
      } else if (token.length >= 3) {
        return;
      }
      continue;
    }
    if (t[1] case final tag?) {
      final close = RegExp(
        '<\\s*/\\s*$tag\\s*>',
        caseSensitive: false,
      ).allMatches(text, pos).firstOrNull;
      if (close == null) return;
      pos = close.end;
      lastControlEnd = pos;
      continue;
    }
    // Quoted markup is ordinary prose. Providers put a call on its own line,
    // or directly after a closing control tag / previous call.
    final lineStart = text.lastIndexOf('\n', t.start) + 1;
    final start = lastControlEnd > lineStart ? lastControlEnd : lineStart;
    if (text.substring(start, t.start).trim().isNotEmpty) continue;
    final dsml = t[2] != null;
    final endTag = dsml ? _dsmlEnd[t[2]!.toLowerCase()]! : _glmEnd;
    final close = endTag.allMatches(text, pos).firstOrNull;
    final end = close?.end ?? text.length;
    yield NativeToolBlock(
      t.start,
      end,
      text.substring(pos, close?.start),
      dsml,
      close != null,
    );
    pos = end;
    lastControlEnd = end;
  }
}

/// Only withhold a partial control token while receiving a live frame.
String nativeToolProse(String text, {bool streaming = false}) {
  if (!text.contains('<')) return text;
  var end = text.length;
  final at = text.lastIndexOf('<');
  if (streaming && text.length - at <= 48) {
    final tail = text
        .substring(at)
        .replaceAll(RegExp(r'[ \t]'), '')
        .replaceAll('｜', '|')
        .replaceAll('||', '|')
        .toLowerCase();
    if (const [
      '<|dsml|calls>',
      '<|dsml|function_calls>',
      '<|dsml|tool_calls>',
      '<tool_call>',
    ].any((s) => s.startsWith(tail))) {
      end = at;
    }
  }
  final body = StringBuffer();
  var pos = 0;
  for (final block in nativeToolBlocks(text)) {
    if (block.start >= end) break;
    body.write(text.substring(pos, block.start));
    pos = block.end;
  }
  if (pos == 0) return end == text.length ? text : text.substring(0, end);
  if (pos < end) body.write(text.substring(pos, end));
  return body.toString().trim();
}
