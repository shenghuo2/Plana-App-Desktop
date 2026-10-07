import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';

import 'app_stores.dart';

/// Commit editor drafts before flushing, and let desktop exit only after the
/// storage queues finish. Background transitions still start an immediate save.
AppLifecycleListener createStorageLifecycleListener(
  AppStores stores, {
  VoidCallback? beforeFlush,
}) => AppLifecycleListener(
  onStateChange: (state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      beforeFlush?.call();
      stores.flushNow();
    }
  },
  onExitRequested: () async {
    beforeFlush?.call();
    await stores.flushForExit();
    return AppExitResponse.exit;
  },
);
