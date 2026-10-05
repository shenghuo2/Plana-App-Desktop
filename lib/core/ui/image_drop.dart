import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

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
  ImageDropPayload.files(List<String> paths, {this.source})
    : paths = List.unmodifiable(paths),
      imageId = null,
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

  factory ImageDropPayload.clipboard(Map<Object?, Object?> arguments) {
    final paths = (arguments['paths'] as List?)?.cast<String>() ?? const [];
    final error = arguments['error'] as String? ?? '';
    if (error.isEmpty && paths.isNotEmpty) {
      return ImageDropPayload.files(paths, source: 'clipboard');
    }
    return ImageDropPayload.image(
      name: 'clipboard.png',
      source: 'clipboard',
      load: () async {
        if (error.isNotEmpty) {
          throw FormatException(switch (error) {
            'clipboard_busy' => '剪贴板暂时被占用，请重试粘贴',
            'too_many_images' => '一次最多粘贴 64 张图片',
            _ => '无法读取剪贴板图片，请重新复制；单张最多 64 MB',
          });
        }
        final bytes = arguments['bytes'] as Uint8List?;
        if (bytes == null || bytes.isEmpty) {
          throw const FormatException('剪贴板中没有可读取的图片');
        }
        // A DIB gains a small BMP header in the native reader.
        if (bytes.length > 64 * 1024 * 1024 + 14) {
          throw const FormatException('剪贴板图片过大：单张最多 64 MB');
        }
        if (arguments['bitmap'] != true) return bytes;
        final codec = await ui.instantiateImageCodec(bytes);
        try {
          final frame = await codec.getNextFrame();
          try {
            final png = await frame.image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            return png?.buffer.asUint8List();
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
      },
    );
  }

  final List<String> paths;
  final String? imageId;
  final String? source;
  final Future<List<PickedImage>> Function()? _load;
  int get count => _load == null ? paths.length : 1;

  Future<List<PickedImage>> read() async {
    if (count == 0 || count > 64) {
      throw const FormatException('一次最多导入 64 张图片');
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
    var totalBytes = 0;
    for (final file in files) {
      totalBytes += file.bytes.length;
      if (file.bytes.length > 64 * 1024 * 1024 ||
          totalBytes > 256 * 1024 * 1024) {
        throw const FormatException('图片过大：单张最多 64 MB，一次最多 256 MB');
      }
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
class ImageDropRegion extends StatefulWidget {
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

  /// 这块接收区参不参与桌面端的 ⌘/Ctrl+V 粘贴分发。
  ///
  /// 落点由 [DesktopImageDropHost] 统一裁:**鼠标底下**那块优先,鼠标没落在任何
  /// 一块上时退回焦点所在的那块 —— 鼠标点过的位置就是你正在看的地方,比键盘焦点
  /// 更接近意图(点过提示词框之后鼠标停在哪张卡上,图就该进哪张卡)。
  ///
  /// 剪贴板里没图、或者同时躺着能用的文本(用户多半想粘文字),一律放手给系统
  /// 原本的文本粘贴 —— 这个动作一次都不该被吞掉。
  final bool acceptPaste;

  final bool Function(ImageDropPayload)? accept;

  @override
  State<ImageDropRegion> createState() => _ImageDropRegionState();
}

class _ImageDropRegionState extends State<ImageDropRegion> {
  _DesktopImageDropHostState? _host;
  bool _externalHover = false;
  bool _busy = false;
  bool get _enabled => widget.enabled && !_busy;
  bool _accepts(ImageDropPayload payload) =>
      _enabled &&
      // 剪贴板来的图没有 paths,`acceptInternal: false` 那道闸对它不成立 ——
      // 否则「应用级导入区收外部拖入、但不收应用内拖拽」这种配置会把 ⌘V 也一起
      // 挡在外面(它本来就没打算管那条路)。
      (widget.acceptInternal ||
          payload.paths.isNotEmpty ||
          payload.source == kClipboardSource) &&
      (widget.accept?.call(payload) ?? true);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final host = context.findAncestorStateOfType<_DesktopImageDropHostState>();
    if (_host != host) {
      _host?._regions.remove(this);
      _host = host;
      _host?._regions.add(this);
    }
  }

  @override
  void dispose() {
    _host?._regions.remove(this);
    super.dispose();
  }

  void _hover(bool value) {
    if (mounted && value != _externalHover) {
      setState(() => _externalHover = value);
    }
  }

  Future<void> _receive(
    ImageDropPayload payload, {
    bool Function()? stillVisible,
  }) async {
    if (!_accepts(payload)) return;
    setState(() => _busy = true);
    try {
      if (!widget.multiple && payload.count > 1) {
        throw const FormatException('此处一次接收一张图片，请选择单张图片');
      }
      final images = await payload.read();
      if (mounted && widget.enabled && (stillVisible?.call() ?? true)) {
        await widget.onDrop(images, payload);
      }
    } catch (error) {
      if (mounted && (stillVisible?.call() ?? true)) {
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

  /// 把剪贴板里的图贴到这块里。由 [DesktopImageDropHost] 按鼠标/焦点选中后调用。
  ///
  /// 返回 false = 这块不收(或正忙),调用方据此把这一下还给文本粘贴。
  Future<bool> pasteFromClipboard() async {
    final image = await DesktopClipboard.readImage();
    if (!mounted || image == null || !_enabled) return false;
    final payload = ImageDropPayload.image(
      // 落到各块区域里就叫这个名字(附件列表、导入面板首行都会显示它),
      // 和上传时的默认名保持一致。
      name: image.name ?? kClipboardImageName,
      source: kClipboardSource,
      load: () async => image.bytes,
    );
    if (!_accepts(payload)) return false;
    await _receive(payload);
    return true;
  }

  @override
  Widget build(BuildContext context) => MetaData(
    metaData: this,
    behavior: HitTestBehavior.translucent,
    child: _target(context),
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

/// 剪贴板来的图的来源标记:接收区据此把它和「应用内拖拽」区分开
/// ([ImageDropPayload.source] 的其余取值是 `canvas` / `history`)。
const kClipboardSource = 'clipboard';

/// 把一块接收区的**粘贴范围**扩到它自己盖不到的地方。
///
/// 工作台右栏就是这个情形:助手页占着标签栏底下那一块,而标签栏在它外面 ——
/// 鼠标停在「AI 助手 / 灵感」那一行上按 ⌘V,本该贴进助手,却因为光标底下没有
/// 接收区而落空。把标签栏包进这个 proxy 指回助手那块接收区,这一行才归它管。
///
/// **只影响粘贴**:拖入仍然按最里层的接收区裁决,标签栏不会变成拖放目标。
class ImagePasteProxy extends StatelessWidget {
  const ImagePasteProxy({
    super.key,
    required this.target,
    required this.child,
    this.enabled = true,
  });

  /// 指向那块接收区的 [GlobalKey](`ImageDropRegion` 上的)。
  final GlobalKey target;

  /// 这块代理现在算不算数 —— 比如助手不在前台时,这一行不该把粘贴截走。
  final bool enabled;

  final Widget child;
  @override
  Widget build(BuildContext context) => MetaData(
    metaData: this,
    behavior: HitTestBehavior.translucent,
    child: child,
  );
}

/// 「把剪贴板里的图贴到鼠标/焦点所在的那块接收区」。派发在 [DesktopImageDropHost]。
class _PasteImageIntent extends Intent {
  const _PasteImageIntent();
}

class DesktopImageDropHost extends ConsumerStatefulWidget {  const DesktopImageDropHost({super.key, required this.child});
  final Widget child;
  static const channel = MethodChannel('plana/image_drop');

  @override
  ConsumerState<DesktopImageDropHost> createState() =>
      _DesktopImageDropHostState();
}

class _DesktopImageDropHostState extends ConsumerState<DesktopImageDropHost> {
  _ImageDropRegionState? _hovered;
  bool _receiving = false;
  final _regions = <_ImageDropRegionState>{};

  /// 鼠标在窗口里的位置(逻辑像素),没进过窗口就是 null。
  ///
  /// 自己记而不是问 Flutter:引擎那层「最后一次指针事件」不会随窗口一起清 ——
  /// 鼠标移出去之后它还停在边界值上,拿它当「鼠标底下是哪块」会把窗口边缘那张
  /// 卡一直当成悬停目标。这里用 MouseRegion 的进出事件把这笔账算准。
  Offset? _pointer;

  /// 粘贴那一趟正在读剪贴板,挡住连按。
  bool _pasting = false;

  @override
  void initState() {
    super.initState();
    DesktopImageDropHost.channel.setMethodCallHandler(_nativeEvent);
  }

  HitTestResult _hitAt(Offset position) {    final hit = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      hit,
      position,
      View.of(context).viewId,
    );
    return hit;
  }

  _ImageDropRegionState? _at(Offset position) {
    for (final entry in _hitAt(position).path) {      final target = entry.target;
      if (target is RenderMetaData &&
          target.metaData is _ImageDropRegionState) {
        final region = target.metaData as _ImageDropRegionState;
        // A disabled local receiver blocks the fallback behind it too.
        return region._enabled ? region : null;
      }
    }
    return null;
  }

  /// 贴图落点:**鼠标底下**那块优先,鼠标不在任何一块上时才看焦点。
  ///
  /// 为什么鼠标优先:用户刚点过提示词框(焦点在那边),接着把鼠标挪到图生图卡片上
  /// 按 ⌘V —— 他要的是「贴进我正看着的这张卡」。只看焦点的话这一下哪儿都不去,
  /// 白按。焦点兜底留着,是为了鼠标不在窗口里(纯键盘操作、或刚切回来的窗口)时
  /// 还能贴到正在编辑的那块上。
  /// [at] 给 Windows 的 `paste` 事件用:那个位置是**按下那一刻**原生报上来的,
  /// 比 [_pointer](最近一次悬停)更准 —— 用户可能刚把光标挪开就按了键。
  _ImageDropRegionState? _pasteTarget({Offset? at}) {
    final point = at ?? _pointer;
    if (point != null) {
      final under = _pasteRegionAt(point);
      // 鼠标底下明确摆着一块接收区时,成不成都是它说了算:它正忙就这一下不动,
      // 不越过它去贴用户没在看着的下一层 —— 贴哪儿和看着哪儿对不上比不贴更糟。
      if (under != null) return under._enabled ? under : null;
    }
    return _focusedPasteRegion();
  }

  /// 命中路径上第一块**参与粘贴**的接收区,或一个指回接收区的 [ImagePasteProxy]。
  ///
  /// 不参与粘贴的区域([ImageDropRegion.acceptPaste] 为 false)对粘贴来说等于
  /// 不存在:既不接收,也不挡住后面那些(素材库这类页面收不了图,鼠标停在上头
  /// 时该落到它外面那层通用导入区,而不是什么都不发生)。
  _ImageDropRegionState? _pasteRegionAt(Offset position) {
    for (final entry in _hitAt(position).path) {
      final target = entry.target;
      if (target is! RenderMetaData) continue;
      final data = target.metaData;
      if (data is _ImageDropRegionState) {
        if (data.widget.acceptPaste) return data;
        continue;
      }
      if (data is ImagePasteProxy && data.enabled) {
        return data.target.currentState as _ImageDropRegionState?;
      }
    }
    return null;
  }

  /// 焦点所在的那块粘贴接收区 —— 只认最近的,再往外的层不顶替。
  _ImageDropRegionState? _focusedPasteRegion() {
    _ImageDropRegionState? candidate;
    FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
      element,
    ) {
      if (element is StatefulElement &&
          element.state is _ImageDropRegionState) {
        final region = element.state as _ImageDropRegionState;
        if (region.widget.acceptPaste) {
          candidate = region;
          return false; // 最近那块说了算
        }
      }
      return true;
    });
    if (candidate == null || !candidate!._enabled || !_visible(candidate!)) {
      return null;
    }
    return candidate;
  }

  /// 这块接收区现在**真的露在界面上**吗。
  ///
  /// 判据是「在它中心打一发命中测试,能不能打到它」——**不是**「它在树里有尺寸」。
  /// 保活的页面(工作台右栏是 IndexedStack、助手页切走了也还在树里)照样有尺寸,
  /// 用后者会把一次 ⌘V 贴进一个用户正眼都看不到的页面。命中测试走的就是绘制
  /// 那份可见性:IndexedStack 只命中当前那一页,被挡住的、离屏的一律打不到。
  bool _visible(_ImageDropRegionState region) {
    if (!region.mounted || ModalRoute.of(region.context)?.isCurrent == false) {
      return false;
    }
    final box = region.context.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        box.size.isEmpty) {
      return false;
    }
    final center = box.localToGlobal(box.size.center(Offset.zero));
    for (final entry in _hitAt(center).path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData == region) return true;
    }
    return false;
  }

  /// ⌘/Ctrl+V:先当作「贴图」试一遍,不成再把文本粘贴原样还回去。
  ///
  /// **一次都不吞**:剪贴板里没图、没有接收区、那块不收或正忙 —— 每一条都落到
  /// [_pasteText],行为与没拦过这一下完全一致。
  Future<void> _paste() async {
    if (_pasting) return;
    _pasting = true;
    try {
      final target = _pasteTarget();
      if (target == null || !target.mounted) {
        await _pasteText();
        return;
      }
      final handled = await target.pasteFromClipboard();
      if (!handled) await _pasteText();
    } finally {
      _pasting = false;
    }
  }

  /// 把这一下还给当前的文本粘贴。焦点还在这块接收区里(用户多半刚点过输入框),
  /// 走的就是系统那套 PasteTextIntent —— 和没拦过一模一样。
  Future<void> _pasteText() async {
    final target = FocusManager.instance.primaryFocus?.context;
    if (target == null || !target.mounted) return;
    Actions.maybeInvoke(
      target,
      const PasteTextIntent(SelectionChangedCause.keyboard),
    );
  }
  Future<void> _nativeEvent(MethodCall call) async {
    if (!mounted) return;
    if (call.method == 'leave') {
      _hovered?._hover(false);
      _hovered = null;
      return;
    }
    if (call.method != 'over' &&
        call.method != 'drop' &&
        call.method != 'paste') {
      return;
    }
    final args = Map<Object?, Object?>.from(call.arguments as Map);
    final scale = View.of(context).devicePixelRatio;
    final point = Offset(
      (args['x'] as num).toDouble() / scale,
      (args['y'] as num).toDouble() / scale,
    );
    if (call.method == 'paste') {
      // Windows:密钥在原生侧就拦下了(见 windows/runner/image_clipboard.cpp),
      // 图和位置一起送上来。落点和 macOS 那条路是**同一个** [_pasteTarget]:
      // 光标优先、焦点兜底。原图在原生读好了,所以不走剪贴板再问一遍。
      final target = _pasteTarget(at: point);
      if (target == null || !target.mounted) return;
      await target._receive(ImageDropPayload.clipboard(args));
      return;
    }
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

  /// 只有桌面端才拦 ⌘/Ctrl+V:移动端没有这一步。
  ///
  /// 走 [desktopModeProvider] 而不是直接看平台:这张开关在测试里能换,桌面那套
  /// 分支才跑得起来(全 app 其余桌面分支同一个判据)。
  @override
  Widget build(BuildContext context) {
    final child = MouseRegion(
      // opaque:整窗都要收到进出事件,不然鼠标一进工具栏就断了追踪。
      opaque: true,
      onEnter: (event) => _pointer = event.position,
      onHover: (event) => _pointer = event.position,
      onExit: (_) => _pointer = null,
      child: widget.child,
    );
    if (!ref.watch(desktopModeProvider)) return child;
    return Shortcuts(
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
        child: child,
      ),
    );
  }
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
