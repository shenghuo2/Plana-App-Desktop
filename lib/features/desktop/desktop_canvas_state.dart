import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A one-shot request also works when the creation sidebar mounts after the
/// action, or the same image is chosen as a base more than once.
final desktopImg2ImgRevealProvider =
    NotifierProvider<DesktopImg2ImgRevealNotifier, int?>(
      DesktopImg2ImgRevealNotifier.new,
    );

class DesktopImg2ImgRevealNotifier extends Notifier<int?> {
  int _sequence = 0;

  @override
  int? build() => null;

  void request() => state = ++_sequence;

  void handled(int request) {
    if (state == request) state = null;
  }
}

/// Coordinates Focus Canvas Mode (collapsing both workspace sidebars) across
/// the shell header toggle, workspace dividers, and Ctrl+\ / Cmd+\ shortcut.
final desktopFocusModeProvider =
    NotifierProvider<DesktopFocusModeNotifier, bool>(
      DesktopFocusModeNotifier.new,
    );

class DesktopFocusModeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final desktopFocusRequestProvider =
    NotifierProvider<DesktopFocusRequestNotifier, int?>(
      DesktopFocusRequestNotifier.new,
    );

class DesktopFocusRequestNotifier extends Notifier<int?> {
  int _sequence = 0;

  @override
  int? build() => null;

  void toggle() => state = ++_sequence;

  void handled(int request) {
    if (state == request) state = null;
  }
}
