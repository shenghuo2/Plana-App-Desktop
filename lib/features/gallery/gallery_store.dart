import '../../core/util/log.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/store/atomic_file.dart';
import '../../core/store/blob_store.dart';
import '../../core/util/image_ops.dart';
import '../../core/util/webp_to_png.dart' show isWebp;
import '../generate/models.dart' show GenerateState, imageSizeOf;
import '../generate/state_codec.dart';
import 'models.dart';

class InpaintHistoryInventory {
  const InpaintHistoryInventory(this.ids, this.detachedRefs, this.retainedRefs);
  final Set<String> ids;
  final Set<String> detachedRefs;
  final Set<String> retainedRefs;
}

class InpaintHistoryRemoval {
  const InpaintHistoryRemoval(this.ids, this.detachedRefs, this.failedIds);
  final Set<String> ids;
  final Set<String> detachedRefs;
  final Set<String> failedIds;
}

typedef _HistoryInput = ({
  File file,
  String id,
  Map<String, dynamic> document,
  Map<String, dynamic>? cleaned,
  Set<String> detachedRefs,
  Set<String> retainedRefs,
});

/// 一张图的检索元数据(见 gallery_search):[text] 已按 normalizeSearchText 归一;
/// 后三项是图库按角色 / 画风归类认的来源 —— [ids] 灵感库条目 id(分区与角色卡
/// 记下的),[cards] 启用的角色卡名,[folds] 草稿里的折叠组名。
typedef GallerySearchMeta = ({
  String model,
  String text,
  List<String> ids,
  List<String> cards,
  List<String> folds,
});

/// 图库持久化(`<support>/gallery/`):每张结果 `images/<id>.png` 原图 +
/// `thumbs/<id>.jpg|png` 缩略图 + `inputs/<id>.json` 参数快照(参考图外置
/// blob 仓),旁挂 index.json(顺序/选中/发号器)。启动只读索引,像素
/// 按需懒读——重启不丢图,也不把整库塞回内存。
class GalleryStore {
  GalleryStore(this._blobs, Directory supportRoot)
    : _root = Directory('${supportRoot.path}/gallery');

  final BlobStore _blobs;
  final Directory _root;

  Directory get _imagesDir => Directory('${_root.path}/images');
  Directory get _thumbsDir => Directory('${_root.path}/thumbs');
  Directory get _inputsDir => Directory('${_root.path}/inputs');
  File get _indexFile => File('${_root.path}/index.json');

  File imageFileForPreview(String id) {
    final png = _imageFile(id);
    if (png.existsSync()) return png;
    final webp = _imageWebp(id);
    return webp.existsSync() ? webp : png;
  }

  File _imageFile(String id) => File('${_imagesDir.path}/$id.png');
  File _imageWebp(String id) => File('${_imagesDir.path}/$id.webp');

  /// 盘上那张原图(PNG 优先);都没有给 null。
  Future<File?> _existingImage(String id) async {
    for (final f in [_imageFile(id), _imageWebp(id)]) {
      if (await f.exists()) return f;
    }
    return null;
  }

  File _thumbPng(String id) => File('${_thumbsDir.path}/$id.png');
  File _thumbJpg(String id) => File('${_thumbsDir.path}/$id.jpg');
  File _thumbSourceFile(String id) => File('${_thumbsDir.path}/$id.json');
  File _inputFile(String id) => File('${_inputsDir.path}/$id.json');

  /// 重绘产物要继承的源图 id:发起重绘时置,落新图时**消费一次**后清空。
  /// 「只继承一次」的语义就落在这里 —— 此后两张图的蒙版各自独立编辑保存。

  /// 启动读出的图库(字节/快照皆空壳,懒读);首启为空。
  List<ResultImage> initialResults = const [];
  List<TrashedImage> initialTrash = const [];
  String? initialSelectedId;
  int seq = 0;
  final _clearedInpaintIds = <String>{};
  final _thumbReads = <String, Future<Uint8List?>>{};
  // Limit simultaneous decoding when a whole row of old thumbnails is rebuilt.
  final _thumbLanes = List.generate(3, (_) => Future<void>.value());
  int _nextThumbLane = 0;

  static final _seqRe = RegExp(r'^gen(\d+)$');

