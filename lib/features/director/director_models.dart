import 'dart:typed_data';

enum DirectorTool {
  removeBackground('bg-removal', '去背景', '移除背景，保留透明结果；服务可能返回多种版本。'),
  lineart('lineart', '提取线稿', '提取图片的轮廓与线条。'),
  sketch('sketch', '转为草图', '将图片还原为草图。'),
  colorize('colorize', '上色', '为线稿或草图上色，可用提示词描述颜色。'),
  emotion('emotion', '调整表情', '更适合单人、正面、平静表情的动漫图片；其他区域也可能变化。'),
  declutter('declutter', '清理杂物', '清理文字、气泡等覆盖在画面上的内容。'),
  pixelSnap('pixel-snap', '像素对齐', '在本机整理已有像素画的网格，不消耗 Anlas。');

  const DirectorTool(this.code, this.label, this.help);
  final String code, label, help;
  bool get local => this == pixelSnap;
}

const directorEmotions = <String, String>{
  'neutral': '平静',
  'happy': '开心',
  'sad': '悲伤',
  'angry': '生气',
  'scared': '害怕',
  'surprised': '惊讶',
  'tired': '疲倦',
  'excited': '兴奋',
  'nervous': '紧张',
  'thinking': '思考',
  'confused': '困惑',
  'shy': '害羞',
  'disgusted': '厌恶',
  'smug': '得意',
  'bored': '无聊',
  'laughing': '大笑',
  'irritated': '烦躁',
  'aroused': '动情',
  'embarrassed': '尴尬',
  'worried': '担心',
  'love': '爱慕',
  'determined': '坚定',
  'hurt': '受伤',
  'playful': '俏皮',
};
const directorEmotionLevels = ['正常', '稍弱', '较弱', '更弱', '很弱', '最弱'];

enum DirectorPalette { off, auto, custom }

class DirectorOptions {
  const DirectorOptions({
    this.tool = DirectorTool.removeBackground,
    this.prompt = '',
    this.defry = 0,
    this.emotion = 'neutral',
    this.palette = DirectorPalette.auto,
    this.colors = 64,
    this.avoidOverRefining = false,
    this.upscale = false,
  });
  final DirectorTool tool;
  final String prompt, emotion;
  final int defry, colors;
  final DirectorPalette palette;
  final bool avoidOverRefining, upscale;

  void validate() {
    if (defry < 0 ||
        defry > 5 ||
        !directorEmotions.containsKey(emotion) ||
        colors < 2 ||
        colors > 256 ||
        prompt.length > 10000) {
      throw const FormatException('导演工具参数超出范围');
    }
  }

  Map<String, Object?> requestParameters() {
    validate();
    if (tool.local) throw const FormatException('像素对齐在本机处理');
    return {
      'req_type': tool.code,
      if (tool == DirectorTool.colorize) 'prompt': prompt,
      if (tool == DirectorTool.emotion) 'prompt': '$emotion;;$prompt',
      if (tool == DirectorTool.colorize || tool == DirectorTool.emotion)
        'defry': defry,
    };
  }

  Map<String, Object?> record() => tool.local
      ? {
          'palette': palette.name,
          'colors': colors,
          'avoidOverRefining': avoidOverRefining,
          'upscale': upscale,
        }
      : requestParameters();

  DirectorOptions copyWith({
    DirectorTool? tool,
    String? prompt,
    int? defry,
    String? emotion,
    DirectorPalette? palette,
    int? colors,
    bool? avoidOverRefining,
    bool? upscale,
  }) => DirectorOptions(
    tool: tool ?? this.tool,
    prompt: prompt ?? this.prompt,
    defry: defry ?? this.defry,
    emotion: emotion ?? this.emotion,
    palette: palette ?? this.palette,
    colors: colors ?? this.colors,
    avoidOverRefining: avoidOverRefining ?? this.avoidOverRefining,
    upscale: upscale ?? this.upscale,
  );
}

class DirectorInput {
  const DirectorInput({
    required this.id,
    required this.name,
    required this.bytes,
    required this.width,
    required this.height,
    this.galleryId,
  });
  final String id, name;
  final String? galleryId;
  final Uint8List bytes;
  final int width, height;
}

class DirectorOutput {
  const DirectorOutput(this.bytes, this.width, this.height, {this.variant});
  final Uint8List bytes;
  final int width, height;
  final String? variant;
}

String directorVariantLabel(String? variant) => switch (variant) {
  'masked' => '原图蒙版',
  'generated' => '生成补全',
  'blend' => '混合',
  _ => '转换结果',
};
