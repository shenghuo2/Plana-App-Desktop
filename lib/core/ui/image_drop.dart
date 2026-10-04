import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../platform/clipboard_image.dart';
import '../platform/desktop.dart';
import '../util/image_ops.dart';
import '../util/image_pick.dart';

/// One drag has one payload and one recipient. Bytes are read only on drop.
class ImageDropPayload {
  ImageDropPayload.files(List<String> paths)
    : paths = List.unmodifiable(paths),
      imageId = null,
      source = null,
      _load = null;

  ImageDropPayload.image({
    required String name,
    required Future<Uint8List?> Function() load,
    this.imageId,
    this.source,
  }) : paths = const [],
       _load = (() async {
         final bytes = await load();
         if (bytes == null || bytes.isEmpty) {
           throw const FormatException('图片已删除或尚未就绪');
         }
         return [PickedImage(name, bytes)];
       });

  final List<String> paths;
  final String? imageId;
  final String? source;
  final Future<List<PickedImage>> Function()? _load;
  int get count => _load == null ? paths.length : 1;

  Future<List<PickedImage>> read() async {
    if (count == 0 || count > 64) {
      throw const FormatException('一次最多拖入 64 张图片');
    }
    final files = <PickedImage>[];
    if (_load != null) {
      files.addAll(await _load());
    } else {
      var total = 0;
      for (final path in paths) {
        final file = File(path);
        final size = await file.length();
        total += size;
        if (size > 64 * 1024 * 1024 || total > 256 * 1024 * 1024) {
          throw const FormatException('图片过大：单张最多 64 MB，一次最多 256 MB');
        }
        files.add(PickedImage(p.basename(path), await file.readAsBytes()));
      }
    }
    // Validate the entire batch before any recipient changes its state.
    for (final file in files) {
      try {
        final (width, height) = await decodeImageSize(file.bytes);
        if (width <= 0 || height <= 0) throw const FormatException();
      } catch (_) {
        throw FormatException('无法读取图片：${file.name}');
      }
    }
    return files;
  }
}

typedef ImageDropCallback =
    Future<void> Function(List<PickedImage> images, ImageDropPayload payload);

/// Flutter's drag target arbitration also selects the innermost native target.
/// Hit testing (rather than rectangle registration) excludes obscured/offstage
/// pages and prevents drops through modal barriers.
class ImageDropRegion extends ConsumerStatefulWidget {
  const ImageDropRegion({
    super.key,
    required this.label,
    required this.onDrop,
    required this.child,
    this.multiple = false,
    this.enabled = true,
    this.acceptInternal = true,
    this.acceptPaste = false,
    this.accept,
  });

  final String label;
  final ImageDropCallback onDrop;
  final Widget child;
  final bool multiple;
  final bool enabled;
  final bool acceptInternal;

  /// 桌面端 ⌘/Ctrl+V 也能把剪贴板里的图送进这块(焦点在这块里就行)。
  ///
  /// 落点和拖入同一套仲裁:焦点在哪块里,图就归哪块,**最里面那块说了算**。
  /// 剪贴板里没图、或者同时躺着能用的文本(用户多半想粘文字),一律放手给系统
  /// 原本的文本粘贴 —— 这个动作一次都不该被吞掉。
  final bool acceptPaste;

  final bool Function(ImageDropPayload)? accept;

  @override
  ConsumerState<ImageDropRegion> createState() => _ImageDropRegionState();
}

class _ImageDropRegionState extends ConsumerState<ImageDropRegion> {
  bool _externalHover = false;
  bool _busy = false;
  bool get _enabled => widget.enabled && !_busy;
  bool _accepts(ImageDropPayload payload) =>
      _enabled &&
      (widget.acceptInternal || payload.paths.isNotEmpty) &&
      (widget.accept?.call(payload) ?? true);

  void _hover(bool value) {
    if (mounted && value != _externalHover) {
      setState(() => _externalHover = value);
    }
  }

  Future<void> _receive(ImageDropPayload payload) async {
    if (!_accepts(payload)) return;
    setState(() => _busy = true);
    try {
      if (!widget.multiple && payload.count > 1) {
        throw const FormatException('此处一次接收一张图片，请拖入单张图片');
      }
      final images = await payload.read();
      if (mounted) await widget.onDrop(images, payload);
    } catch (error) {
      if (mounted) {
        final message = error is FormatException
            ? error.message
            : '图片导入失败，请检查文件是否可读';
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// ⌘/Ctrl+V 落到这块上。
  ///
  /// **先问剪贴板,再决定吞不吞**:这一下是同步认领的(剪贴板是异步读的,等读完
  /// 再决定就轮不到自己了),所以读不到图时必须把文本粘贴原样补回去 —— 补的是
  /// [PasteTextIntent],走的是当前焦点自己那套粘贴,行为与没拦过一模一样。
  Future<void> _paste() async {
    final image = await DesktopClipboard.readImage();
    if (!mounted) return;
    if (image == null || !_enabled) {
      await _pasteText();
      return;
    }
    final payload = ImageDropPayload.image(
      // 落到各块区域里就叫这个名字(附件列表、导入面板首行都会显示它),
      // 和上传时的默认名保持一致。
      name: image.name ?? kClipboardImageName,
      load: () async => image.bytes,
    );
    if (!_accepts(payload)) {
      await _pasteText();
      return;
    }
    await _receive(payload);
  }

  Future<void> _pasteText() async {
    final target = FocusManager.instance.primaryFocus?.context;
    if (target == null || !target.mounted) return;
    Actions.maybeInvoke(
      target,
      const PasteTextIntent(SelectionChangedCause.keyboard),
    );
  }

  /// 桌面端才拦 ⌘/Ctrl+V:移动端这一下没有键盘,拦了只会挡住系统自己的粘贴。
  ///
  /// 走 [desktopModeProvider] 而不是直接看平台:这张开关在测试里能换,
  /// 桌面那套分支才跑得起来(和全 app 其余桌面分支同一个判据)。
  bool get _pasteEnabled =>
      widget.acceptPaste && ref.watch(desktopModeProvider);

  @override
  Widget build(BuildContext context) => MetaData(
    metaData: this,
    behavior: HitTestBehavior.translucent,
    child: _pasteEnabled
        ? Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.keyV, meta: true):
                  _PasteImageIntent(),
              SingleActivator(LogicalKeyboardKey.keyV, control: true):
                  _PasteImageIntent(),
            },
            child: Actions(
              actions: {
                _PasteImageIntent: CallbackAction<_PasteImageIntent>(
                  onInvoke: (_) {
                    unawaited(_paste());
                    return null;
                  },
                ),
              },
              child: _target(context),
            ),
          )
        : _target(context),
  );