  Future<void> load() async {
    try {
      await _imagesDir.create(recursive: true);
      await _thumbsDir.create(recursive: true);
      await _inputsDir.create(recursive: true);
      if (!await _indexFile.exists()) {
        await _rebuildFromDisk(); // 索引缺失但图还在(如首次升级/被误删)
        return;
      }
      final j = await _readIndexInBackground(_indexFile.path);
      if (j is! Map) {
        await _rebuildFromDisk();
        return;
      }
      seq = (j['seq'] as num?)?.toInt() ?? 0;
      initialSelectedId = j['selectedId'] as String?;
      final seen = <String>{};
      final trash = <TrashedImage>[];
      if (j['trash'] is List) {
        for (final entry in j['trash'] as List) {
          final image = _parseItem(entry);
          if (image == null || !seen.add(image.id)) continue;
          final e = entry as Map;
          final stamp = _number(e['dt']);
          trash.add(
            TrashedImage(
              image,
              stamp > 0 ? stamp : DateTime.now().millisecondsSinceEpoch,
              position: _number(e['position']),
              beforeId: _validId(e['before']),
              afterId: _validId(e['after']),
            ),
          );
        }
      }
      initialTrash = List.unmodifiable(trash);
      final items = <ResultImage>[];
      if (j['items'] is List) {
        for (final entry in j['items'] as List) {
          final image = _parseItem(entry);
          if (image != null && seen.add(image.id)) items.add(image);
        }
      }
      initialResults = List.unmodifiable(await _backfillCreatedAt(items));
      final saved = _selectionFile;
      if (await saved.exists()) {
        try {
          final id = (await saved.readAsString()).trim();
          if (id.isEmpty || initialResults.any((item) => item.id == id)) {
            initialSelectedId = id.isEmpty ? null : id;
          }
        } on FileSystemException {
          // The main index still carries the last structural selection.
        }
      }
      await _includeUnindexedImages();
    } catch (e) {
      logd('[gallery-store] 索引载入失败,改从目录重建: $e');
      await _rebuildFromDisk();
    }
  }

  static int _number(Object? value, [int fallback = 0]) =>
      value is num && value.isFinite ? value.toInt() : fallback;

  static String? _validId(Object? value) =>
      value is String && RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(value)
      ? value
      : null;

  ResultImage? _parseItem(Object? raw) {
    if (raw is! Map) return null;
    final id = _validId(raw['id']);
    if (id == null) return null;
    final match = _seqRe.firstMatch(id);
    final next = match == null ? 0 : int.parse(match[1]!) + 1;
    if (next > seq) seq = next;
    if (raw['inpaintHistoryCleared'] == true) _clearedInpaintIds.add(id);
    return ResultImage(
      id: id,
      width: _number(raw['w']),
      height: _number(raw['h']),
      seed: _number(raw['seed']),
      badge:
          ResultBadge.values.where((b) => b.name == raw['badge']).firstOrNull ??
          ResultBadge.none,
      createdAt: _number(raw['t']),
      batchIndex: _number(raw['bi'], -1),
      inpaintFrom: _validId(raw['inpaintFrom']),
      inpaintHistoryCleared: raw['inpaintHistoryCleared'] == true,
      favorite: raw['favorite'] == true,
      saved: raw['sv'] == true,
      hasInput: raw['hasInput'] == true,
      operation: ImageOperation.fromJson(raw['operation']),
    );
  }

  static Map<String, Object?> _itemJson(ResultImage r) => {
    'id': r.id,
    'w': r.width,
    'h': r.height,
    'seed': r.seed,
    'badge': r.badge.name,
    't': r.createdAt,
    if (r.batchIndex >= 0) 'bi': r.batchIndex,
    if (r.inpaintFrom != null) 'inpaintFrom': r.inpaintFrom,
    if (r.inpaintHistoryCleared) 'inpaintHistoryCleared': true,
    if (r.favorite) 'favorite': true,
    if (r.saved) 'sv': true,
    'hasInput': r.hasInput,
    if (r.operation != null) 'operation': r.operation!.toJson(),
  };

  /// 原图完成写入而索引未提交时，补回新增图片并推进发号器。
  Future<void> _includeUnindexedImages() async {
    final known = {
      for (final r in initialResults) r.id,
      for (final t in initialTrash) t.image.id,
    };
    final extra = <ResultImage>[];
    await for (final entry in _imagesDir.list()) {
      if (entry is! File ||
          !(entry.path.endsWith('.png') || entry.path.endsWith('.webp'))) {
        continue;
      }
      final id = _idOf(entry);
      final match = _seqRe.firstMatch(id);
      if (match != null) {
        final next = int.parse(match[1]!) + 1;
        if (next > seq) seq = next;
      }
      if (!known.add(id)) continue;
      final (width, height) = await _imageSize(entry);
      extra.add(
        ResultImage(
          id: id,
          width: width,
          height: height,
          seed: 0,
          createdAt: (await entry.stat()).modified.millisecondsSinceEpoch,
          hasInput: await _inputFile(id).exists(),
        ),
      );
    }
    if (extra.isEmpty) return;
    extra.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    initialResults = List.unmodifiable([...extra, ...initialResults]);
    initialSelectedId ??= extra.first.id;
    scheduleIndex(
      results: initialResults,
      selectedId: initialSelectedId,
      seq: seq,
    );
  }

  /// 生成时刻缺失(升级前的老索引)→ 原图文件 mtime 一次性回填并落索引,
  /// 之后不再 stat。mtime 在备份恢复场景可能失真,但它是老图唯一可用来源。
  Future<List<ResultImage>> _backfillCreatedAt(List<ResultImage> items) async {
    var changed = false;
    final out = <ResultImage>[];
    for (final r in items) {
      if (r.createdAt > 0) {
        out.add(r);
        continue;
      }
      var t = 0;
      try {
        final f = await _existingImage(r.id);
        if (f != null) {
          t = (await f.stat()).modified.millisecondsSinceEpoch;
        }
      } catch (_) {}
      if (t > 0) changed = true;
      out.add(t > 0 ? r.withCreatedAt(t) : r);
    }
    if (changed) {
      // 防抖窗口内被杀也无妨:回填幂等,下次启动重来
      scheduleIndex(results: out, selectedId: initialSelectedId, seq: seq);
    }
    return out;
  }

