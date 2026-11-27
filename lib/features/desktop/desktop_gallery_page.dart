import '../../l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../gallery/albums/album_state.dart';
import '../gallery/gallery_state.dart';
import 'desktop_gallery_browser.dart';
import '../gallery/widgets/gallery_grid_sheet.dart';
import '../generate/generation_controller.dart';
import '../generate/widgets/common.dart' show hintSnack;
import '../inpaint/inpaint_overlay.dart' show inpaintSessionProvider;
import '../shell/shell_state.dart';
import 'desktop_library_picker.dart';
import 'desktop_library_state.dart';

void returnToDesktopCreation(WidgetRef ref) =>
    ref.read(shellIndexProvider.notifier).select(kTabCreate);

void openDesktopGallery(WidgetRef ref, {bool currentLibrary = false}) {
  ref.read(desktopLibraryProvider.notifier).refreshDay();
  ref
      .read(desktopGalleryLocationProvider.notifier)
      .open(
        currentLibrary ? ref.read(desktopLibraryProvider).albumId : null,
        overview: !currentLibrary,
      );
  ref.read(shellIndexProvider.notifier).select(kTabGallery);
}

Future<void> showDesktopLibraryPicker(
  BuildContext context,
  WidgetRef ref,
) async {
  if (ref.read(inpaintSessionProvider) != null) {
    hintSnack(context, l10nNow.desktopFinishInpaintingToSwitchGalleries);
    return;
  }
  final choice = await showLibraryChoiceDialog(context);
  if (choice == null || !context.mounted) return;
  // 浏览别的图库不等于主动改选历史图，保留当前任务的画布跟随。
  final following = ref.read(generationProvider).selected != null;
  ref
      .read(desktopLibraryProvider.notifier)
      .choose(choice.albumId, automatic: choice.automatic);
  if (!following) {
    ref.read(generationProvider.notifier).select(null);
    ref.read(galleryResultPreviewProvider.notifier).clear();
    final images = ref.read(galleryViewProvider).results;
    final selected = ref.read(galleryProvider).selectedId;
    if (!images.any((r) => r.id == selected)) {
      ref.read(galleryProvider.notifier).select(images.firstOrNull?.id);
    }
  }
}

class DesktopGalleryPage extends StatelessWidget {
  const DesktopGalleryPage({super.key});
  @override
  Widget build(BuildContext context) => const DesktopGalleryBrowser();
}

class DesktopLibraryButton extends ConsumerWidget {
  const DesktopLibraryButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(desktopLibraryProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: OutlinedButton.icon(
            key: const ValueKey('desktop-library-picker'),
            style: OutlinedButton.styleFrom(
              backgroundColor: context.scheme.surfaceContainerLowest,
              foregroundColor: context.scheme.onSurfaceVariant,
              side: BorderSide(color: context.scheme.outlineVariant),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 30),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () => showDesktopLibraryPicker(context, ref),
            icon: Icon(
              selection.automatic
                  ? Icons.calendar_month_outlined
                  : Icons.photo_library_outlined,
              size: 15,
            ),
            label: Text(
              l10nNow.desktopSwitchGallery,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.labelMedium!.copyWith(
                color: context.scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('desktop-history-browse'),
          tooltip:
              '快速浏览与批量导出 · ${desktopLibraryLabel(selection, ref.watch(albumsProvider))}',
          onPressed: () => showGalleryGrid(
            context,
            desktop: true,
            onChooseAlbum: showDesktopLibraryPicker,
          ),
          icon: const Icon(Icons.expand_less, size: 18),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
