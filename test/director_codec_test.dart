import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/features/director/director_codec.dart';
import 'package:plana_app/features/director/director_models.dart';
import 'package:plana_app/features/director/director_service.dart';
import 'package:plana_app/features/director/pixel_snap.dart';
import 'package:plana_app/features/gallery/image_operation.dart';

Uint8List png(int w, int h, {bool transparent = false}) {
  final image = img.Image(width: w, height: h, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(70, 130, 200, transparent ? 90 : 255));
  return Uint8List.fromList(img.encodePng(image));
}

img.Image pixelPicture({int scale = 6}) {
  final small = img.Image(width: 16, height: 12, numChannels: 4);
  for (final p in small) {
    p.setRgba(
      (p.x * 37 + p.y * 9) % 256,
      (p.y * 57) % 256,
      (p.x * 91) % 256,
      p.x < 2 ? 0 : 255,
    );
  }
  return img.copyResize(
    small,
    width: 16 * scale,
    height: 12 * scale,
    interpolation: img.Interpolation.nearest,
  );
}

void main() {
  test('six cloud tools send only their documented parameters', () {
    for (final tool in DirectorTool.values.where((t) => !t.local)) {
      final p = DirectorOptions(
        tool: tool,
        prompt: 'blue hair',
        emotion: 'happy',
        defry: 4,
      ).requestParameters();
      expect(p['req_type'], tool.code);
      if (tool == DirectorTool.emotion) {
        expect(p['prompt'], 'happy;;blue hair');
        expect(p['defry'], 4);
      } else if (tool == DirectorTool.colorize) {
        expect(p['prompt'], 'blue hair');
        expect(p['defry'], 4);
      } else {
        expect(p.keys, ['req_type']);
      }
    }
    expect(
      () => const DirectorOptions(defry: 6).requestParameters(),
      throwsFormatException,
    );
    expect(
      () => const DirectorOptions(
        tool: DirectorTool.pixelSnap,
      ).requestParameters(),
      throwsFormatException,
    );
  });

  test(
    'send copy uses exact aspect ratio and public size bounds, not 64 snapping',
    () {
      expect(directorSendSize(512, 511), (width: 1025, height: 1022));
      expect(directorSendSize(1024, 1024), (width: 1024, height: 1024));
      final resized = directorSendSize(4096, 2048);
      expect(resized.width * resized.height, lessThanOrEqualTo(3143728));
      expect(resized.width / resized.height, closeTo(2, .002));
      final original = png(512, 511, transparent: true);
      final copy = List<int>.from(original);
      final sent = prepareDirectorImage(original);
      expect(original, copy);
      final decoded = img.decodePng(base64Decode(sent.image))!;
      expect(decoded.width, sent.width);
      expect(decoded.height, sent.height);
      expect(decoded.getPixel(3, 3).a, 90);
    },
  );

  test('background ZIP preserves all variants, dimensions and alpha', () {
    final archive = Archive();
    for (var i = 0; i < 3; i++) {
      final bytes = png(32 + i, 45, transparent: true);
      archive.addFile(ArchiveFile('image_$i.png', bytes.length, bytes));
    }
    final outputs = decodeDirectorResponse(
      Uint8List.fromList(ZipEncoder().encode(archive)),
      DirectorTool.removeBackground,
    );
    expect(outputs.map((o) => o.variant), ['masked', 'generated', 'blend']);
    expect(outputs.map((o) => o.width), [32, 33, 34]);
    expect(img.decodePng(outputs.first.bytes)!.getPixel(0, 0).a, 90);
    final single = decodeDirectorResponse(
      png(20, 30),
      DirectorTool.removeBackground,
    );
    expect(single.single.variant, isNull);
    expect(
      () => decodeDirectorResponse(
        Uint8List.fromList(utf8.encode('<html>error</html>')),
        DirectorTool.lineart,
      ),
      throwsFormatException,
    );
  });

  test('provenance metadata never invents a generation seed', () {
    const operation = ImageOperation(
      tool: 'emotion',
      sourceName: 'source.png',
      jobId: 'job1',
      parameters: {'prompt': 'happy;;', 'defry': 3},
    );
    final bytes = stampDirectorResult(
      png(15, 30, transparent: true),
      operation,
    );
    final image = img.decodePng(bytes)!;
    expect(image.textData!.keys, ['PlanaDirector']);
    final restored = ImageOperation.fromJson(
      jsonDecode(image.textData!['PlanaDirector']!),
    )!;
    expect(restored.toJson(), operation.toJson());
    expect(image.getPixel(4, 4).a, 90);
  });

  test(
    'route restrictions never fall back from Bot or OpenAI to another token',
    () {
      const key = NaiKey(id: 'primary', token: 'test-only');
      expect(directorAccessFor(AuthMode.bot, key, false).available, false);
      expect(
        directorAccessFor(
          AuthMode.token,
          key.copyWith(endpoint: 'https://example.test/v1/chat/completions'),
          false,
        ).available,
        false,
      );
      expect(directorAccessFor(AuthMode.token, key, true).proxy, true);
      expect(
        directorAccessFor(
          AuthMode.token,
          key.copyWith(joinPaid: false),
          false,
        ).available,
        false,
      );
      expect(
        directorAnlasEstimate(DirectorTool.removeBackground, 1024, 1024),
        65,
      );
      expect(directorAnlasEstimate(DirectorTool.emotion, 1024, 1024), 20);
      expect(directorAnlasEstimate(DirectorTool.pixelSnap, 4096, 4096), 0);
    },
  );

  test(
    'local pixel grid detection rebuilds cells and retains transparency',
    () {
      final source = pixelPicture();
      final grid = detectPixelGrid(source, horizontal: true);
      expect(grid.step, 6);
      final bytes = Uint8List.fromList(img.encodePng(source));
      final output = snapDirectorPixels(
        bytes,
        const DirectorOptions(
          tool: DirectorTool.pixelSnap,
          palette: DirectorPalette.off,
          avoidOverRefining: true,
        ),
      );
      expect((output.width, output.height), (16, 12));
      final result = img.decodePng(output.bytes)!;
      expect(result.getPixel(0, 0).a, 0);
      expect(result.getPixel(5, 5).r, source.getPixel(33, 33).r);
      final enlarged = snapDirectorPixels(
        bytes,
        const DirectorOptions(
          tool: DirectorTool.pixelSnap,
          palette: DirectorPalette.custom,
          colors: 8,
          upscale: true,
        ),
      );
      expect((enlarged.width, enlarged.height), (96, 72));
      expect(img.decodePng(enlarged.bytes)!.getPixel(0, 0).a, 0);
    },
  );

  test(
    'pixel grid rejects uniform images instead of pretending to transform them',
    () {
      expect(
        () => snapDirectorPixels(
          png(64, 64),
          const DirectorOptions(tool: DirectorTool.pixelSnap),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'fractional rescaling and blurred pixel boundaries still recover a grid',
    () {
      final source = pixelPicture(scale: 1);
      for (final width in [88, 96]) {
        final resized = img.copyResize(
          source,
          width: width,
          height: width * 3 ~/ 4,
          interpolation: img.Interpolation.nearest,
        );
        final blurred = img.gaussianBlur(resized, radius: 1);
        final output = snapDirectorPixels(
          Uint8List.fromList(img.encodePng(blurred)),
          const DirectorOptions(
            tool: DirectorTool.pixelSnap,
            palette: DirectorPalette.off,
            avoidOverRefining: true,
          ),
        );
        expect(output.width, inInclusiveRange(15, 17));
        expect(output.height, inInclusiveRange(11, 13));
      }
    },
  );

  test(
    'custom palette limits opaque colors while automatic only merges nearby colors',
    () {
      final source = pixelPicture();
      final bytes = Uint8List.fromList(img.encodePng(source));
      final limited = snapDirectorPixels(
        bytes,
        const DirectorOptions(
          tool: DirectorTool.pixelSnap,
          palette: DirectorPalette.custom,
          colors: 8,
          avoidOverRefining: true,
        ),
      );
      final image = img.decodePng(limited.bytes)!;
      final colors = {
        for (final p in image)
          if (p.a > 0) '${p.r},${p.g},${p.b}',
      };
      expect(colors.length, lessThanOrEqualTo(8));
      final gradient = img.Image(width: 100, height: 80);
      for (final p in gradient) {
        p.setRgb(p.x * 2, p.y * 3, p.x + p.y);
      }
      expect(detectPixelGrid(gradient, horizontal: true).step, 1);
    },
  );

  test(
    'augment endpoint accepts 201, preserves payload and never retries failure',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var calls = 0;
      Map<String, dynamic>? request;
      String? path, auth;
      server.listen((incoming) async {
        calls++;
        path = incoming.uri.path;
        auth = incoming.headers.value('authorization');
        request =
            jsonDecode(await utf8.decoder.bind(incoming).join())
                as Map<String, dynamic>;
        incoming.response.statusCode = calls == 1 ? 201 : 402;
        incoming.response.add(
          calls == 1 ? png(16, 16) : utf8.encode('private request echo'),
        );
        await incoming.response.close();
      });
      final client = NaiClient(base: 'http://127.0.0.1:${server.port}');
      final body = {
        ...const DirectorOptions(
          tool: DirectorTool.emotion,
          emotion: 'sad',
          defry: 2,
        ).requestParameters(),
        'image': 'test-image',
        'width': 1024,
        'height': 1024,
      };
      final response = await client.augmentImage(
        token: 'test-only',
        parameters: body,
      );
      expect(response, png(16, 16));
      expect(path, '/ai/augment-image');
      expect(auth, 'Bearer test-only');
      expect(request, body);
      await expectLater(
        client.augmentImage(token: 'test-only', parameters: body),
        throwsA(
          isA<NaiException>().having(
            (e) => e.message,
            'message',
            isNot(contains('private')),
          ),
        ),
      );
      expect(calls, 2);
    },
  );
}
