import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

enum EndpointModelKind {
  chat,
  image,
  chatAndImage,
  embedding,
  transcription,
  speechSynthesis,
  other,
  unknown;

  bool supports(bool drawing) =>
      this == chatAndImage || this == (drawing ? image : chat);
}

enum ModelEvidence { provider, directory, unknown }

class CatalogModel {
  const CatalogModel(this.kind, this.source);
  static const unknown = CatalogModel(
    EndpointModelKind.unknown,
    ModelEvidence.unknown,
  );
  final EndpointModelKind kind;
  final ModelEvidence source;
}

Set<String> _values(Object? v) =>
    v is List ? v.whereType<String>().map((s) => s.toLowerCase()).toSet() : {};
EndpointModelKind _kind(bool chat, bool image) => chat && image
    ? EndpointModelKind.chatAndImage
    : chat
    ? EndpointModelKind.chat
    : image
    ? EndpointModelKind.image
    : EndpointModelKind.other;

EndpointModelKind? _specializedKind(String capability) => switch (capability) {
  'embedding' ||
  'embeddings' ||
  'text-embedding' ||
  '/v1/embeddings' => EndpointModelKind.embedding,
  'stt' ||
  'asr' ||
  'transcription' ||
  'transcriptions' ||
  'speech-to-text' ||
  'automatic-speech-recognition' ||
  'audio-transcription' ||
  'audio/transcriptions' ||
  '/v1/audio/transcriptions' => EndpointModelKind.transcription,
  'speech' ||
  'tts' ||
  'text-to-speech' ||
  'audio-speech' ||
  'audio/speech' ||
  '/v1/audio/speech' => EndpointModelKind.speechSynthesis,
  _ => null,
};

/// Vendor capability/method names, independent of the model's ID.
EndpointModelKind declaredKind(Map row, {bool anthropic = false}) {
  final mode = (row['mode'] ?? row['type'] ?? '').toString().toLowerCase();
  if (_specializedKind(mode) case final kind?) return kind;
  if (const {
    'rerank',
    'reranker',
    'moderation',
    'video',
    'audio',
    'image-to-video',
    'decision',
  }.contains(mode)) {
    return EndpointModelKind.other;
  }
  final architecture = row['architecture'], modalities = row['modalities'];
  final outputs = _values(
    row['output_modalities'] ??
        row['outputModalities'] ??
        row['supportedOutputModalities'] ??
        (architecture is Map ? architecture['output_modalities'] : null) ??
        (modalities is Map ? modalities['output'] : null),
  );
  if (outputs.isNotEmpty) {
    final chat = outputs.contains('text') || outputs.contains('text/plain');
    final image = outputs.any((s) => s == 'image' || s.startsWith('image/'));
    if (chat || image) return _kind(chat, image);
    final specialized = outputs.map(_specializedKind).nonNulls.toSet();
    if (specialized.length == 1) return specialized.single;
    return EndpointModelKind.other;
  }
  if (const {
    'image',
    'image_generation',
    'text-to-image',
    'image-to-image',
  }.contains(mode)) {
    return EndpointModelKind.image;
  }
  if (const {
    'chat',
    'text-generation',
    'responses',
    'completion',
  }.contains(mode)) {
    return EndpointModelKind.chat;
  }
  final types = _values(row['supported_endpoint_types']);
  if (types.isNotEmpty) {
    final image = types.any(
      const {
        'image-generation',
        'image',
        'images',
        'images/generations',
        '/v1/images/generations',
        'image-generation-openai',
      }.contains,
    );
    final chat = types.any(
      const {
        'openai',
        'openai-response',
        'openai-responses',
        'openai-response-compact',
        'anthropic',
        'anthropic-messages',
        'chat',
        'chat/completions',
        '/v1/chat/completions',
        'responses',
        '/v1/responses',
      }.contains,
    );
    if (chat || image) return _kind(chat, image);
    final specialized = types.map(_specializedKind).nonNulls.toSet();
    if (specialized.length == 1) return specialized.single;
    if (types.every(
      const {
        'rerank',
        'jina-rerank',
        'openai-video',
        'video',
        'audio',
      }.contains,
    )) {
      return EndpointModelKind.other;
    }
  }
  final capabilities = _values(row['capabilities']);
  if (capabilities.isNotEmpty) {
    if (capabilities.contains('completion') || capabilities.contains('image')) {
      return _kind(
        capabilities.contains('completion'),
        capabilities.contains('image'),
      );
    }
    final specialized = capabilities.map(_specializedKind).nonNulls.toSet();
    if (specialized.length == 1) return specialized.single;
  }
  if (anthropic && row['type'] == 'model') {
    return EndpointModelKind.chat;
  }
  final methods = _values(row['supportedGenerationMethods']);
  const embeddingMethods = {'embedcontent', 'batchembedcontents', 'embedtext'};
  if (methods.any(embeddingMethods.contains) &&
      methods.every(
        (m) => m == 'counttokens' || embeddingMethods.contains(m),
      )) {
    return EndpointModelKind.embedding;
  }
  // Gemini generateContent and predict can produce different modalities.
  return EndpointModelKind.unknown;
}

