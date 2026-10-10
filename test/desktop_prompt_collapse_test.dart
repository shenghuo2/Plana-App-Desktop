import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/editor_page.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/widgets/character_card.dart';
import 'package:plana_app/features/generate/widgets/prompt_card.dart';
import 'package:plana_app/features/inspiration/widgets/tag_card.dart';

void main() {
  late AppStores stores;
  late ProviderContainer container;
  setUp(() async {
    stores = AppStores.ephemeral();
    await stores.prefs.write(
      key: 'editor_settings',
      value: jsonEncode(
        const EditorSettings(
          enableCompletion: false,
          showTranslation: false,
        ).toJson(),
      ),
    );
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
  });

  Finder key(String id) => find.byKey(ValueKey(id));
  Finder input(String id) =>
      find.descendant(of: key('$id-text'), matching: find.byType(TextField));
  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(width: 500, child: child),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String id) async {
    await tester.ensureVisible(key(id));
    await tester.tap(key(id));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets(
    'compact character expands to the complete card and preserves editor session',
    (tester) async {
      final gen = container.read(generateProvider.notifier);
      gen.addCharacter();
      final id = container.read(generateProvider).characters.single.id;
      gen.updateCharacter(
        id,
        positive: 'traveler, white shirt',
        negative: 'hat',
      );
      container
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(compactCharCards: true));
      await mount(tester, const CharacterCard());
      expect(input('desktop-character-$id'), findsNothing);
      expect(find.byType(TagCardPreview), findsNothing);
      expect(find.text('traveler, white shirt'), findsOneWidget);
      await tap(tester, 'character-collapse-$id');
      expect(find.byType(TagCardPreview), findsOneWidget);
      expect(input('desktop-character-$id'), findsOneWidget);
      expect(find.byType(ExpansionTile), findsNothing);
      expect(
        find.text('hat'),
        findsNothing,
        reason: 'the summary row is removed when expanded',
      );
      final field = tester.widget<TextField>(input('desktop-character-$id'));
      await tester.enterText(
        input('desktop-character-$id'),
        'traveler, blue shirt',
      );
      await tap(tester, 'character-collapse-$id');
      expect(
        container.read(generateProvider).characters.single.positive,
        'traveler, blue shirt',
      );
      expect(input('desktop-character-$id'), findsNothing);
      await tap(tester, 'character-collapse-$id');
      expect(
        tester.widget<TextField>(input('desktop-character-$id')).controller,
        same(field.controller),
      );
      expect(
        tester
            .widget<TextField>(input('desktop-character-$id'))
            .controller!
            .text,
        'traveler, blue shirt',
      );
      expect(
        container.read(generateProvider).characters.single.negative,
        'hat',
      );
      expect(find.byType(EditorPage), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'main and section cards collapse independently without losing edits',
    (tester) async {
      final gen = container.read(generateProvider.notifier);
      gen.setPrompts(positive: 'solo', negative: 'lowres');
      gen.addSection();
      final id = container.read(generateProvider).sections.last.id;
      gen.applyCanvas(
        CanvasPrompts.of(
          container
              .read(generateProvider)
              .copyWith(
                sections: [
                  for (final s in container.read(generateProvider).sections)
                    s.id == id
                        ? s.copyWith(positive: 'ocean', negative: 'indoors')
                        : s,
                ],
              ),
        ),
        force: true,
      );
      await mount(tester, const PromptCard());
      await tester.enterText(input('desktop-section-$id'), 'ocean, blue sky');
      final controller = tester
          .widget<TextField>(input('desktop-section-$id'))
          .controller;
      await tap(tester, 'prompt-section-collapse-$id');
      expect(input('desktop-section-$id'), findsNothing);
      expect(input('desktop-prompt'), findsOneWidget);
      expect(
        container.read(generateProvider).sections.last.positive,
        'ocean, blue sky',
      );
      await tap(tester, 'prompt-section-collapse-main');
      expect(input('desktop-prompt'), findsNothing);
      await tap(tester, 'prompt-section-collapse-$id');
      expect(input('desktop-prompt'), findsNothing);
      expect(
        tester.widget<TextField>(input('desktop-section-$id')).controller,
        same(controller),
      );
      expect(container.read(generateProvider).negativePrompt, 'lowres');
      expect(
        container.read(generateProvider).sections.last.negative,
        'indoors',
      );
      await finish(tester);
    },
  );

  testWidgets(
    'default collapsed preference covers main and all section cards',
    (tester) async {
      final gen = container.read(generateProvider.notifier);
      gen.setPrompts(positive: 'solo');
      gen.addSection();
      container
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(compactCharCards: true));
      await mount(tester, const PromptCard());
      expect(find.byType(EditorPage), findsNothing);
      await tap(tester, 'prompt-section-collapse-main');
      expect(input('desktop-prompt'), findsOneWidget);
      expect(find.byType(EditorPage), findsOneWidget);
      await finish(tester);
    },
  );
  testWidgets(
    'main prompt without sections supports the same default and preserves edits',
    (tester) async {
      final gen = container.read(generateProvider.notifier);
      gen.setPrompts(positive: 'solo', negative: 'lowres');
      container
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(compactCharCards: true));
      await mount(tester, const PromptCard());
      expect(input('desktop-prompt'), findsNothing);
      expect(find.text('solo'), findsOneWidget);
      await tap(tester, 'prompt-section-collapse-main');
      await tester.enterText(input('desktop-prompt'), 'solo, rain');
      final controller = tester
          .widget<TextField>(input('desktop-prompt'))
          .controller;
      await tap(tester, 'prompt-section-collapse-main');
      expect(input('desktop-prompt'), findsNothing);
      expect(container.read(generateProvider).prompt, 'solo, rain');
      await tap(tester, 'prompt-section-collapse-main');
      expect(
        tester.widget<TextField>(input('desktop-prompt')).controller,
        same(controller),
      );
      expect(container.read(generateProvider).negativePrompt, 'lowres');
      await finish(tester);
    },
  );
  testWidgets(
    'disabled sections remain expandable and editing does not enable them',
    (tester) async {
      final gen = container.read(generateProvider.notifier);
      gen.addSection();
      final id = container.read(generateProvider).sections.last.id;
      gen.updateSection(id, enabled: false);
      container
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(compactCharCards: true));
      await mount(tester, const PromptCard());
      expect(input('desktop-section-$id'), findsNothing);
      await tap(tester, 'prompt-section-collapse-$id');
      expect(input('desktop-section-$id'), findsOneWidget);
      await tester.enterText(input('desktop-section-$id'), 'disabled draft');
      await tap(tester, 'prompt-section-collapse-$id');
      expect(
        container.read(generateProvider).sections.last.positive,
        'disabled draft',
      );
      expect(container.read(generateProvider).sections.last.enabled, isFalse);
      await finish(tester);
    },
  );
}
