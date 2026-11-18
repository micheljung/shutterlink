@TestOn('!windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink_server/src/limits.dart' as limits;
import 'package:test/test.dart';

import 'process_support.dart';
import 'support.dart';

const Duration _exitBound = Duration(seconds: 10);
const Duration _pollInterval = Duration(milliseconds: 5);
const Duration _readyBound = Duration(seconds: 60);

/// Close to `previewMaxPixels` and full of detail, so the preview job keeps
/// the JIT isolate busy for seconds.
const int _largeWidth = 9600;
const int _largeHeight = limits.previewMaxPixels ~/ _largeWidth - 1;
const int _largeQuality = 75;

Uint8List _largeJpeg() {
  final image = Image(width: _largeWidth, height: _largeHeight);
  for (final pixel in image) {
    final noise = (pixel.x * 73856093) ^ (pixel.y * 19349663);
    pixel
      ..r = noise & 0xFF
      ..g = (noise >> 8) & 0xFF
      ..b = (pixel.x + pixel.y) & 0xFF;
  }
  return encodeJpg(image, quality: _largeQuality, chroma: JpegChroma.yuv420);
}

Future<void> _upload(Uri url, List<int> bytes) async {
  final client = HttpClient();
  try {
    final put = await client.openUrl(
      'PUT',
      url.resolve('/api/sessions/$codeA/photos/${keyOf(bytes)}'),
    );
    put.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $uploadToken')
      ..contentLength = bytes.length;
    put.add(bytes);
    final response = await put.close();
    await response.drain<void>();
    expect(response.statusCode, HttpStatus.created);
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory dataDir;

  setUp(() async => dataDir = await tempDataDir());
  tearDown(() => dataDir.delete(recursive: true));

  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    test('exits with code 0 on $signal', () async {
      final server = await ServerProcess.start(dataDir);
      addTearDown(server.kill);

      server.process.kill(signal);

      final exitCode = await server.process.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('still running 10 s after $signal'),
      );
      expect(exitCode, 0, reason: server.stderr);
    });
  }

  group(
    'with a preview in flight',
    timeout: const Timeout(Duration(minutes: 2)),
    () {
      late Uint8List large;

      setUpAll(() => large = _largeJpeg());

      Future<List<String>> previewNames() async {
        final sessions = Directory(p.join(dataDir.path, 'sessions'));
        final session = await sessions.list().single;
        return [
          await for (final entity in Directory(
            p.join(session.path, 'previews'),
          ).list())
            p.basename(entity.path),
        ];
      }

      bool isMarker(String name) =>
          name.endsWith('.ready') || name.endsWith('.failed');

      test('SIGTERM leaves the photo pending for the next start', () async {
        final server = await ServerProcess.start(dataDir);
        addTearDown(server.kill);
        await _upload(server.url, large);

        var names = await previewNames();
        while (!names.any((n) => n.endsWith('.attempt') || isMarker(n))) {
          await Future<void>.delayed(_pollInterval);
          names = await previewNames();
        }
        expect(
          names.where(isMarker),
          isEmpty,
          reason: 'the preview finished before SIGTERM; grow the fixture',
        );
        expect(names, [matches(RegExp(r'^[0-9a-f]{64}\.[0-9a-f]+\.attempt$'))]);

        server.process.kill(ProcessSignal.sigterm);
        final exitCode = await server.process.exitCode.timeout(
          _exitBound,
          onTimeout: () => fail('still running $_exitBound after SIGTERM'),
        );
        expect(exitCode, 0, reason: server.stderr);
        expect(await previewNames(), isEmpty);

        final restarted = await ServerProcess.start(dataDir);
        addTearDown(restarted.kill);
        final deadline = DateTime.now().add(_readyBound);
        while (!(names = await previewNames()).any(isMarker)) {
          if (DateTime.now().isAfter(deadline)) {
            fail('no preview after restart');
          }
          await Future<void>.delayed(_pollInterval);
        }
        expect(names.where((n) => n.endsWith('.failed')), isEmpty);
        expect(names.where((n) => n.endsWith('.ready')), hasLength(1));
      });
    },
  );
}