  /// 索引损坏 / 缺失时的兜底:扫 `images/` 重建条目并续上发号器。
  ///
  /// **为什么必须有**:原先失败路径直接把库当成空的,而 `seq` 的赋值在 try 内
  /// 没跑到、停在初始值 `0` —— 下一张生成写 `images/gen0.png`,**覆盖盘上仍在
  /// 的老图**,事后修好索引也回不来。`vibe_library` / `char_library` 早就有
  /// 目录重建兜底,唯独图库没有,而图库存的恰恰是最不可再生的东西。见 S1C-01。
  ///
  /// **代价**:seed 与角标(`4x` / `重绘`)只存在索引里,重建取不回来,按
  /// `0` / `none` 处理;原图与参数快照都还在,重新生成、参数导入照常可用。
  Future<void> _rebuildFromDisk() async {
    final out = <ResultImage>[];
    var maxSeq = 0;
    try {
      final files = <File>[];
      await for (final ent in _imagesDir.list()) {
        if (ent is File &&
            (ent.path.endsWith('.png') || ent.path.endsWith('.webp'))) {
          files.add(ent);
        }
      }
      int numOf(File f) {
        final m = _seqRe.firstMatch(_idOf(f));
        return m == null ? -1 : int.parse(m.group(1)!);
      }

      files.sort((a, b) => numOf(a).compareTo(numOf(b))); // 还原生成先后
      for (final f in files) {
        final id = _idOf(f);
        final (w, h) = await _imageSize(f);
        var t = 0;
        try {
          t = (await f.stat()).modified.millisecondsSinceEpoch;
        } catch (_) {}
        out.add(
          ResultImage(
            id: id,
            width: w,
            height: h,
            seed: 0,
            badge: ResultBadge.none,
            createdAt: t > 0 ? t : 0,
            hasInput: await _inputFile(id).exists(),
          ),
        );
        final n = numOf(f);
        if (n + 1 > maxSeq) maxSeq = n + 1;
      }
    } catch (e) {
      logd('[gallery-store] 目录重建失败: $e');
    }
    initialResults = List.unmodifiable(out);
    initialTrash = const [];
    initialSelectedId = out.isEmpty ? null : out.last.id;
    // 关键一行:发号器只进不退,否则新图会覆盖盘上老图
    if (maxSeq > seq) seq = maxSeq;
    if (out.isNotEmpty) {
      logd('[gallery-store] 已从目录重建 ${out.length} 条,发号器续到 $seq');
    }
  }

  static String _idOf(File f) {
    final n = f.uri.pathSegments.last;
    return n.substring(0, n.lastIndexOf('.')); // 去 .png / .webp
  }

  /// 只读文件头拿宽高(PNG 的 IHDR / WebP 的 VP8X 等),不解码整图。
  static Future<(int, int)> _imageSize(File? f) async {
    if (f == null) return (0, 0);
    try {
      final head = <int>[];
      await for (final chunk in f.openRead(0, 30)) {
        head.addAll(chunk);
        if (head.length >= 30) break;
      }
      return imageSizeOf(Uint8List.fromList(head)) ?? (0, 0);
    } catch (_) {
      return (0, 0);
    }
  }

  // ---- 写入(串行队列,互不重叠) ----

  Future<void> _chain = Future.value();
  Future<void> _stateChanges = Future.value();

  /// Exit waits for user-visible trash transitions before flushing the index.
  Future<void> get pendingChanges => _stateChanges;
  void trackChange<T>(Future<T> work) {
    _stateChanges = Future.wait<void>([
      _stateChanges,
      work.then<void>((_) {}, onError: (Object _) {}),
    ]).then((_) {});
  }

  /// 写入队列排空(存储管理在清空后等它,再做 GC/重扫)。
  Future<void> get idle => Future.wait([_chain, _searchChain]).then((_) {});

  Future<T> _enqueue<T>(Future<T> Function() job) {
    final work = _chain.then((_) => job());
    _chain = work.then<void>(
      (_) {},
      onError: (Object e) {
        logd('[gallery-store] 写入失败: $e');
      },
    );
    return work;
  }

  /// 新结果落盘:原图 + 缩略图 + 参数快照(有则)。
  /// 调用时机是 addResult 同帧,bytes/input 一定在内存里。
  Future<void> persistResult(ResultImage r) {
    _blobs.referencesChanged();
    final bytes = r.bytes;
    if (bytes == null) return Future.value();
    final input = r.input;
    return _enqueue(() async {
      // 全部走原子写:半截 PNG 会变成永远打不开的坏图,半截快照 JSON 会让
      // 「重新生成」读不出参数(见 atomic_file.dart)
      await writeBytesAtomic(
        isWebp(bytes) ? _imageWebp(r.id) : _imageFile(r.id),
        bytes,
      );
      try {
        await _writeThumb(r.id, bytes, await imageFileForPreview(r.id).stat());
      } catch (
        _
      ) {} // Invalid/missing provenance makes readers use the original.
      if (input != null) {
        final enc = await encodeGenerateState(input, _blobs);
        await writeStringAtomic(
          _inputFile(r.id),
          jsonEncode({'v': 1, 'refs': enc.refs.toList(), 'state': enc.json}),
        );
      }
    });
  }