class ModelDirectory {
  ModelDirectory._(this.exact, this.unique);
  final Map<String, EndpointModelKind> exact, unique;
  static const _canonical = {
    'openai',
    'anthropic',
    'google',
    'deepseek',
    'xai',
    'mistral',
    'cohere',
    'alibaba',
    'meta',
    'qwen',
    'moonshotai',
    'zai',
    'bfl',
    'stabilityai',
    'bytedance',
    'black-forest-labs',
  };
  factory ModelDirectory.fromKinds(Map<String, EndpointModelKind> entries) {
    final unique = <String, EndpointModelKind>{};
    for (final entry in entries.entries) {
      final slash = entry.key.indexOf('/');
      if (slash < 1 || !_canonical.contains(entry.key.substring(0, slash))) {
        continue;
      }
      final id = entry.key.substring(slash + 1);
      unique[id] = unique.containsKey(id)
          ? EndpointModelKind.unknown
          : entry.value;
    }
    return ModelDirectory._(entries, unique);
  }
  factory ModelDirectory.parse(Map raw) {
    final entries = <String, EndpointModelKind>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      if (value['models'] case final Map models) {
        for (final m in models.entries) {
          if (m.value is! Map) continue;
          final id = m.key.toString(), vendor = entry.key.toString();
          final kind = declaredKind(m.value as Map);
          if (kind != EndpointModelKind.unknown) {
            entries[id.startsWith('$vendor/') ? id : '$vendor/$id'] = kind;
          }
        }
      } else if (entry.key.toString().contains('/')) {
        final kind = declaredKind(value);
        if (kind != EndpointModelKind.unknown) {
          entries[entry.key.toString()] = kind;
        }
      }
    }
    return ModelDirectory.fromKinds(entries);
  }
  EndpointModelKind lookup(String id, {String? vendor, String? canonical}) {
    if (canonical != null && exact.containsKey(canonical)) {
      return exact[canonical]!;
    }
    if (canonical != null && canonical != id && !canonical.contains('/')) {
      final known = lookup(canonical, vendor: vendor);
      if (known != EndpointModelKind.unknown) return known;
    }
    if (id.contains('/')) return exact[id] ?? EndpointModelKind.unknown;
    if (vendor != null && _canonical.contains(vendor)) {
      return exact['$vendor/$id'] ?? EndpointModelKind.unknown;
    }
    return unique[id] ?? EndpointModelKind.unknown;
  }
}

ModelDirectory _decodeDirectory(Uint8List bytes) =>
    ModelDirectory.parse(jsonDecode(utf8.decode(bytes)) as Map);

/// Only this public catalog is cached. Endpoint URLs, API keys and private model IDs never enter it.
class ModelDirectoryCache {
  ModelDirectoryCache({this.cacheDir = getApplicationCacheDirectory});
  final Future<Directory> Function() cacheDir;
  static final shared = ModelDirectoryCache();
  ModelDirectory? _memory;
  DateTime? _next;
  Future<ModelDirectory>? _pending;
  Future<ModelDirectory> load(http.Client client) {
    if (_memory != null && DateTime.now().isBefore(_next!)) {
      return Future.value(_memory!);
    }
    return _pending ??= _load(client).whenComplete(() => _pending = null);
  }

  Future<ModelDirectory> _load(http.Client client) async {
    final now = DateTime.now();
    File? file;
    try {
      final dir = await cacheDir();
      file = File('${dir.path}/model-capabilities-v2.json');
      if (_memory == null && await file.exists()) {
        final data = jsonDecode(await file.readAsString()) as Map;
        final kinds = data['models'] as Map;
        _memory = ModelDirectory.fromKinds({
          for (final e in kinds.entries)
            e.key as String: EndpointModelKind.values.byName(e.value as String),
        });
        _next = DateTime.fromMillisecondsSinceEpoch(data['until'] as int);
        if (now.isBefore(_next!)) return _memory!;
      }
    } catch (_) {
      /* A missing cache must not block discovery. */
    }
    for (final path in ['/experimental/v2.0/api.json', '/models.json']) {
      try {
        final resp = await client
            .get(
              Uri.https('models.dev', path, {'type': 'all'}),
              headers: {
                'Accept': 'application/json',
                'User-Agent': 'Plana/1.2',
              },
            )
            .timeout(const Duration(seconds: 12));
        if (resp.statusCode != 200) continue;
        final parsed = await compute(_decodeDirectory, resp.bodyBytes);
        if (parsed.exact.isEmpty) continue;
        _memory = parsed;
        _next = now.add(const Duration(days: 1));
        if (file != null) {
          try {
            await file.parent.create(recursive: true);
            final temp = File(
              '${file.path}.$pid.${now.microsecondsSinceEpoch}.tmp',
            );
            await temp.writeAsString(
              jsonEncode({
                'until': _next!.millisecondsSinceEpoch,
                'models': parsed.exact.map((k, v) => MapEntry(k, v.name)),
              }),
              flush: true,
            );
            await temp.rename(file.path);
          } on FileSystemException {
            /* Memory cache is still available. */
          }
        }
        return parsed;
      } catch (_) {
        /* Try the independent, model-only representation. */
      }
    }
    _next = now.add(const Duration(minutes: 5));
    return _memory ??= ModelDirectory.fromKinds({});
  }
}
