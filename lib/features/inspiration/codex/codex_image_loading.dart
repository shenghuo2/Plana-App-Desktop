import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/net/remote_image.dart';

/// Scheduling belongs to one codex browser, not the shared image cache. No
/// notifier rebuilds the cards/list when scrolling starts or stops.
class CodexImageLoadController {
  CodexImageLoadController({
    this.quietPeriod = const Duration(milliseconds: 140),
    this.heldQuietPeriod = const Duration(seconds: 3),
    this.startsPerFrame = 3,
    this.maxConcurrent = 4,
  }) : assert(startsPerFrame > 0),
       assert(maxConcurrent > 0);

  final Duration quietPeriod;
  final Duration heldQuietPeriod;
  final int startsPerFrame;
  final int maxConcurrent;
  final _positions = <ScrollPosition>{};
  final _waiting = <_CodexImageRequest, VoidCallback>{};
  final _inFlight = Map<ImageStreamCompleter, ImageStreamListener>.identity();
  int _activeTasks = 0;
  int get _busy => _inFlight.length + _activeTasks;
  CodexLoadTicket ticket() => CodexLoadTicket._(this);
  Timer? _quiet;
  bool _paused = false;
  bool _drainScheduled = false;
  bool _disposed = false;

  @visibleForTesting
  bool get isPaused => _paused;

  @visibleForTesting
  int get pendingCount => _waiting.length;

  /// DragScrollActivity reports zero velocity while dragging a scrollbar; its
  /// isScrollingNotifier remains true, including pauses with the thumb held.
  void attach(ScrollPosition position) {
    if (_disposed || !_positions.add(position)) return;
    position.addListener(_moved);
    position.isScrollingNotifier.addListener(_activityChanged);
    if (position.isScrollingNotifier.value) _activityChanged();
  }

  void detach(ScrollPosition position) {
    if (!_positions.remove(position)) return;
    position.removeListener(_moved);
    position.isScrollingNotifier.removeListener(_activityChanged);
    if (_positions.isEmpty) {
      // An empty filter or a closed grid has no scroll activity left to wait
      // for. Do not leave a quiet timer alive after its last position detaches.
      _quiet?.cancel();
      _quiet = null;
      _paused = false;
      _scheduleDrain();
    } else if (!_disposed && _paused) {
      _waitForQuiet();
    }
  }

  bool get _scrolling =>
      _positions.any((position) => position.isScrollingNotifier.value);

  void _activityChanged() {
    if (_disposed) return;
    if (_scrolling) _paused = true;
    _waitForQuiet();
  }

  void _moved() {
    if (_disposed) return;
    _paused = true;
    // Also covers pointerScroll and jumpTo, whose start/end notifications can
    // occur together in one event with no sustained scrolling activity.
    _waitForQuiet();
  }

  void _waitForQuiet() {
    _quiet?.cancel();
    _quiet = Timer(_scrolling ? heldQuietPeriod : quietPeriod, () {
      _quiet = null;
      if (_disposed) return;
      _paused = false;
      _scheduleDrain();
    });
  }

  void _enqueue(_CodexImageRequest request, VoidCallback resolve) {
    if (_disposed || !request.active) return;
    _waiting[request] = resolve;
    _scheduleDrain();
  }

  void _scheduleDrain() {
    if (_disposed ||
        _paused ||
        _drainScheduled ||
        _waiting.isEmpty ||
        _busy >= maxConcurrent) {
      return;
    }
    _drainScheduled = true;
    // After layout, cards removed by scrolling/filtering have already canceled
    // their tickets. Start only a few remaining thumbnails in each frame.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _drainScheduled = false;
      if (_disposed || _paused) return;
      final slots = math.min(startsPerFrame, maxConcurrent - _busy);
      final batch = _waiting.keys.take(slots).toList();
      for (final request in batch) {
        final resolve = _waiting.remove(request);
        if (request.active) resolve?.call();
      }
      _scheduleDrain();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  // A card can leave the viewport while its download or decode still runs.
  // Hold that slot until the first frame or error, including for offscreen cards.
  void _trackFirstFrame(ImageStreamCompleter completer) {
    if (_inFlight.containsKey(completer)) return;
    void finish() {
      final listener = _inFlight.remove(completer);
      if (listener != null) completer.removeListener(listener);
      _scheduleDrain();
    }

    final listener = ImageStreamListener((image, _) {
      image.dispose();
      finish();
    }, onError: (Object error, StackTrace? stack) => finish());
    _inFlight[completer] = listener;
    completer.addListener(listener);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _quiet?.cancel();
    _quiet = null;
    for (final position in _positions.toList()) {
      detach(position);
    }
    for (final ticket in _waiting.keys.whereType<CodexLoadTicket>().toList()) {
      ticket.cancel();
    }
    _waiting.clear();
    for (final entry in _inFlight.entries) {
      entry.key.removeListener(entry.value);
    }
    _inFlight.clear();
  }
}

/// Owns one image request. Replacing its URL, decode size, or content revision
/// cancels the queued resolution; disposing a card never starts an old request.
class CodexDeferredImage extends StatefulWidget {
  const CodexDeferredImage({
    super.key,
    required this.controller,
    required this.builder,
  });