  // 索引防抖:新增/点选共用,窗口内合并成一次全量重写
  Timer? _idxTimer;
  List<ResultImage>? _idxItems;
  List<TrashedImage> _idxTrash = const [];
  int _idxRevision = 0;
  bool _selectionPending = false;
  File get _selectionFile => File('${_root.path}/selected.txt');
  String? _idxSelected;
  int _idxSeq = 0;
  Future<void> _indexWrite = Future.value();

  void scheduleIndex({
    required List<ResultImage> results,
    List<TrashedImage>? trash,
    required String? selectedId,
    required int seq,
  }) {
    initialResults = List.unmodifiable(results.map(_normalizedResult));
    initialTrash = List.unmodifiable([
      for (final t in trash ?? initialTrash)
        t.withImage(_normalizedResult(t.image)),
    ]);
    _idxTrash = initialTrash;
    _idxRevision++;
    this.seq = seq;
    _idxItems = initialResults;
    _idxSeq = seq;
    scheduleSelection(selectedId);
  }

  void scheduleSelection(String? id) {
    initialSelectedId = _idxSelected = id;
    _selectionPending = true;
    _idxTimer?.cancel();
    _idxTimer = Timer(const Duration(milliseconds: 400), flushIndex);
  }

  /// 立即写索引(前后台切换时由 AppStores.flushNow 调用)。
  Future<void> flushIndex() {
    final items = _idxItems;
    if (items == null && !_selectionPending) return _indexWrite;
    _idxItems = null;
    _selectionPending = false;
    _idxTimer?.cancel();
    final selected = _idxSelected;
    final seq = _idxSeq;
    final trash = _idxTrash;
    final revision = _idxRevision;
    final work = _enqueue(() async {
      try {
        if (items != null) {
          await _writeIndex(items, selected, seq, trash: trash);
        }
        await writeStringAtomic(_selectionFile, selected ?? '');
      } catch (_) {
        // Retain a failed snapshot only if a newer edit has not superseded it.
        if (_idxRevision == revision && _idxItems == null) {
          _idxItems = items;
          _idxTrash = trash;
          _selectionPending = true;
          _idxSeq = seq;
        }
        rethrow;
      }
    });
    _indexWrite = work;
    // Timer-triggered flushes are observed here; explicit callers still fail.
    unawaited(work.then<void>((_) {}, onError: (Object _) {}));
    return work;
  }

  ResultImage _normalizedResult(ResultImage result) =>
      _clearedInpaintIds.contains(result.id)
      ? result.withoutInpaintHistory()
      : result;

  Future<void> _writeIndex(
    List<ResultImage> items,
    String? selected,
    int seq, {
    List<TrashedImage>? trash,
  }) async {
    final index = <String, Object?>{
      'v': 1,
      'seq': seq,
      'selectedId': ?selected,
      'items': [for (final r in items.map(_normalizedResult)) _itemJson(r)],
      'trash': [
        for (final t in trash ?? initialTrash)
          {
            ..._itemJson(_normalizedResult(t.image)),
            'dt': t.deletedAt,
            'position': t.position,
            'before': ?t.beforeId,
            'after': ?t.afterId,
          },
      ],
    };
    // Small libraries can be encoded within a frame; avoid starting a worker
    // for each edit in a fresh gallery.
    final count = items.length + (trash ?? initialTrash).length;
    final text = count < 256
        ? jsonEncode(index)
        : await _encodeIndexInBackground(index);
    await writeStringAtomic(_indexFile, text);
  }

  /// 删除若干条结果的文件(上限裁剪用):原图/缩略图/快照一并删。
  /// 索引由调用方随后 scheduleIndex 重写。
  void deleteResultFiles(List<String> ids) {
    if (ids.isEmpty) return;
    unawaited(deleteResultFilesVerified(ids));
  }

