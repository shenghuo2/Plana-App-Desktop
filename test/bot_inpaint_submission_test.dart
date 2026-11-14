import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/core/net/backend_config.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/generation_controller.dart';
import 'package:plana_app/features/generate/models.dart';

class _Auth extends AuthModeNotifier {
  @override
  Future<AuthMode?> build() async => AuthMode.bot;
}

class _Session extends BotSessionNotifier {
  @override
  Future<BotSession?> build() async =>
      const BotSession(sessionId: 'synthetic-bot-session');
}

class _Base extends BackendBaseNotifier {
  @override
  Future<String> build() async => 'https://bot-fixture.invalid';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (model, sentModel) in [
    ('NAI 4.5 Full', 'nai-diffusion-4-5-full'),
    ('NAI 5.0 Full', 'nai-diffusion-5-full'),
    ('NAI 5.0 Full Medium', 'nai-diffusion-5-full-medium'),
  ]) {
    test(
      '$model: main and saved-image generation send effective Bot inpaint strength',
      () async {
        final stores = AppStores.ephemeral();
        final requests = <http.Request>[];
        final transport = MockClient((request) async {
          requests.add(request);
          // Stop at the HTTP boundary: this test cannot validate the remote
          // backend's conversion to a NovelAI request or its generated pixels.
          return http.Response(
            jsonEncode({'success': false, 'message': 'fixture: captured only'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        await http.runWithClient(() async {
          final container = ProviderContainer(
            overrides: [
              appStoresProvider.overrideWithValue(stores),
              authModeProvider.overrideWith(_Auth.new),
              botSessionProvider.overrideWith(_Session.new),
              backendBaseProvider.overrideWith(_Base.new),
              backendClientProvider.overrideWithValue(
                BackendClient('https://bot-fixture.invalid'),
              ),
            ],
          );
          try {
            await container.read(authModeProvider.future);
            await container.read(botSessionProvider.future);
            await container.read(backendBaseProvider.future);
            final editor = container.read(generateProvider.notifier);
            editor.applyParams(
              const GenParams().copyWith(model: model, seed: '123456'),
            );
            editor.setPrompts(positive: 'synthetic test');
            final image = Uint8List.fromList(
              img.encodePng(img.Image(width: 64, height: 64)),
            );
            final mask = Uint8List.fromList(
              img.encodePng(
                img.fill(
                  img.Image(width: 64, height: 64),
                  color: img.ColorRgb8(255, 255, 255),
                ),
              ),
            );
            editor.setInpaint(
              InpaintJob(image: image, mask: mask, strength: .5),
              width: 64,
              height: 64,
            );
            final generation = container.read(generationProvider.notifier);
            // Use the main action, without a saved-image `using` override.
            final first = generation.generate();
            // A later slider edit must not replace the first job's snapshot.
            editor.updateInpaintStrength(.75);
            expect(await first, GenOutcome.notCharged);
            expect(await generation.generate(), GenOutcome.notCharged);

            expect(requests, hasLength(2));
            final sent = <Map<String, dynamic>>[];
            for (final request in requests) {
              expect(request.method, 'POST');
              expect(
                request.url.toString(),
                'https://bot-fixture.invalid/api/bot/generate',
              );
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              expect(body['image_backend'], 'novelai');
              final params = body['params'] as Map<String, dynamic>;
              sent.add(params);
              expect(params['model'], sentModel);
              expect(params['seed'], 123456);
              expect(params['inpaint']['imageBase64'], base64Encode(image));
              expect(params['inpaint']['maskBase64'], base64Encode(mask));
            }
            expect(sent.map((p) => p['inpaint']['strength']), [.5, .75]);
            // The Bot adapter reads this field for NAI's effective infill
            // strength; checking only the legacy `strength` missed this bug.
            expect(sent.map((p) => p['inpaint']['img2imgStrength']), [.5, .75]);
            final job = container.read(generateProvider).inpaint!;
            expect(job.strength, .75);
            expect(job.image, image);
            expect(job.mask, mask);

            // Re-generating a saved image uses its snapshot, even when the
            // current editor has another strength. Include 1 to catch stale
            // sub-unit values leaking from the preceding job.
            final snapshot = container.read(generateProvider);
            editor.updateInpaintStrength(.25);
            for (final strength in [.5, .75, 1.0]) {
              expect(
                await generation.generate(
                  using: snapshot.copyWith(
                    inpaint: InpaintJob(
                      image: image,
                      mask: mask,
                      strength: strength,
                    ),
                  ),
                ),
                GenOutcome.notCharged,
              );
            }
            expect(requests, hasLength(5));
            final regenerated = requests
                .skip(2)
                .map((r) => (jsonDecode(r.body) as Map)['params'] as Map)
                .toList();
            expect(regenerated.map((p) => p['seed']), [123456, 123456, 123456]);
            expect(regenerated.map((p) => p['inpaint']['strength']), [
              .5,
              .75,
              1.0,
            ]);
            expect(regenerated.map((p) => p['inpaint']['img2imgStrength']), [
              .5,
              .75,
              1.0,
            ]);
            for (final p in regenerated) {
              expect(p['inpaint']['imageBase64'], base64Encode(image));
              expect(p['inpaint']['maskBase64'], base64Encode(mask));
              expect(p.containsKey('img2img'), isFalse);
            }
            expect(container.read(generateProvider).inpaint!.strength, .25);
          } finally {
            container.dispose();
            stores.flushNow();
            await stores.workspace.idle;
          }
        }, () => transport);
      },
    );
  }
}