  Widget _target(BuildContext context) => DragTarget<ImageDropPayload>(
    onWillAcceptWithDetails: (details) => _accepts(details.data),
    onAcceptWithDetails: (details) => unawaited(_receive(details.data)),
    builder: (context, candidates, rejected) {
      final hover = _enabled && (_externalHover || candidates.isNotEmpty);
      return Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (hover)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: .08),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Material(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Text('松开以${widget.label}'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// 「把剪贴板里的图贴到这块里」。内容由 [_ImageDropRegionState._paste] 定,
/// 这里只是个认领键盘事件的由头。
class _PasteImageIntent extends Intent {
  const _PasteImageIntent();
}

class DesktopImageDropHost extends StatefulWidget {
  const DesktopImageDropHost({super.key, required this.child});
  final Widget child;
  static const channel = MethodChannel('plana/image_drop');

  @override
  State<DesktopImageDropHost> createState() => _DesktopImageDropHostState();
}

class _DesktopImageDropHostState extends State<DesktopImageDropHost> {
  _ImageDropRegionState? _hovered;
  bool _receiving = false;

  @override
  void initState() {
    super.initState();
    DesktopImageDropHost.channel.setMethodCallHandler(_nativeEvent);
  }

  _ImageDropRegionState? _at(Offset position) {
    final hit = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      hit,
      position,
      View.of(context).viewId,
    );
    for (final entry in hit.path) {
      final target = entry.target;
      if (target is RenderMetaData &&
          target.metaData is _ImageDropRegionState) {
        final region = target.metaData as _ImageDropRegionState;
        // A disabled local receiver blocks the fallback behind it too.
        return region._enabled ? region : null;
      }
    }
    return null;
  }

  Future<void> _nativeEvent(MethodCall call) async {
    if (!mounted) return;
    if (call.method == 'leave') {
      _hovered?._hover(false);
      _hovered = null;
      return;
    }
    if (call.method != 'over' && call.method != 'drop') return;
    final args = Map<Object?, Object?>.from(call.arguments as Map);
    final scale = View.of(context).devicePixelRatio;
    final point = Offset(
      (args['x'] as num).toDouble() / scale,
      (args['y'] as num).toDouble() / scale,
    );
    final target = _receiving ? null : _at(point);
    if (_hovered != target) {
      _hovered?._hover(false);
      _hovered = target;
      target?._hover(true);
    }
    if (call.method == 'drop') {
      _hovered?._hover(false);
      _hovered = null;
      if (target == null) return;
      final paths = (args['paths'] as List).cast<String>();
      _receiving = true;
      try {
        await target._receive(ImageDropPayload.files(paths));
      } finally {
        _receiving = false;
      }
    }
  }

  @override
  void dispose() {
    DesktopImageDropHost.channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Mouse drags move images; touch keeps the child's existing gestures.
class DesktopImageDraggable extends Draggable<ImageDropPayload> {
  const DesktopImageDraggable({
    super.key,
    required ImageDropPayload super.data,
    required super.child,
    required super.feedback,
    super.onDragStarted,
    super.onDragEnd,
    super.maxSimultaneousDrags = 1,
  }) : super(dragAnchorStrategy: pointerDragAnchorStrategy);

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) => _ImageMouseDragRecognizer()..onStart = onStart;
}

class _ImageMouseDragRecognizer extends ImmediateMultiDragGestureRecognizer {
  _ImageMouseDragRecognizer()
    : super(
        supportedDevices: {PointerDeviceKind.mouse},
        allowedButtonsFilter: (buttons) => buttons == kPrimaryMouseButton,
      );

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _ImageMouseDragState(event.position, event.kind, gestureSettings);
}

class _ImageMouseDragState extends MultiDragPointerState {
  _ImageMouseDragState(
    super.initialPosition,
    super.kind,
    super.gestureSettings,
  );

  @override
  void checkForResolutionAfterMove() {
    if (pendingDelta!.distanceSquared > 16) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) =>
      starter(initialPosition);
}