  Future<void> _deleteRecoveryFiles(File target) async {
    for (final suffix in ['.pending', '.tmp', '.bak']) {
      final recovery = File('${target.path}$suffix');
      if (await FileSystemEntity.type(recovery.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await recovery.delete();
      }
    }
  }

  /// Export cleanup must preserve records whose original file cannot be
  /// removed. Revoke recovery, delete the original, then remove auxiliary files.
  Future<Set<String>> deleteResultFilesVerified(
    List<String> ids, {
    bool Function(String id)? canDelete,
  }) => _enqueue(() async {
    final deleted = <String>{};
    for (final id in ids.toSet()) {
      final originals = [_imageFile(id), _imageWebp(id)];
      try {
        if (canDelete?.call(id) == false) continue;
        // Revoke recovery before unlinking the original. A failed cleanup keeps
        // the image and its index entry available for a later retry.
        for (final file in [
          ...originals,
          _thumbPng(id),
          _thumbJpg(id),
          _thumbSourceFile(id),
          _inputFile(id),
        ]) {
          await _deleteRecoveryFiles(file);
        }
        final present = <File>[];
        var removable = true;
        for (final original in originals) {
          final type = await FileSystemEntity.type(
            original.path,
            followLinks: false,
          );
          if (type == FileSystemEntityType.file ||
              type == FileSystemEntityType.link) {
            present.add(original);
          } else if (type != FileSystemEntityType.notFound) {
            removable = false;
          }
        }
        if (!removable || canDelete?.call(id) == false) continue;
        for (final original in present) {
          original.deleteSync();
        }
        if (originals.any(
          (file) =>
              FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.notFound,
        )) {
          continue;
        }
        deleted.add(id);
      } catch (error) {
        logd('[gallery-store] 原图或恢复文件未能删除 $id: $error');
        continue;
      }
      for (final file in [
        _thumbPng(id),
        _thumbJpg(id),
        _thumbSourceFile(id),
        _inputFile(id),
      ]) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
    return Set<String>.unmodifiable(deleted);
  });

  /// 清空图库文件(存储管理「清空图库」):删光原图/缩略图/快照,
  /// 写空索引但**保留发号器**(id 永不复用)。作废挂起的索引写,
  /// 串行队列保证在途的 persistResult 先完成再删。
  Future<void> clearAllFiles({required int seq}) {
    initialResults = const [];
    initialTrash = const [];
    initialSelectedId = null;
    this.seq = seq;
    _idxItems = null;
    _idxTrash = const [];
    _idxRevision++;
    _selectionPending = false;
    _idxTimer?.cancel();
    return _indexWrite = _enqueue(() async {
      for (final d in [_imagesDir, _thumbsDir, _inputsDir]) {
        try {
          await for (final ent in d.list()) {
            try {
              await ent.delete(recursive: true);
            } catch (_) {}
          }
        } catch (_) {}
      }
      await writeStringAtomic(
        _indexFile,
        jsonEncode({'v': 1, 'seq': seq, 'items': const <Object>[]}),
      );
      await writeStringAtomic(_selectionFile, '');
    });
  }

  // ---- 懒读 ----

  Future<List<_HistoryInput>> _historyInputs() async {
    final inputs = <_HistoryInput>[];
    if (!await _inputsDir.exists()) return inputs;
    await for (final entry in _inputsDir.list(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      final document = jsonDecode(await entry.readAsString());
      if (document is! Map<String, dynamic>) {
        throw const FormatException('历史参数引用记录无法读取，已停止清理');
      }
      final state = document['state'];
      final detached = state is Map && state['inpaint'] is Map
          ? BlobStore.referencedHashes(state['inpaint'])
          : <String>{};
      Map<String, dynamic>? cleaned;
      var retained = BlobStore.referencedHashes(document);
      if (state is Map<String, dynamic> && state['inpaint'] != null) {
        final nextState = Map<String, dynamic>.of(state)..remove('inpaint');
        final nextDocument = Map<String, dynamic>.of(document)
          ..remove('refs')
          ..['state'] = nextState
          ..['inpaintHistoryCleared'] = true;
        retained = retained.difference(detached)
          ..addAll(BlobStore.referencedHashes(nextDocument));
        cleaned = {...nextDocument, 'refs': retained.toList()};
      }
      final filename = entry.uri.pathSegments.last;
      inputs.add((
        file: entry,
        id: filename.substring(0, filename.length - 5),
        document: document,
        cleaned: cleaned,
        detachedRefs: detached,
        retainedRefs: retained,
      ));
    }
    return inputs;
  }

  Future<InpaintHistoryInventory> inspectInpaintHistory() => _enqueue(() async {
    final results = [...initialResults, for (final t in initialTrash) t.image];
    final inputs = await _historyInputs();
    return InpaintHistoryInventory(
      {
        for (final input in inputs)
          if (input.cleaned != null) input.id,
        for (final result in results)
          if (result.hasInpaintComparison) result.id,
      },
      {for (final input in inputs) ...input.detachedRefs},
      {for (final input in inputs) ...input.retainedRefs},
    );
  });

  /// Serialized with result writes. The explicit marker is committed first:
  /// interrupted cleanup can leave extra bytes, but cannot resurrect "旧的".
  Future<InpaintHistoryRemoval> clearInpaintHistory() => _enqueue(() async {
    final results = [...initialResults, for (final t in initialTrash) t.image];
    final inputs = await _historyInputs();
    final ids = {
      for (final input in inputs)
        if (input.cleaned != null) input.id,
      for (final result in results)
        if (result.hasInpaintComparison) result.id,
    };
    final added = ids.difference(_clearedInpaintIds);
    _clearedInpaintIds.addAll(ids);
    try {
      await _writeIndex(initialResults, initialSelectedId, seq);
    } catch (_) {
      _clearedInpaintIds.removeAll(added);
      rethrow;
    }
    initialResults = List.unmodifiable(initialResults.map(_normalizedResult));
    initialTrash = List.unmodifiable([
      for (final t in initialTrash) t.withImage(_normalizedResult(t.image)),
    ]);
    _idxTrash = initialTrash;
    if (_idxItems != null) {
      _idxItems = List.unmodifiable(_idxItems!.map(_normalizedResult));
    }
    final detached = <String>{};
    final failed = <String>{};
    for (final input in inputs) {
      if (input.cleaned == null) continue;
      try {
        await writeStringAtomic(input.file, jsonEncode(input.cleaned));
        detached.addAll(input.detachedRefs);
      } catch (error) {
        failed.add(input.id);
        logd('[gallery-store] 重绘历史清理失败 ${input.id}: $error');
      }
    }
    return InpaintHistoryRemoval(ids, detached, failed);
  });

  Future<Uint8List?> readImage(String id) async {
    try {
      final f = await _existingImage(id);
      if (f == null) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _writeThumb(
    String id,
    Uint8List bytes,
    FileStat source,
  ) async {
    final thumb = await _makeThumb(bytes);
    await _cacheThumb(id, thumb, source);
    return thumb.bytes;
  }

  Future<({Uint8List bytes, bool jpeg})> _makeThumb(Uint8List bytes) {
    final lane = _nextThumbLane++ % _thumbLanes.length;
    final work = _thumbLanes[lane].then((_) => makeThumb(bytes));
    // Release the decoding lane before waiting for the serialized disk writer.
    _thumbLanes[lane] = work.then<void>((_) {}, onError: (Object _) {});
    return work;
  }

  /// Called only on the write queue, so deletion cannot interleave with commits.
  Future<void> _cacheThumb(
    String id,
    ({Uint8List bytes, bool jpeg}) thumb,
    FileStat source,
  ) async {
    final current = await imageFileForPreview(id).stat();
    if (!_sameSource(current, source)) return;
    final format = thumb.jpeg ? 'jpg' : 'png';
    await writeBytesAtomic(
      thumb.jpeg ? _thumbJpg(id) : _thumbPng(id),
      thumb.bytes,
    );
    await writeStringAtomic(
      _thumbSourceFile(id),
      jsonEncode({
        'v': 3,
        'id': id,
        'format': format,
        'size': source.size,
        'modified': source.modified.microsecondsSinceEpoch,
        'thumbSha256': sha256.convert(thumb.bytes).toString(),
      }),
    );
    final obsolete = thumb.jpeg ? _thumbPng(id) : _thumbJpg(id);
    await _deleteRecoveryFiles(obsolete);
    if (await obsolete.exists()) await obsolete.delete();
  }

  bool _sameSource(FileStat a, FileStat b) =>
      a.type == FileSystemEntityType.file &&
      a.size == b.size &&
      a.modified == b.modified;

  /// A thumbnail can be replaced independently of its source/signature. Rebuild
  /// legacy caches once, then verify both the source and the cached pixels.
  Future<Uint8List?> readThumb(String id) => _thumbReads.putIfAbsent(
    id,
    () => _readThumb(id).whenComplete(() {
      _thumbReads.remove(id);
    }),
  );

  /// Read and close files before a queued Windows delete/clear can unlink them.
  Future<({FileStat source, Uint8List bytes, bool cached})?> _thumbInput(
    String id,
  ) async {
    final source = await imageFileForPreview(id).stat();
    if (source.type != FileSystemEntityType.file) return null;
    try {
      final signature = jsonDecode(await _thumbSourceFile(id).readAsString());
      if (signature is Map &&
          signature['v'] == 3 &&
          signature['id'] == id &&
          (signature['format'] == 'jpg' || signature['format'] == 'png') &&
          signature['size'] == source.size &&
          signature['modified'] == source.modified.microsecondsSinceEpoch) {
        final thumb =
            await (signature['format'] == 'jpg' ? _thumbJpg(id) : _thumbPng(id))
                .readAsBytes();
        if (signature['thumbSha256'] == sha256.convert(thumb).toString() &&
            _sameSource(await imageFileForPreview(id).stat(), source)) {
          return (source: source, bytes: thumb, cached: true);
        }
      }
    } catch (_) {}
    final bytes = await readImage(id);
    if (bytes == null) return null;
    return (source: source, bytes: bytes, cached: false);
  }

  Future<Uint8List?> _readThumb(String id) async {
    final input = await _enqueue(() => _thumbInput(id));
    if (input == null) return null;
    if (input.cached) return input.bytes;
    final source = input.source;
    try {
      final thumb = await _makeThumb(input.bytes);
      // Decoding runs outside the write queue; only a still-current original may
      // publish its cache. A delete/clear queued during decoding wins safely.
      await _enqueue(() => _cacheThumb(id, thumb, source));
      final current = await imageFileForPreview(id).stat();
      if (current.type == FileSystemEntityType.notFound) {
        await _enqueue(() async {
          if (await _existingImage(id) != null) return;
          for (final file in [
            _thumbPng(id),
            _thumbJpg(id),
            _thumbSourceFile(id),
          ]) {
            try {
              await _deleteRecoveryFiles(file);
              if (await file.exists()) await file.delete();
            } on FileSystemException {
              /* already removed */
            }
          }
        });
        return null;
      }
      return _sameSource(current, source)
          ? thumb.bytes
          : await _enqueue(() => readImage(id));
    } catch (_) {
      return _enqueue(() => readImage(id));
    }
  }

  // ---- 检索索引(search.json;可重建,容错语义与 index.json 不同) ----

  File get _searchFile => File('${_root.path}/search.json');

  /// 检索索引的版本。取材口径一变就得抬 —— 旧版里的文本是按旧口径抽的,留着就是
  /// 带着错答案不走;读到版本不对直接当空表,回填会按新口径把整库重扫一遍。
  ///
  ///   1 → 2:禁用的角色卡不再进索引(旧版把它们也收了,搜得到图里没画的东西,
  ///          按角色分组也跟着归错)。
  ///   2 → 3:多存来源(灵感库条目 id、角色卡名、折叠组名);换行算分隔。
  static const _searchVersion = 3;

  /// 增量日志:每行一条新增(`p`)或一批删除(`d`),读时在 search.json 之上重放;
  /// 攒多了在后台并回 search.json。文件名带版本,换版本后旧日志自然作废。
  File get _searchLog => File('${_root.path}/search.v$_searchVersion.log');

  Future<void> _searchChain = Future.value();
  int _searchLogLines = 0;
  int _searchBaseCount = 0;

  Future<void> _enqueueSearch(Future<void> Function() job) {
    final work = _searchChain.then((_) => job());
    return _searchChain = work.catchError((Object e) {
      logd('[gallery-store] 检索索引写入失败: $e');
    });
  }

  /// 检索索引读入(后台 isolate);空/坏/**版本不对** → 空表(回填会重扫快照补齐)。
  Future<Map<String, GallerySearchMeta>> readSearchIndex() async {
    final base = _searchFile.path;
    final log = _searchLog.path;
    await _searchChain;
    try {
      final r = await _readSearchInIsolate(base, log);
      _searchBaseCount = r.baseCount;
      _searchLogLines = r.logLines;
      return r.items;
    } catch (_) {
      return const {};
    }
  }

  /// 追加若干条(新图 / 回填一批)。
  void appendSearch(Map<String, GallerySearchMeta> puts) {
    if (puts.isEmpty) return;
    final b = StringBuffer();
    for (final e in puts.entries) {
      b
        ..write(jsonEncode({'p': e.key, ..._searchItemJson(e.value)}))
        ..write('\n');
    }
    _appendSearchLines(b.toString(), puts.length);
  }

  /// 追加一批删除。
  void appendSearchRemovals(List<String> ids) {
    if (ids.isEmpty) return;
    _appendSearchLines('${jsonEncode({'d': ids})}\n', 1);
  }

  void _appendSearchLines(String text, int n) {
    _searchLogLines += n;
    final log = _searchLog;
    _enqueueSearch(() async {
      await log.parent.create(recursive: true);
      await log.writeAsString(text, mode: FileMode.append);
    });
    if (_searchLogLines >= math.max(2000, _searchBaseCount)) {
      unawaited(compactSearch());
    }
  }

  /// 把日志并回 search.json(后台 isolate)。
  Future<void> compactSearch() {
    _searchLogLines = 0;
    final base = _searchFile.path;
    final log = _searchLog.path;
    return _enqueueSearch(() async {
      _searchBaseCount = await _compactSearchInIsolate(base, log);
    });
  }

  /// 清空检索索引。
  Future<void> clearSearch() {
    _searchLogLines = 0;
    _searchBaseCount = 0;
    final log = _searchLog;
    return _enqueueSearch(() async {
      await writeStringAtomic(
        _searchFile,
        jsonEncode({'v': _searchVersion, 'items': const <String, Object>{}}),
      );
      if (await log.exists()) await log.delete();
    });
  }

  /// 某张图参数快照的文件路径(检索索引回填在后台 isolate 里自己读)。
  String inputPathOf(String id) => _inputFile(id).path;

  /// 有参数快照的全部 id(检索索引回填清单)。
  Future<List<String>> listInputIds() async {
    final out = <String>[];
    try {
      await for (final ent in _inputsDir.list()) {
        if (ent is File && ent.path.endsWith('.json')) {
          final n = ent.uri.pathSegments.last;
          out.add(n.substring(0, n.length - 5));
        }
      }
    } catch (_) {}
    return out;
  }

  /// 参数快照的**原始 JSON**(检索索引轻量抽取用):只 jsonDecode,
  /// 不走 [readInput] 的 decodeGenerateState(那要解参考图 blob,重)。
  Future<Map<String, dynamic>?> readInputRaw(String id) async {
    try {
      final f = _inputFile(id);
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null;
    }
  }

  /// 参数快照(重新生成/重绘/导入用),blob 缺失字段按可用降级。
  /// [presetFallback]:快照里没记提示词预设的老图用哪一档(见 [decodeGenerateState])。
  Future<GenerateState?> readInput(String id, {String? presetFallback}) async {
    try {
      final f = _inputFile(id);
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['state'] is! Map<String, dynamic>) return null;
      final input = await decodeGenerateState(
        j['state'] as Map<String, dynamic>,
        _blobs,
        presetFallback: presetFallback,
      );
      return _clearedInpaintIds.contains(id) ||
              j['inpaintHistoryCleared'] == true
          ? input.copyWith(inpaint: null)
          : input;
    } catch (e) {
      logd('[gallery-store] 快照读取失败 $id: $e');
      return null;
    }
  }

  /// 全部参数快照引用的 blob 哈希(启动 GC 的引用清单)。
  Future<Set<String>> liveRefs({bool strict = false}) async {
    final out = <String>{};
    try {
      await for (final ent in _inputsDir.list()) {
        if (ent is! File || !ent.path.endsWith('.json')) continue;
        try {
          final j = jsonDecode(await ent.readAsString());
          if (j is! Map) throw const FormatException('历史参数引用记录无法读取');
          out.addAll(BlobStore.referencedHashes(j));
        } catch (_) {
          if (strict) rethrow;
        }
      }
    } catch (_) {
      if (strict && await _inputsDir.exists()) rethrow;
    }
    return out;
  }
}

Map<String, Object> _searchItemJson(GallerySearchMeta m) => {
  'm': m.model,
  't': m.text,
  if (m.ids.isNotEmpty) 'i': m.ids,
  if (m.cards.isNotEmpty) 'c': m.cards,
  if (m.folds.isNotEmpty) 'f': m.folds,
};

GallerySearchMeta? _searchMetaOf(Object? v) {
  if (v is! Map || v['t'] is! String) return null;
  List<String> strs(Object? x) => x is List
      ? [
          for (final y in x)
            if (y is String) y,
        ]
      : const [];
  return (
    model: (v['m'] as String?) ?? '',
    text: v['t'] as String,
    ids: strs(v['i']),
    cards: strs(v['c']),
    folds: strs(v['f']),
  );
}

Future<({Map<String, GallerySearchMeta> items, int baseCount, int logLines})>
_readSearchInIsolate(String base, String log) =>
    Isolate.run(() => _readSearch(base, log));

Future<int> _compactSearchInIsolate(String base, String log) =>
    Isolate.run(() => _compactSearch(base, log));

/// 后台 isolate:search.json(版本对得上才用)+ 日志重放。坏行跳过。
({Map<String, GallerySearchMeta> items, int baseCount, int logLines})
_readSearch(String basePath, String logPath) {
  final out = <String, GallerySearchMeta>{};
  try {
    final base = File(basePath);
    if (base.existsSync()) {
      final j = jsonDecode(base.readAsStringSync());
      if (j is Map &&
          j['v'] == GalleryStore._searchVersion &&
          j['items'] is Map) {
        for (final e in (j['items'] as Map).entries) {
          if (e.key is! String) continue;
          if (_searchMetaOf(e.value) case final m?) out[e.key as String] = m;
        }
      }
    }
  } catch (_) {}
  final baseCount = out.length;
  var lines = 0;
  try {
    final log = File(logPath);
    if (log.existsSync()) {
      for (final line in log.readAsLinesSync()) {
        if (line.isEmpty) continue;
        lines++;
        try {
          final j = jsonDecode(line);
          if (j is! Map) continue;
          if (j['p'] is String) {
            if (_searchMetaOf(j) case final m?) out[j['p'] as String] = m;
          } else if (j['d'] is List) {
            for (final id in j['d'] as List) {
              out.remove(id);
            }
          }
        } catch (_) {}
      }
    }
  } catch (_) {}
  return (items: out, baseCount: baseCount, logLines: lines);
}

/// 后台 isolate:日志并回 search.json,删日志。返回并完的条数。
int _compactSearch(String basePath, String logPath) {
  final items = _readSearch(basePath, logPath).items;
  final tmp = File('$basePath.tmp');
  tmp.parent.createSync(recursive: true);
  final payload = jsonEncode({
    'v': GalleryStore._searchVersion,
    'items': {for (final e in items.entries) e.key: _searchItemJson(e.value)},
  });
  tmp.writeAsStringSync(payload, flush: true);
  // Retry brief transient locks (e.g. antivirus scans on Windows) before falling back.
  var renamed = false;
  for (var attempt = 0; attempt < 3 && !renamed; attempt++) {
    try {
      tmp.renameSync(basePath);
      renamed = true;
    } on FileSystemException {
      if (attempt < 2) sleep(const Duration(milliseconds: 20));
    }
  }
  if (!renamed) {
    File(basePath).writeAsStringSync(payload, flush: true);
    try {
      tmp.deleteSync();
    } catch (_) {}
  }
  try {
    File(logPath).deleteSync();
  } catch (_) {}
  return items.length;
}

Future<Object?> _readIndexInBackground(String path) =>
    Isolate.run(() => jsonDecode(File(path).readAsStringSync()));
Future<String> _encodeIndexInBackground(Map<String, Object?> index) =>
    Isolate.run(() => jsonEncode(index));
