import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../import/image_metadata.dart';
import 'metadata_processing.dart';

/// The single-image form keeps text exactly as entered, including unfinished
/// numbers. Validation and conversion happen when an image is written.
class MetadataDraft {
  const MetadataDraft({
    required this.fields,
    this.source = 'Plana',
    this.imagePath,
    this.outputDirectory = '',
    this.advanced = false,
  });

  static final defaults = Map<String, dynamic>.unmodifiable(
    metadataComment(null),
  );
  final Map<String, dynamic> fields;
  final String source;
  final String? imagePath;
  final String outputDirectory;
  final bool advanced;

  factory MetadataDraft.fromJson(Map<String, dynamic> json) => MetadataDraft(
    fields: {
      ...defaults,
      if (json['fields'] case final Map<String, dynamic> saved) ...saved,
    },
    source: json['source'] is String ? json['source'] : 'Plana',
    imagePath: json['imagePath'] is String ? json['imagePath'] : null,
    outputDirectory: json['outputDirectory'] is String
        ? json['outputDirectory']
        : '',
    advanced: json['advanced'] == true,
  );

  Map<String, dynamic> toJson() => {
    'fields': fields,
    'source': source,
    if (imagePath != null) 'imagePath': imagePath,
    'outputDirectory': outputDirectory,
    'advanced': advanced,
  };

  MetadataDraft copyWith({
    Map<String, dynamic>? fields,
    String? outputDirectory,
    bool? advanced,
  }) => MetadataDraft(
    fields: fields ?? this.fields,
    source: source,
    imagePath: imagePath,
    outputDirectory: outputDirectory ?? this.outputDirectory,
    advanced: advanced ?? this.advanced,
  );

  Map<String, dynamic> buildComment() {
    final edits = <String, dynamic>{
      'sm': fields['sm'] == true,
      'sm_dyn': fields['sm'] == true && fields['sm_dyn'] == true,
    };
    final errors = <String, String>{};
    for (final entry in defaults.entries) {
      final key = entry.key;
      if (entry.value is bool) continue;
      final text = fields[key]?.toString().trim() ?? '';
      if (entry.value is String) {
        edits[key] = text;
        if (text.isEmpty && (key == 'sampler' || key == 'noise_schedule')) {
          errors[key] = '请填写此项';
        }
        continue;
      }
      final integer = entry.value is int;
      final num? value = integer ? int.tryParse(text) : double.tryParse(text);
      final min = switch (key) {
        'steps' => 1,
        'seed' => -1,
        _ => 0,
      };
      if (value == null || !value.isFinite || value < min) {
        errors[key] = integer ? '请输入不小于 $min 的整数' : '请输入有效的非负数';
      } else {
        edits[key] = value;
      }
    }
    if (errors.isNotEmpty) throw MetadataFieldErrors(errors);
    return updateMetadataComment(fields, edits);
  }
}

class MetadataFieldErrors extends FormatException {
  MetadataFieldErrors(this.fields)
    : super('请检查工具箱「单张处理」中的生成参数（${fields.keys.join('、')}）');
  final Map<String, String> fields;
}

final metadataDraftProvider =
    NotifierProvider<MetadataDraftNotifier, MetadataDraft>(
      MetadataDraftNotifier.new,
    );

class MetadataDraftNotifier extends Notifier<MetadataDraft> {
  static const _key = 'desktop_single_metadata';

  @override
  MetadataDraft build() {
    final prefs = ref.watch(prefsStoreProvider);
    final saved = prefs.get(_key);
    if (saved != null) {
      try {
        if (jsonDecode(saved) case final Map<String, dynamic> json) {
          return MetadataDraft.fromJson(json);
        }
      } on FormatException {
        // Recover the old prompt if this draft is unreadable.
      }
    }
    final legacy = prefs.get('save_settings');
    if (legacy != null) {
      try {
        if (jsonDecode(legacy) case {'customPrompt': final String prompt}) {
          return MetadataDraft(
            fields: {...MetadataDraft.defaults, 'prompt': prompt},
          );
        }
      } on FormatException {
        // A new form can still be used when previous settings are unreadable.
      }
    }
    return MetadataDraft(fields: MetadataDraft.defaults);
  }

  void _save(MetadataDraft next) {
    state = next;
    ref
        .read(prefsStoreProvider)
        .writeDebounced(key: _key, value: jsonEncode(next.toJson()));
  }

  void readImage(ImageMetadata? meta, String? path) {
    final raw = meta?.raw;
    _save(
      MetadataDraft(
        fields: metadataComment(meta),
        source: meta?.isNovelAI == true && raw is Map
            ? raw['Source']?.toString() ?? 'NovelAI'
            : 'Plana',
        imagePath: path,
        outputDirectory: state.outputDirectory,
        advanced: state.advanced,
      ),
    );
  }

  void editFields(Map<String, dynamic> edits) =>
      _save(state.copyWith(fields: {...state.fields, ...edits}));

  void setOutputDirectory(String path) =>
      _save(state.copyWith(outputDirectory: path));

  void setAdvanced(bool expanded) => _save(state.copyWith(advanced: expanded));
}
