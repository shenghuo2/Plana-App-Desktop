import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/desktop.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/desktop_popover.dart';
import '../../../core/util/haptics.dart';
import '../generate_state.dart';
import '../models.dart';
import '../res_rules.dart';
import 'common.dart';

const _customTab = '自定义';

// 画布满格对应的真实像素(两轴一致);矩形左上角锚定,右下角拖拽定 W/H。
final double _axisMax = kMaxDim.toDouble();

// 可视化配色(在浅色画布上可读,语义同 web:绿=免费线,红=上限线)。
const _vizFree = FixedSemantic.ok;
const _vizOver = FixedSemantic.danger;

// 可吸附的两条等像素线:免费线 / 上限线。
const _pixelLines = [kFreePixelThreshold, kMaxTotalPixels];

// 吸附圈(画布 dp):离线 8 以内吸上,拉出 12 才松开 —— 滞回,
// 免得手指停在圈边时来回跳、连着振。
const _snapInDp = 8.0;
const _snapOutDp = 12.0;

/// 分辨率 Sheet:预设三档(小图免费/大图/壁纸)+ 自定义档(拖拽画布)
/// + 统一档位状态条(MP·比例·免费/付费/超限)+ 确认生效。数值/交互对齐 web 桌面端。
Future<void> showResolutionSheet(BuildContext context) {
  if (ProviderScope.containerOf(
    context,
    listen: false,
  ).read(desktopModeProvider)) {
    return showDesktopPopover<void>(
      context,
      width: 340,
      maxHeight: 640,
      builder: (_) => const _ResolutionSheet(desktop: true),
    );
  }
  return showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => const _ResolutionSheet(),
  );
}

class _ResolutionSheet extends ConsumerStatefulWidget {
  const _ResolutionSheet({this.desktop = false});
  final bool desktop;

  @override
  ConsumerState<_ResolutionSheet> createState() => _ResolutionSheetState();
}

class _ResolutionSheetState extends ConsumerState<_ResolutionSheet> {
  late String tab;

  /// 最后停留的预设页签:自定义档下预设行仍要渲染(CrossFade 常驻两子树)。
  late String lastPresetTab;
  late SizePreset selected;
  late int customW;
  late int customH;
  late final TextEditingController _width;
  late final TextEditingController _height;
  String? _widthError, _heightError;

  @override
  void initState() {
    super.initState();
    final p = ref.read(generateProvider).params;
    tab = sizeTabs.keys.first;
    selected = sizeTabs[tab]!.first;
    customW = snapDim(p.width);
    customH = snapDim(p.height);
    _width = TextEditingController(text: '$customW');
    _height = TextEditingController(text: '$customH');
    var matched = false;
    for (final entry in sizeTabs.entries) {
      for (final preset in entry.value) {
        if (preset.width == p.width && preset.height == p.height) {
          tab = entry.key;
          selected = preset;
          matched = true;
        }
      }
    }
    // 当前尺寸不是任何预设(如图生图按底图设的怪尺寸)→ 落在自定义档回显。
    if (!matched) tab = _customTab;
    lastPresetTab = _isCustom ? sizeTabs.keys.first : tab;
  }

