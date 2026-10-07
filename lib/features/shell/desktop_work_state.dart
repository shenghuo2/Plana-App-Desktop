import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../assistant/assistant_state.dart';
import '../generate/gen_queue.dart';
import '../generate/generation_controller.dart';
import '../generate/loop_controller.dart';
import '../gallery/external_image_push.dart';

/// 这些工作重启后不能接续,更新安装需要先等它们结束。
final desktopWorkBusyProvider = Provider(
  (ref) =>
      ref.watch(generationProvider.select((pool) => pool.busy)) ||
      ref.watch(
        genQueueProvider.select((q) => q.active || q.items.isNotEmpty),
      ) ||
      ref.watch(loopStatusProvider.select((loop) => loop.active)) ||
      ref.watch(assistantProvider.select((assistant) => assistant.running)) ||
      ref.watch(
        externalImagePushUploadsProvider.select((uploads) => uploads.busy),
      ),
);
