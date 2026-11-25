import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../../core/store/atomic_file.dart';

const manualImageTypes = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'avif'];
const manualVideoTypes = ['mp4', 'm4v', 'webm'];

/// Shipped articles are read-only. Each locally saved page is an independent
/// override, so adding a new bundled chapter never discards an author's work.
class ManualLibrary {
  ManualLibrary(this.root);

  final Directory root;
  Directory get pages => Directory(p.join(root.path, 'pages'));
  Directory get media => Directory(p.join(root.path, 'media'));
  static final _pageId = RegExp(r'^[a-z][a-z0-9-]{0,79}$');
  static final _mediaName = RegExp(r'^m-[0-9a-f]{32}\.[a-z0-9]+$');
  final _staged = <String>{};
  bool _closed = false;

  Future<void> prepare() async {
    await pages.create(recursive: true);
    await media.create(recursive: true);
  }

  static String _unique() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<Map<String, Object?>> load() async {
    final articles = <Map<String, dynamic>>[];
    final unreadable = <String>[];
    await for (final entry in pages.list(followLinks: false)) {
      if (entry is! File || p.extension(entry.path) != '.json') continue;
      try {
        final page =
            jsonDecode(await entry.readAsString()) as Map<String, dynamic>;
        _validate(page);
        if (page['id'] != p.basenameWithoutExtension(entry.path)) {
          throw const FormatException('页面编号与文件名不一致');
        }
        articles.add(page);
      } on Object {
        unreadable.add(p.basename(entry.path));
      }
    }
    articles.sort(
      (a, b) => a['created'].toString().compareTo(b['created'].toString()),
    );
    return {'pages': articles, 'unreadable': unreadable};
  }

  static void _validate(Map<String, dynamic> page) {
    bool id(dynamic value) => value is String && _pageId.hasMatch(value);
    bool strings(dynamic value) =>
        value is List && value.every((v) => v is String);
    if (!id(page['id']) ||
        !id(page['section']) ||
        page['title'] is! String ||
        (page['title'] as String).trim().isEmpty ||
        page['summary'] is! String ||
        page['blocks'] is! List) {
      throw const FormatException('请填写页面标题并检查章节。');
    }
    final headings = <String>{};
    for (final b in page['blocks'] as List) {
      if (b is! Map<String, dynamic>) throw const FormatException('内容块格式有误。');
      final valid = switch (b['type']) {
        'h2' ||
        'h3' => id(b['id']) && headings.add(b['id']) && b['text'] is String,
        'p' => b['text'] is String,
        'ol' || 'ul' => strings(b['items']),
        'callout' =>
          b['title'] is String &&
              b['text'] is String &&
              const ['info', 'tip', 'warn'].contains(b['tone']),
        'table' =>
          strings(b['headers']) &&
              b['rows'] is List &&
              (b['rows'] as List).every(strings),
        'widget' => const [
          'topbar-demo',
          'semantic-chips',
          'proxy-route',
        ].contains(b['kind']),
        'cards' =>
          b['items'] is List &&
              (b['items'] as List).every(
                (c) =>
                    c is Map &&
                    c['title'] is String &&
                    c['desc'] is String &&
                    id(c['target']) &&
                    (c['heading'] == null ||
                        c['heading'] == '' ||
                        id(c['heading'])),
              ),
        'image' || 'video' =>
          b['file'] is String &&
              _mediaName.hasMatch(b['file']) &&
              (b['type'] == 'image' ? manualImageTypes : manualVideoTypes)
                  .contains(p.extension(b['file']).substring(1)) &&
              b['caption'] is String,
        _ => false,
      };
      if (!valid) {
        throw FormatException('请检查「${b['type']}」内容块。');
      }
    }
  }

  Future<Map<String, dynamic>> save(Map<String, dynamic> page) async {
    _validate(page);
    final target = File(p.join(pages.path, '${page['id']}.json'));
    final lock = await File(
      p.join(root.path, '.edit-lock'),
    ).open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      final previous = await target.exists()
          ? jsonDecode(await target.readAsString()) as Map<String, dynamic>
          : null;
      if (previous?['revision'] != page['revision']) {
        throw const FormatException('这篇说明已在别处修改。请取消本次编辑，重新打开手册后再编辑。');
      }
      final used = <String>{};
      for (final block in page['blocks'] as List) {
        if (block['type'] == 'image' || block['type'] == 'video') {
          final name = block['file'] as String;
          if (!await File(p.join(media.path, name)).exists()) {
            throw const FormatException('找不到已插入的素材，请重新选择文件。');
          }
          used.add(name);
        }
      }
      final now = DateTime.now().toUtc().toIso8601String();
      final saved = <String, dynamic>{
        'id': page['id'],
        'section': page['section'],
        'title': page['title'].trim(),
        'summary': page['summary'],
        'blocks': page['blocks'],
        'created': previous?['created'] ?? now,
        'updated': now.substring(0, 10),
        'revision': _unique(),
      };
      await writeStringAtomic(
        target,
        const JsonEncoder.withIndent('  ').convert(saved),
      );
      _staged.removeAll(used);
      return saved;
    } finally {
      await lock.close();
    }
  }

  Future<Map<String, String>> stage(File source) async {
    final extension = p.extension(source.path).toLowerCase();
    final suffix = extension.isEmpty ? '' : extension.substring(1);
    final isVideo = manualVideoTypes.contains(suffix);
    if (!isVideo && !manualImageTypes.contains(suffix)) {
      throw const FormatException('请选择图片、GIF、MP4 或 WebM 视频。');
    }
    final name = 'm-${_unique()}$extension';
    final dest = File(p.join(media.path, name));
    try {
      await source.copy(dest.path);
      if (_closed) throw const FormatException('手册已关闭。');
      _staged.add(name);
      return {'type': isVideo ? 'video' : 'image', 'file': name, 'caption': ''};
    } catch (_) {
      if (await dest.exists()) await dest.delete();
      rethrow;
    }
  }

  Future<void> discardStaged() async {
    final pending = _staged.toList();
    _staged.removeAll(pending);
    for (final name in pending) {
      final file = File(p.join(media.path, name));
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // A video can still be releasing its Windows file handle.
        _staged.add(name);
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    await discardStaged();
  }
}