  final CodexImageLoadController controller;
  final Widget Function(RemoteImageProviderDecorator decorator) builder;

  @override
  State<CodexDeferredImage> createState() => _CodexDeferredImageState();
}

class _CodexDeferredImageState extends State<CodexDeferredImage> {
  ImageProvider<Object>? _source;
  _CodexImageRequest? _request;
  _CodexImageProvider? _provider;

  ImageProvider<Object> _decorate(ImageProvider<Object> source) {
    if (_source != source || _request?.controller != widget.controller) {
      _request?.cancel();
      _source = source;
      _request = _CodexImageRequest(widget.controller);
      _provider = _CodexImageProvider(source, _request!);
    }
    return _provider!;
  }

  @override
  void dispose() {
    _request?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_decorate);
}

class _CodexImageRequest {
  _CodexImageRequest(this.controller);

  final CodexImageLoadController controller;
  bool _canceled = false;
  bool get active => !_canceled && !controller._disposed;

  void cancel() {
    _canceled = true;
    controller._waiting.remove(this);
  }
}

/// Runs successive catalog reads through the same viewport queue as thumbnail
/// decodes. A recycled card cancels its waiting read before it starts.
class CodexLoadTicket extends _CodexImageRequest {
  CodexLoadTicket._(super.controller);
  VoidCallback? _cancelWaiting;

  Future<void> waitForViewport() async {
    if (controller._paused) await run(() async {});
    if (!active) throw const CodexLoadCancelled();
  }

  Future<T> run<T>(Future<T> Function() work) {
    if (!active) return Future.error(const CodexLoadCancelled());
    final result = Completer<T>();
    _cancelWaiting = () => result.completeError(const CodexLoadCancelled());
    controller._enqueue(this, () async {
      _cancelWaiting = null;
      controller._activeTasks++;
      try {
        result.complete(await work());
      } catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        controller._activeTasks--;
        controller._scheduleDrain();
      }
    });
    return result.future;
  }

  @override
  void cancel() {
    super.cancel();
    _cancelWaiting?.call();
    _cancelWaiting = null;
  }
}

class CodexLoadCancelled implements Exception {
  const CodexLoadCancelled();
}

@immutable
class _CodexImageProvider extends ImageProvider<Object> {
  const _CodexImageProvider(this.source, this.request);

  final ImageProvider<Object> source;
  final _CodexImageRequest request;

  @override
  Future<Object> obtainKey(ImageConfiguration configuration) =>
      source.obtainKey(configuration);

  @override
  ImageStreamCompleter loadImage(Object key, ImageDecoderCallback decode) =>
      source.loadImage(key, decode);

  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    Object key,
    ImageErrorListener handleError,
  ) {
    if (!request.active) return;
    final cache = PaintingBinding.instance.imageCache;
    bool tracked() {
      final status = cache.statusForKey(key);
      return status.pending || status.keepAlive || status.live;
    }

    void resolve() {
      if (!request.active) return;
      final startsLoad = stream.completer == null && !tracked();
      if (request.controller._paused && startsLoad) {
        request.controller._enqueue(request, resolve);
        return;
      }
      try {
        source.resolveStreamForKey(configuration, stream, key, handleError);
        final completer = stream.completer;
        if (startsLoad && completer != null) {
          request.controller._trackFirstFrame(completer);
        }
      } catch (error, stack) {
        handleError(error, stack);
      }
    }

    // Decoded cache hits remain visible while moving. Sharing an existing
    // in-flight completer also starts no new download/decode.
    if (stream.completer != null || tracked()) {
      resolve();
    } else {
      request.controller._enqueue(request, resolve);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _CodexImageProvider &&
      other.source == source &&
      identical(other.request, request);

  @override
  int get hashCode => Object.hash(source, request);
}
