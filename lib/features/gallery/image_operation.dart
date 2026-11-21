/// Provenance for image processing. It contains no account credentials and is
/// deliberately separate from a text-to-image generation snapshot.
class ImageOperation {
  const ImageOperation({
    required this.tool,
    required this.sourceName,
    required this.jobId,
    required this.parameters,
    this.sourceId,
    this.variant,
  });

  final String tool, sourceName, jobId;
  final String? sourceId, variant;
  final Map<String, Object?> parameters;

  Map<String, Object?> toJson() => {
    'tool': tool,
    'sourceName': sourceName,
    'jobId': jobId,
    if (sourceId != null) 'sourceId': sourceId,
    if (variant != null) 'variant': variant,
    'parameters': parameters,
  };

  static ImageOperation? fromJson(Object? value) {
    if (value is! Map ||
        value['tool'] is! String ||
        value['sourceName'] is! String ||
        value['jobId'] is! String) {
      return null;
    }
    return ImageOperation(
      tool: value['tool'] as String,
      sourceName: value['sourceName'] as String,
      jobId: value['jobId'] as String,
      sourceId: value['sourceId'] is String
          ? value['sourceId'] as String
          : null,
      variant: value['variant'] is String ? value['variant'] as String : null,
      parameters: value['parameters'] is Map
          ? Map<String, Object?>.from(value['parameters'] as Map)
          : const {},
    );
  }
}