  bool get _isCustom => tab == _customTab;
  int get _effW => _isCustom ? customW : selected.width;
  int get _effH => _isCustom ? customH : selected.height;

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    super.dispose();
  }

  void _setCustom(int w, int h) => setState(() {
    customW = w.clamp(kMinDim, kMaxDim);
    customH = h.clamp(kMinDim, kMaxDim);
    _width.text = '$customW';
    _height.text = '$customH';
    _widthError = _heightError = null;
  });

  // Parse a decimal as a number before truncating it; filtering out the dot
  // would silently turn a pasted "832.5" into "8325".
  int? _dimension(String text) {
    final value = double.tryParse(text.trim());
    if (value == null || !value.isFinite) return null;
    final integer = value.toInt();
    if (integer < kMinDim || integer > kMaxDim) return null;
    return snapDim(integer).clamp(kMinDim, kMaxDim);
  }

  bool _commitDimensions({bool normalize = true}) {
    final w = _dimension(_width.text), h = _dimension(_height.text);
    setState(() {
      _widthError = w == null ? '$kMinDim ～ $kMaxDim' : null;
      _heightError = h == null ? '$kMinDim ～ $kMaxDim' : null;
      if (w != null) {
        customW = w;
        if (normalize) _width.text = '$w';
      }
      if (h != null) {
        customH = h;
        if (normalize) _height.text = '$h';
      }
    });
    return w != null && h != null;
  }

  Widget _dimensionInput({required bool width}) => SizedBox(
    width: widget.desktop ? 96 : 108,
    child: TextField(
      key: ValueKey(width ? 'resolution-width' : 'resolution-height'),
      controller: width ? _width : _height,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textInputAction: TextInputAction.done,
      style: mono(context, size: 16).copyWith(fontWeight: FontWeight.w700),
      decoration: InputDecoration(
        labelText: width ? '宽' : '高',
        suffixText: 'px',
        isDense: true,
        contentPadding: widget.desktop
            ? const EdgeInsets.symmetric(horizontal: 10, vertical: 12)
            : null,
        errorText: width ? _widthError : _heightError,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => _commitDimensions(normalize: false),
      onSubmitted: (_) => _commitDimensions(),
      onTapOutside: (_) {
        _commitDimensions();
        FocusManager.instance.primaryFocus?.unfocus();
      },
    ),
  );

  void _apply() {
    if (_isCustom && !_commitDimensions()) return;
    if (classifyPixels(_effW, _effH) == PixelTier.over) return;
    ref.read(generateProvider.notifier).setSize(_effW, _effH);
    Navigator.pop(context);
  }

  Widget _desktopPanel() {
    final scheme = context.scheme;
    final over = classifyPixels(_effW, _effH) == PixelTier.over;
    final canApply =
        !over && (!_isCustom || (_widthError == null && _heightError == null));
    return SingleChildScrollView(
      key: const ValueKey('resolution-panel'),
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '选择比例',
                  style: context.texts.titleMedium!.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
          const Divider(height: 18),
          Row(
            children: [
              for (final t in [...sizeTabs.keys, _customTab])
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: TextButton(
                      onPressed: () => setState(() {
                        tab = t;
                        if (!_isCustom) {
                          lastPresetTab = t;
                          selected = sizeTabs[t]!.first;
                        }
                      }),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        minimumSize: const Size(0, 34),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        backgroundColor: tab == t
                            ? scheme.primaryContainer
                            : null,
                        foregroundColor: tab == t
                            ? scheme.onPrimaryContainer
                            : scheme.onSurfaceVariant,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: Text(t),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (_isCustom)
            _CanvasEditor(
              width: customW,
              height: customH,
              onChanged: _setCustom,
              dimensions: const SizedBox.shrink(),
              maxSide: 280,
            )
          else
            Row(
              children: [
                for (final p in sizeTabs[tab]!) ...[
                  Expanded(
                    child: _PresetCard(
                      preset: p,
                      selected: p == selected,
                      onTap: () => setState(() => selected = p),
                    ),
                  ),
                  if (p != sizeTabs[tab]!.last) const SizedBox(width: 6),
                ],
              ],
            ),
          const Divider(height: 24),
          Tooltip(
            message: '免费档（≤1.05 MP）：Opus ≤28 步单张免费；更大按张扣 Anlas。',
            child: _StatusStrip(width: _effW, height: _effH),
          ),
          const SizedBox(height: 16),
          if (_isCustom) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _dimensionInput(width: true),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  child: _SwapBtn(
                    onTap: () {
                      if (_commitDimensions()) _setCustom(customH, customW);
                    },
                  ),
                ),
                _dimensionInput(width: false),
                const Spacer(),
                Tooltip(
                  message: over ? '超出像素上限' : '确认 · $_effW×$_effH',
                  child: FilledButton(
                    key: const ValueKey('resolution-confirm'),
                    onPressed: canApply ? _apply : null,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(40, 42),
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Icon(Icons.check, size: 20),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              over ? '超出像素上限' : '小数取整数部分，尺寸自动对齐 64 像素。',
              style: context.texts.bodySmall!.copyWith(
                fontSize: 11,
                color: over ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ] else
            FilledButton(
              key: const ValueKey('resolution-confirm'),
              onPressed: canApply ? _apply : null,
              child: Text('确认 · $_effW×$_effH'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.desktop) return _desktopPanel();
    final scheme = context.scheme;
    final over = classifyPixels(_effW, _effH) == PixelTier.over;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, widget.desktop ? 12 : 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '分辨率',
                style: context.texts.titleMedium!.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const HelpDot(Help.resolution, size: 30, iconSize: 18),
              const Spacer(),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, size: 20),
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: [
              for (final t in sizeTabs.keys)
                ButtonSegment(value: t, label: Text(t)),
              const ButtonSegment(value: _customTab, label: Text(_customTab)),
            ],
            selected: {tab},
            onSelectionChanged: (s) => setState(() {
              tab = s.first;
              if (!_isCustom) {
                lastPresetTab = tab;
                selected = sizeTabs[tab]!.first;
              }
            }),
            showSelectedIcon: false,
          ),
          const SizedBox(height: 14),
          // CrossFade 同步动画高度与透明度:预设行(矮)↔ 画布(高)切换不跳变
          AnimatedCrossFade(
            duration: Motion.medium,
            sizeCurve: Motion.emphasized,
            crossFadeState: _isCustom
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: Row(
              children: [
                for (final p in sizeTabs[lastPresetTab]!) ...[
                  Expanded(
                    child: _PresetCard(
                      preset: p,
                      selected: selected == p,
                      onTap: () => setState(() => selected = p),
                    ),
                  ),
                  if (p != sizeTabs[lastPresetTab]!.last)
                    const SizedBox(width: 10),
                ],
              ],
            ),
            secondChild: _CanvasEditor(
              width: customW,
              height: customH,
              onChanged: _setCustom,
              dimensions: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _dimensionInput(width: true),
                  const SizedBox(width: 8),
                  _SwapBtn(
                    onTap: () {
                      if (_commitDimensions()) _setCustom(customH, customW);
                    },
                  ),
                  const SizedBox(width: 8),
                  _dimensionInput(width: false),
                ],
              ),
            ),
          ),
          if (_isCustom) ...[
            const SizedBox(height: 8),
            Text(
              '可手动输入宽高；小数取整数部分，尺寸自动对齐 64 像素。',
              style: context.texts.bodySmall,
            ),
          ],
          const SizedBox(height: 12),
          _StatusStrip(width: _effW, height: _effH),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('resolution-confirm'),
            onPressed:
                over ||
                    (_isCustom && (_widthError != null || _heightError != null))
                ? null
                : _apply,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            child: Text(
              over ? '超出像素上限' : '确认 · $_effW×$_effH',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// 档位状态条:MP · 比例 + 免费/消耗点数/超出上限徽章(与 web classifyPixelStatus 同义)。
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.width, required this.height});

  final int width;
  final int height;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final tier = classifyPixels(width, height);
    final (label, color) = switch (tier) {
      PixelTier.free => ('免费', scheme.tertiary),
      PixelTier.paid => ('消耗点数', scheme.primary),
      PixelTier.over => ('超出上限', scheme.error),
    };
    return Row(
      children: [
        Text(
          '${megapixels(width, height).toStringAsFixed(2)} MP',
          style: mono(
            context,
            size: 12.5,
          ).copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 8),
        Text('·', style: TextStyle(color: scheme.outline)),
        const SizedBox(width: 8),
        Text(
          formatAspectRatio(width, height),
          style: mono(
            context,
            size: 12.5,
          ).copyWith(color: scheme.onSurfaceVariant),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .14),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

/// 自定义档:拖拽画布(左上锚定,右下角把手定 W/H)+ 读数/交换 + 缩到免费/上限。
/// 触屏在画布任意处按下/拖动即把右下角吸到手指,较桌面「抓把手」更顺;
/// 拖到免费线/上限线附近自动吸到线内侧那格。读数框点开可手输。
class _CanvasEditor extends StatefulWidget {
  const _CanvasEditor({
    required this.width,
    required this.height,
    required this.onChanged,
    this.dimensions,
    this.maxSide = 300,
  });

  final int width;
  final int height;
  final void Function(int w, int h) onChanged;
  final Widget? dimensions;
  final double maxSide;

  @override
  State<_CanvasEditor> createState() => _CanvasEditorState();
}

class _CanvasEditorState extends State<_CanvasEditor> {
  /// 本次拖拽吸住的线(像素预算),null = 没吸。只管手势判定,不进 build。
  int? _stuck;

  void _fromLocal(Offset local, double side) {
    final x = (local.dx / side).clamp(0.0, 1.0) * _axisMax;
    final y = (local.dy / side).clamp(0.0, 1.0) * _axisMax;
    final dpPerPx = side / _axisMax;
    int? line;
    var nearest = double.infinity;
    for (final budget in _pixelLines) {
      final d = distanceToPixelLine(x, y, budget) * dpPerPx;
      final reach = budget == _stuck ? _snapOutDp : _snapInDp;
      if (d <= reach && d < nearest) {
        line = budget;
        nearest = d;
      }
    }
    if (line != null && line != _stuck) Haptics.selection();
    _stuck = line;
    if (line != null) {
      final r = snapToPixelLine(x, y, line);
      widget.onChanged(r.w, r.h);
    } else {
      widget.onChanged(snapDim(x.round()), snapDim(y.round()));
    }
  }

  /// 读数框手输:走通用手输弹窗,步长 64、范围同画布。
  Future<void> _input({required bool isWidth}) async {
    final v = await showParamInput(
      context,
      title: isWidth ? '宽度' : '高度',
      value: (isWidth ? widget.width : widget.height).toDouble(),
      min: kMinDim.toDouble(),
      max: kMaxDim.toDouble(),
      divisions: (kMaxDim - kMinDim) ~/ kResSnapStep,
    );
    if (v == null || !mounted) return;
    final n = v.round();
    if (isWidth) {
      widget.onChanged(n, widget.height);
    } else {
      widget.onChanged(widget.width, n);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final width = widget.width;
    final height = widget.height;
    final onChanged = widget.onChanged;
    final tier = classifyPixels(width, height);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: LayoutBuilder(
            builder: (context, cons) {
              final side = (cons.maxWidth.isFinite ? cons.maxWidth : 280.0)
                  .clamp(0.0, widget.maxSide)
                  .toDouble();
              return SizedBox(
                width: side,
                height: side,
                child: GestureDetector(
                  // 用手势识别器抢占竞技场,避免竖向拖被底部浮层的「下拉关闭」偷走。
                  behavior: HitTestBehavior.opaque,
                  onPanDown: (d) => _fromLocal(d.localPosition, side),
                  onPanUpdate: (d) => _fromLocal(d.localPosition, side),
                  onPanEnd: (_) => _stuck = null,
                  onPanCancel: () => _stuck = null,
                  child: CustomPaint(
                    painter: _ResCanvasPainter(
                      width: width,
                      height: height,
                      scheme: scheme,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        // 读数 + 动作:交换钮夹在长宽之间(替代 ×)。动作按档位只出一个:
        // 消耗点数 → 缩到免费,超出上限 → 缩到上限。Wrap 兜底:字号调大时整组换行,
        // 不会把 chip 挤出界。
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 8,
          children: [
            widget.dimensions ??
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ParamValueBox(
                      text: '$width',
                      onTap: () => _input(isWidth: true),
                    ),
                    const SizedBox(width: 6),
                    _SwapBtn(onTap: () => onChanged(height, width)),
                    const SizedBox(width: 6),
                    ParamValueBox(
                      text: '$height',
                      onTap: () => _input(isWidth: false),
                    ),
                  ],
                ),
            // 免费档淡出但照常占位:chip 比读数行高一点,按需插拔会把整个面板
            // 顶高/缩回;常驻占位则三档布局完全一致。
            AnimatedOpacity(
              duration: Motion.fast,
              opacity: tier == PixelTier.free ? 0 : 1,
              child: IgnorePointer(
                ignoring: tier == PixelTier.free,
                child: _QuickChip(
                  tier == PixelTier.over ? '缩到上限' : '缩到免费',
                  onTap: () {
                    final r = tier == PixelTier.over
                        ? clampToMaxPixels(width, height)
                        : scaleToFree(width, height);
                    onChanged(r.w, r.h);
                  },
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ResCanvasPainter extends CustomPainter {
  _ResCanvasPainter({
    required this.width,
    required this.height,
    required this.scheme,
  });

  final int width;
  final int height;
  final ColorScheme scheme;

  Color _tierColor(PixelTier t) => switch (t) {
    PixelTier.free => _vizFree,
    PixelTier.paid => scheme.primary,
    PixelTier.over => _vizOver,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(10),
    );

    // 底 + 圆角裁剪
    canvas.drawRRect(rrect, Paint()..color = scheme.surfaceContainerHigh);
    canvas.save();
    canvas.clipRRect(rrect);

    // 网格(每 256 真实像素一线)
    final grid = Paint()
      ..color = scheme.onSurface.withValues(alpha: .06)
      ..strokeWidth = .5;
    for (double px = 256; px < _axisMax; px += 256) {
      final c = px / _axisMax * s;
      canvas.drawLine(Offset(c, 0), Offset(c, s), grid);
      canvas.drawLine(Offset(0, c), Offset(s, c), grid);
    }

    // 等像素双曲线:免费线(绿)/上限线(红);右下角贴在哪条上,哪条描实
    _hyperbola(canvas, s, kFreePixelThreshold, _vizFree, 3, 3);
    _hyperbola(canvas, s, kMaxTotalPixels, _vizOver, 4, 3);

    // 当前尺寸矩形(左上锚定)
    final rw = (width / _axisMax).clamp(0.0, 1.0) * s;
    final rh = (height / _axisMax).clamp(0.0, 1.0) * s;
    final tier = classifyPixels(width, height);
    final col = _tierColor(tier);
    final rect = Rect.fromLTWH(0, 0, rw, rh);
    canvas.drawRect(rect, Paint()..color = col.withValues(alpha: .18));
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = col,
    );

    // 右下角把手 + 抓握斜线
    final hc = Offset(rw, rh);
    final handle = RRect.fromRectAndRadius(
      Rect.fromCenter(center: hc, width: 22, height: 22),
      const Radius.circular(5),
    );
    canvas.drawRRect(handle, Paint()..color = col);
    final grip = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    for (final d in const [-4.0, 0.0, 4.0]) {
      canvas.drawLine(
        Offset(hc.dx + d, hc.dy + 4),
        Offset(hc.dx + 4, hc.dy + d),
        grip,
      );
    }

    canvas.restore();
    // 外描边
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = scheme.outlineVariant,
    );
  }

  /// w×h=pixels 的等像素线,离散成虚线路径(与 web buildHyperbolaPath 同构)。
  void _hyperbola(
    Canvas canvas,
    double s,
    int pixels,
    Color color,
    double on,
    double off,
  ) {
    final path = Path();
    var started = false;
    for (
      double xpx = kResSnapStep.toDouble();
      xpx <= _axisMax;
      xpx += kResSnapStep
    ) {
      final ypx = pixels / xpx;
      if (ypx > _axisMax) continue;
      final cx = xpx / _axisMax * s;
      final cy = ypx / _axisMax * s;
      if (!started) {
        path.moveTo(cx, cy);
        started = true;
      } else {
        path.lineTo(cx, cy);
      }
    }
    if (!started) return;
    final hit = isOnPixelLine(width, height, pixels);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = hit ? 1.6 : 1
      ..color = color.withValues(alpha: hit ? .9 : .5);
    canvas.drawPath(hit ? path : _dash(path, on, off), paint);
  }

  Path _dash(Path src, double on, double off) {
    final out = Path();
    for (final m in src.computeMetrics()) {
      var dist = 0.0;
      while (dist < m.length) {
        out.addPath(m.extractPath(dist, dist + on), Offset.zero);
        dist += on + off;
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(_ResCanvasPainter old) =>
      old.width != width || old.height != height || old.scheme != scheme;
}

/// 长宽之间的交换钮:小巧圆钮,替代 ×,省出横向空间。
class _SwapBtn extends StatelessWidget {
  const _SwapBtn({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Tooltip(
      message: '交换宽高',
      child: Material(
        color: scheme.surfaceContainerHigh,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 30,
            height: 30,
            child: Icon(
              Icons.swap_horiz,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip(this.label, {required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.compress,
                size: 15,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: context.texts.bodySmall!.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final SizePreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final ratio = preset.width / preset.height;
    const box = 44.0;
    final w = ratio >= 1 ? box : box * ratio;
    final h = ratio >= 1 ? box / ratio : box;
    return AnimatedContainer(
      duration: Motion.fast,
      decoration: BoxDecoration(
        color: selected
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? scheme.primary : Colors.transparent,
          width: 2,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
            child: Column(
              children: [
                SizedBox(
                  width: box,
                  height: box,
                  child: Center(
                    child: AnimatedContainer(
                      duration: Motion.fast,
                      width: w,
                      height: h,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                          color: selected ? scheme.primary : scheme.outline,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  preset.name,
                  style: context.texts.bodySmall!.copyWith(
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurface,
                  ),
                ),
                Text(
                  preset.ratio,
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  '${preset.width}×${preset.height}',
                  style: mono(
                    context,
                    size: 9.5,
                    weight: FontWeight.w500,
                  ).copyWith(color: scheme.outline),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
