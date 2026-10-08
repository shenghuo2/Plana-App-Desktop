import 'package:flutter/material.dart';

/// Desktop's new 100% is the previous 105%; stored preferences stay relative.
const kDesktopTextBaseline = 1.05;

/// Scales text throughout the navigator, including dialogs and overlays.
/// Keeping the same wrapper at 100% preserves routes and drafts during edits.
class AppTextScale extends StatelessWidget {
  const AppTextScale({
    super.key,
    required this.factor,
    this.baseline = 1,
    required this.child,
  });

  final double factor;
  final double baseline;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: factor == 1 && baseline == 1
            ? media.textScaler
            : _AppTextScaler(media.textScaler, factor, baseline: baseline),
      ),
      child: child,
    );
  }
}

/// Dense prompt editors keep their original baseline, including their text
/// measurements and selection overlays. User and system zoom still apply.
class OriginalTextBaseline extends StatelessWidget {
  const OriginalTextBaseline({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scaler = media.textScaler;
    return MediaQuery(
      data: media.copyWith(
        textScaler: scaler is _AppTextScaler ? scaler.withoutBaseline : scaler,
      ),
      child: child,
    );
  }
}

/// Preserve the system's scaling curve while applying the app preference.
class _AppTextScaler extends TextScaler {
  const _AppTextScaler(this.system, this.factor, {this.baseline = 1});

  final TextScaler system;
  final double factor;
  final double baseline;

  TextScaler get withoutBaseline =>
      factor == 1 ? system : _AppTextScaler(system, factor);

  @override
  double scale(double fontSize) => system.scale(fontSize) * factor * baseline;

  @override
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) =>
      other is _AppTextScaler &&
      other.system == system &&
      other.factor == factor &&
      other.baseline == baseline;

  @override
  int get hashCode => Object.hash(system, factor, baseline);
}
