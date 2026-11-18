import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:clock/clock.dart';
import 'package:image/image.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink_server/src/limits.dart' as limits;
import 'package:shutterlink_server/src/previews.dart';
import 'package:shutterlink_server/src/store.dart';
import 'package:test/test.dart';

import 'support.dart';

const String _codeC = 'lunar-magic-noble-ocean';
const Duration _day = Duration(days: 1);
const Duration _pollInterval = Duration(milliseconds: 5);
const Duration _pollTimeout = Duration(seconds: 30);
const int _largePhotoBytes = 1 << 24;
const int _largeSessionBytes = 1 << 26;

const int _sof0 = 0xC0;
const int _sof2 = 0xC2;

Uint8List _jpeg(int width, int height, {int seed = 0, int? orientation}) {
  final image = Image(width: width, height: height);
  for (final pixel in image) {
    pixel
      ..r = (pixel.x + seed) & 0xFF
      ..g = (pixel.y * 2) & 0xFF
      ..b = (pixel.x + pixel.y + seed) & 0xFF;
  }
  if (orientation != null) image.exif.imageIfd.orientation = orientation;
  return encodeJpg(image, quality: 90);
}

List<int> _segment(int marker, int payloadLength) => [
  0xFF,
  marker,
  (payloadLength + 2) >> 8,
  (payloadLength + 2) & 0xFF,
  ...List.filled(payloadLength, 0),
];

List<int> _frame(int marker, int width, int height) => [
  0xFF,
  marker,
  0x00,
  0x11,
  0x08,
  height >> 8,
  height & 0xFF,
  width >> 8,
  width & 0xFF,
  0x03,
  ...List.filled(9, 1),
];

/// SOI, APP1, whatever comes [before] the frame, then a SOF with no scan.
Uint8List _header(
  int marker,
  int width,
  int height, {
  List<int> before = const [],
}) => Uint8List.fromList([
  0xFF,
  0xD8,
  ..._segment(0xE1, 16),
  ...before,
  ..._frame(marker, width, height),
]);

Future<void> _until(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(_pollTimeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met in time');
    await Future<void>.delayed(_pollInterval);
  }
}

void main() {
  late Uint8List baseline;
  late Uint8List small;
  late Uint8List rotated;
  late Uint8List progressive;

  setUpAll(() async {
    baseline = _jpeg(3000, 2000);
    small = _jpeg(300, 200);
    rotated = _jpeg(600, 400, orientation: 6);
    progressive = await File('test/fixtures/progressive.jpg').readAsBytes();
  });

  group('readJpegHeader', () {
    test('reads a baseline frame', () {
      final header = readJpegHeader(_header(_sof0, 6000, 4000))!;
      expect((header.width, header.height), (6000, 4000));
      expect(header.progressive, isFalse);
    });

    test('reads an extended sequential frame', () {
      final header = readJpegHeader(_header(0xC1, 640, 480))!;
      expect(
        (header.width, header.height, header.progressive),
        (640, 480, false),
      );
    });

    test('flags a progressive frame', () {
      final header = readJpegHeader(_header(_sof2, 640, 480))!;
      expect(header.progressive, isTrue);
    });

    for (final marker in [0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD]) {
      test('refuses SOF 0x${marker.toRadixString(16)}', () {
        expect(readJpegHeader(_header(marker, 640, 480)), isNull);
      });
    }

    test('refuses truncated input and a missing SOI', () {
      final full = _header(_sof0, 640, 480);
      expect(readJpegHeader(Uint8List(0)), isNull);
      expect(readJpegHeader(Uint8List.sublistView(full, 0, 1)), isNull);
      expect(
        readJpegHeader(Uint8List.sublistView(full, 0, full.length - 1)),
        isNull,
      );
      expect(readJpegHeader(Uint8List.sublistView(full, 2)), isNull);
    });

    test('skips a long APP segment', () {
      final header = readJpegHeader(
        _header(_sof0, 640, 480, before: _segment(0xE2, 60000)),
      );
      expect(header?.width, 640);
    });

    for (final (name, marker) in [
      ('DHT', 0xC4),
      ('DAC', 0xCC),
      ('JPG', 0xC8),
    ]) {
      test('skips $name before the frame', () {
        final header = readJpegHeader(
          _header(_sof0, 640, 480, before: _segment(marker, 20)),
        );
        expect((header?.width, header?.height), (640, 480));
      });
    }

    test('skips fill bytes between segments', () {
      final header = readJpegHeader(
        _header(
          _sof0,
          640,
          480,
          before: [0xFF, 0xFF, 0xFF, ..._segment(0xDB, 67), 0xFF, 0xFF],
        ),
      );
      expect(header?.height, 480);
    });

    test('skips standalone RST and TEM markers', () {
      final header = readJpegHeader(
        _header(_sof0, 640, 480, before: [0xFF, 0xD3, 0xFF, 0x01]),
      );
      expect(header?.width, 640);
    });

    test('refuses a segment running past the end', () {
      final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 0x10, 0x00]);
      expect(readJpegHeader(bytes), isNull);
    });

    test('refuses a scan before any frame', () {
      final bytes = _header(_sof0, 640, 480, before: _segment(0xDA, 10));
      expect(readJpegHeader(bytes), isNull);
    });

    test('refuses random bytes', () {
      expect(readJpegHeader(Uint8List.fromList(photoBytes(1))), isNull);
    });
  });

  group('renderPreview', () {
    late int decodes;
    Image? countingDecode(
      Uint8List bytes, {
      required int scale,
      required int maxPixels,
    }) {
      decodes++;
      return null;
    }

    setUp(() => decodes = 0);

    test('refuses an oversized frame without decoding it', () {
      const side = 9000;
      final oversized = limits.previewMaxPixels ~/ side + 1;
      expect(
        renderPreview(_header(_sof0, side, oversized), decode: countingDecode),
        isNull,
      );
      final progressiveSide = limits.previewMaxProgressivePixels ~/ side + 1;
      expect(
        renderPreview(
          _header(_sof2, side, progressiveSide),
          decode: countingDecode,
        ),
        isNull,
      );
      expect(decodes, 0);

      renderPreview(_header(_sof0, 640, 480), decode: countingDecode);
      expect(decodes, 1);
    });

    test('decodes large frames at a reduced scale', () {
      final scales = <int>[];
      Image? recordScale(
        Uint8List bytes, {
        required int scale,
        required int maxPixels,
      }) {
        scales.add(scale);
        return null;
      }

      for (final (w, h) in [
        (8192, 5464),
        (6000, 4000),
        (3000, 2000),
        (20000, 1000),
      ]) {
        renderPreview(_header(_sof0, w, h), decode: recordScale);
      }
      expect(scales, [4, 2, 1, 2]);
    });

    test('fits the view and the thumbnail', () {
      final rendition = renderPreview(baseline)!;
      final view = decodeJpg(rendition.view)!;
      final thumbnail = decodeJpg(rendition.thumbnail)!;
      expect((view.width, view.height), (viewLongEdge, 1365));
      expect((rendition.width, rendition.height), (view.width, view.height));
      expect((thumbnail.width, thumbnail.height), (600, thumbnailShortEdge));
    });

    test('never upscales', () {
      final rendition = renderPreview(small)!;
      expect((rendition.width, rendition.height), (300, 200));
      final thumbnail = decodeJpg(rendition.thumbnail)!;
      expect((thumbnail.width, thumbnail.height), (300, 200));
    });

    test('applies the orientation', () {
      final rendition = renderPreview(rotated)!;
      expect((rendition.width, rendition.height), (400, 600));
      final thumbnail = decodeJpg(rendition.thumbnail)!;
      expect((thumbnail.width, thumbnail.height), (400, 600));
    });

    test('strips EXIF', () {
      expect(String.fromCharCodes(rotated), contains('Exif'));
      final rendition = renderPreview(rotated)!;
      for (final bytes in [rendition.view, rendition.thumbnail]) {
        expect(String.fromCharCodes(bytes), isNot(contains('Exif')));
        expect(decodeJpg(bytes)!.exif.isEmpty, isTrue);
      }
    });

    test('handles a progressive file, and refuses one above its limit', () {
      expect(readJpegHeader(progressive)!.progressive, isTrue);
      final rendition = renderPreview(progressive)!;
      expect((rendition.width, rendition.height), (1200, 800));
      expect(decodeJpg(rendition.thumbnail)!.height, thumbnailShortEdge);

      expect(
        renderPreview(
          progressive,
          maxProgressivePixels: 1200 * 800 - 1,
          decode: countingDecode,
        ),
        isNull,
      );
      expect(decodes, 0);
    });

    test('refuses random bytes', () {
      expect(renderPreview(Uint8List.fromList(photoBytes(1))), isNull);
    });
  });

  group('app', () {
    late TestApp server;

    setUp(
      () async => server = await TestApp.open(
        maxPhotoBytes: _largePhotoBytes,
        maxSessionBytes: _largeSessionBytes,
      ),
    );
    tearDown(() => server.close());

    Directory previewsDir(String code) => Directory(
      p.join(
        server.dataDir.path,
        'sessions',
        server.app.store.dirName(code),
        'previews',
      ),
    );

    Future<List<String>> previewNames(String code) async => [
      await for (final entity in previewsDir(code).list())
        p.basename(entity.path),
    ]..sort();

    Future<PreviewInfo> previewOf(String code) async =>
        (await server.app.store.snapshot(code))!.photos.single.preview;

    test('writes both renditions and a ready marker', () async {
      expect((await server.upload(codeA, baseline)).statusCode, 201);
      await server.awaitPreviews();

      final key = keyOf(baseline);
      expect(await previewNames(codeA), [
        '$key.2048x1365.ready',
        '$key.t.jpg',
        '$key.v.jpg',
      ]);
      final preview = await previewOf(codeA);
      expect(preview.status, PreviewStatus.ready);
      expect((preview.width, preview.height), (2048, 1365));

      final view = await server.app.store.previewFile(
        codeA,
        key,
        PreviewKind.view,
      );
      expect(view!.expiresAt, t0.add(limits.defaultRetention));
      expect(decodeJpg(await view.file.readAsBytes())!.width, 2048);
      expect(
        await server.app.store.previewFile(codeB, key, PreviewKind.view),
        isNull,
      );
      expect(
        await server.app.store.previewFile(
          codeA,
          keyOf(small),
          PreviewKind.thumbnail,
        ),
        isNull,
      );
    });

    test('random bytes are marked failed', () async {
      final bytes = photoBytes(1);
      await server.upload(codeA, bytes);
      await server.awaitPreviews();

      expect(await previewNames(codeA), ['${keyOf(bytes)}.failed']);
      expect((await previewOf(codeA)).status, PreviewStatus.failed);
    });

    test('a frame above maxPixels is marked failed', () async {
      final bytes = _header(_sof0, 10000, limits.previewMaxPixels ~/ 10000 + 1);
      await server.upload(codeA, bytes);
      await server.awaitPreviews();

      expect((await previewOf(codeA)).status, PreviewStatus.failed);
    });

    test('originals and the zip stay byte-identical', () async {
      await server.upload(codeA, baseline);
      await server.awaitPreviews();
      expect((await previewOf(codeA)).status, PreviewStatus.ready);

      final key = keyOf(baseline);
      final original = await server.get('/s/$codeA/p/$key.jpg');
      expect(await bodyBytes(original), baseline);
      final zip = await server.get('/s/$codeA/all.zip');
      final archive = ZipDecoder().decodeBytes(await bodyBytes(zip));
      expect(archive.files.map((f) => f.name), ['$key.jpg']);
      expect(archive.files.single.content, baseline);
    });

    test('previews do not count toward the quota', () async {
      await server.close();
      server = await TestApp.open(
        maxPhotoBytes: _largePhotoBytes,
        maxSessionBytes: baseline.length + small.length,
      );
      await server.upload(codeA, baseline);
      await server.awaitPreviews();
      expect((await previewOf(codeA)).status, PreviewStatus.ready);

      expect((await server.upload(codeA, small)).statusCode, 201);
    });

    test('a purge removes the previews', () async {
      await server.upload(codeA, small);
      await server.awaitPreviews();
      expect(await previewsDir(codeA).list().isEmpty, isFalse);

      server.now.now = t0.add(_day * 31);
      await server.app.store.purgeExpired();
      expect(await previewsDir(codeA).parent.exists(), isFalse);
    });
  });

  group('queue', () {
    late Directory dataDir;
    late MutableClockSource now;
    final queues = <PreviewQueue>[];

    setUp(() async {
      dataDir = await tempDataDir();
      now = MutableClockSource(t0);
    });

    tearDown(() async {
      for (final queue in queues) {
        await queue.close();
      }
      queues.clear();
      await dataDir.delete(recursive: true);
    });

    Future<SessionStore> openStore() => SessionStore.open(
      dataDir,
      clock: Clock(now.call),
      maxPhotoBytes: _largePhotoBytes,
      maxSessionBytes: _largeSessionBytes,
    );

    PreviewQueue queueFor(
      SessionStore store, {
      int concurrency = limits.previewConcurrency,
      Future<void>? holdScan,
      Future<void>? holdWorkers,
    }) {
      final queue = PreviewQueue(
        store,
        concurrency: concurrency,
        holdScan: holdScan,
        holdWorkers: holdWorkers,
      );
      queues.add(queue);
      return queue;
    }

    Future<void> put(SessionStore store, String code, List<int> bytes) async {
      final result = await store.put(code, keyOf(bytes), chunked(bytes));
      expect(result.error, isNull);
    }

    Directory sessionDir(SessionStore store, String code) =>
        Directory(p.join(dataDir.path, 'sessions', store.dirName(code)));

    File marker(SessionStore store, String code, String name) =>
        File(p.join(sessionDir(store, code).path, 'previews', name));

    Future<PreviewStatus> statusOf(SessionStore store, String code) async =>
        (await store.snapshot(code))!.photos.single.preview.status;

    test('backfill generates missing previews after a restart', () async {
      await put(await openStore(), codeA, small);

      final store = await openStore();
      final queue = queueFor(store);
      await queue.scan();
      await queue.idle;
      expect(await statusOf(store, codeA), PreviewStatus.ready);
    });

    test('one crashed attempt from an earlier boot is retried', () async {
      final first = await openStore();
      await put(first, codeA, small);
      await marker(first, codeA, '${keyOf(small)}.0badb007.attempt').create();

      final store = await openStore();
      final queue = queueFor(store);
      await queue.scan();
      await queue.idle;
      expect(await statusOf(store, codeA), PreviewStatus.ready);
      expect(
        await marker(first, codeA, '${keyOf(small)}.0badb007.attempt').exists(),
        isFalse,
      );
    });

    test('two crashed attempts mark the photo failed', () async {
      final first = await openStore();
      await put(first, codeA, small);
      for (final boot in ['0badb007', '0badb008']) {
        await marker(first, codeA, '${keyOf(small)}.$boot.attempt').create();
      }

      final store = await openStore();
      final queue = queueFor(store);
      await queue.scan();
      await queue.idle;
      expect(await statusOf(store, codeA), PreviewStatus.failed);
      expect(
        await sessionDir(store, codeA)
            .list(recursive: true)
            .where((e) => e.path.endsWith('.attempt'))
            .isEmpty,
        isTrue,
      );
    });

    test('attempts of the current boot are not crash evidence', () async {
      final store = await openStore();
      await put(store, codeA, small);
      await store.writeAttempt(store.dirName(codeA), keyOf(small));
      await store.writeAttempt(store.dirName(codeA), keyOf(small));
      await marker(store, codeA, '${keyOf(small)}.0badb007.attempt').create();

      final queue = queueFor(store);
      await queue.scan();
      await queue.idle;
      expect(await statusOf(store, codeA), PreviewStatus.ready);
    });

    test('the scan never fails a photo a live job is working on', () async {
      final store = await openStore();
      final release = Completer<void>();
      final queue = queueFor(store, holdScan: release.future);
      final scan = queue.scan();

      await put(store, codeA, baseline);
      final key = keyOf(baseline);
      final attempt = marker(store, codeA, '$key.${store.bootId}.attempt');
      await _until(
        () async =>
            await attempt.exists() ||
            await store
                .snapshot(codeA)
                .then(
                  (s) =>
                      s!.photos.single.preview.status != PreviewStatus.pending,
                ),
      );
      release.complete();
      await scan;
      await queue.idle;

      expect(await statusOf(store, codeA), PreviewStatus.ready);
      expect(await marker(store, codeA, '$key.failed').exists(), isFalse);
    });

    test('live photos come before backfill', () async {
      final first = await openStore();
      await put(first, codeB, _jpeg(64, 48, seed: 1));
      await put(first, _codeC, _jpeg(64, 48, seed: 2));

      final store = await openStore();
      final release = Completer<void>();
      final queue = queueFor(
        store,
        concurrency: 1,
        holdWorkers: release.future,
      );
      await queue.scan();
      await put(store, codeA, _jpeg(64, 48, seed: 3));
      final order = <String>[];
      store.onBump = (name, _) => order.add(name);
      release.complete();
      await queue.idle;

      expect(order, hasLength(3));
      expect(order.first, store.dirName(codeA));
      for (final code in [codeA, codeB, _codeC]) {
        expect(await statusOf(store, code), PreviewStatus.ready);
      }
    });

    test('live photos are generated newest first', () async {
      final store = await openStore();
      final release = Completer<void>();
      final queue = queueFor(
        store,
        concurrency: 1,
        holdWorkers: release.future,
      );
      final codes = [codeA, codeB, _codeC];
      for (final (i, code) in codes.indexed) {
        await put(store, code, _jpeg(64, 48, seed: i));
      }
      final order = <String>[];
      store.onBump = (name, _) => order.add(name);
      release.complete();
      await queue.idle;

      expect(order, [for (final code in codes.reversed) store.dirName(code)]);
    });

    test('an expired Session is skipped', () async {
      final first = await openStore();
      await put(first, codeA, small);
      now.now = t0.add(_day * 20);
      await put(first, codeB, small);

      now.now = t0.add(_day * 31);
      final store = await openStore();
      final queue = queueFor(store);
      await queue.scan();
      await queue.idle;

      final expired = Directory(
        p.join(sessionDir(store, codeA).path, 'previews'),
      );
      expect(await expired.list().isEmpty, isTrue);
      expect(store.generationOf(store.dirName(codeA)), isNull);
      expect(await statusOf(store, codeB), PreviewStatus.ready);
    });

    test('a purge during generation writes nothing', () async {
      final store = await openStore();
      final release = Completer<void>();
      final queue = queueFor(store, holdWorkers: release.future);
      await put(store, codeA, small);
      final name = store.dirName(codeA);
      now.now = t0.add(_day * 31);
      await store.purgeExpired();
      release.complete();
      await queue.idle;

      final thumbnail = store.newTmpFile()..writeAsBytesSync(small);
      final view = store.newTmpFile()..writeAsBytesSync(small);
      expect(
        await store.commitPreview(name, keyOf(small), thumbnail, view, 1, 1),
        isFalse,
      );
      expect(await store.markFailed(name, keyOf(small)), isFalse);
      expect(await store.writeAttempt(name, keyOf(small)), isFalse);

      expect(await sessionDir(store, codeA).exists(), isFalse);
      expect(store.generationOf(name), isNull);
      expect(await thumbnail.exists(), isFalse);
      expect(await view.exists(), isFalse);
    });

    test('close stops a held scan and queued jobs', () async {
      await put(await openStore(), codeA, small);
      final store = await openStore();
      final queue = queueFor(store, holdScan: Completer<void>().future);
      unawaited(queue.scan());
      queue.enqueueLive(store.dirName(codeA), keyOf(small));
      final closing = queue.close();
      queues.remove(queue);
      await closing.timeout(
        const Duration(seconds: 1),
        onTimeout: () => fail('close waited for the held scan'),
      );
      expect(await statusOf(store, codeA), PreviewStatus.pending);
    });

    test('close while a job writes its attempt leaves no marker', () async {
      await put(await openStore(), codeA, small);
      final store = await openStore();
      final queue = queueFor(store);
      queue.enqueueLive(store.dirName(codeA), keyOf(small));
      await Future<void>(() {});
      final closing = queue.close();
      queues.remove(queue);
      await closing;

      expect(await statusOf(store, codeA), PreviewStatus.pending);
      expect(
        await sessionDir(store, codeA)
            .list(recursive: true)
            .where((e) => e.path.endsWith('.attempt'))
            .isEmpty,
        isTrue,
      );
    });
  });

  group('generation', () {
    late Directory dataDir;
    late MutableClockSource now;
    late SessionStore store;
    late List<(String, int)> bumps;

    setUp(() async {
      dataDir = await tempDataDir();
      now = MutableClockSource(t0);
      store = await SessionStore.open(dataDir, clock: Clock(now.call));
      bumps = [];
      store.onBump = (name, generation) => bumps.add((name, generation));
    });

    tearDown(() => dataDir.delete(recursive: true));

    test('bumps on a new photo, a preview and a failure only', () async {
      final name = store.dirName(codeA);
      final bytes = photoBytes(1);
      final committed = <String>[];
      store.onCommitted = (_, key) => committed.add(key);
      expect(store.generationOf(name), isNull);

      await store.put(codeA, keyOf(bytes), chunked(bytes));
      final first = store.generationOf(name)!;
      await store.put(codeA, keyOf(bytes), chunked(bytes));
      expect(store.generationOf(name), first);
      expect(committed, [keyOf(bytes)]);

      final thumbnail = store.newTmpFile()..writeAsBytesSync(bytes);
      final view = store.newTmpFile()..writeAsBytesSync(bytes);
      await store.commitPreview(name, keyOf(bytes), thumbnail, view, 2, 1);
      final second = store.generationOf(name)!;
      await store.markFailed(name, keyOf(bytes));
      final third = store.generationOf(name)!;

      expect(first < second && second < third, isTrue);
      expect(bumps, [(name, first), (name, second), (name, third)]);
    });

    test('generations are never reused across Sessions', () async {
      final a = photoBytes(1);
      final b = photoBytes(2);
      await store.put(codeA, keyOf(a), chunked(a));
      await store.put(codeB, keyOf(b), chunked(b));
      expect(
        store.generationOf(store.dirName(codeB)),
        greaterThan(store.generationOf(store.dirName(codeA))!),
      );
    });

    test('a throwing onCommitted does not fail the upload', () async {
      store.onCommitted = (_, _) => throw StateError('boom');
      final bytes = photoBytes(1);
      final result = await store.put(codeA, keyOf(bytes), chunked(bytes));
      expect(result.error, isNull);
      expect(result.created, isTrue);
    });

    test('a purge removes the entry without a bump', () async {
      final name = store.dirName(codeA);
      final bytes = photoBytes(1);
      await store.put(codeA, keyOf(bytes), chunked(bytes));
      bumps.clear();

      now.now = t0.add(_day * 29);
      await store.purgeExpired();
      expect(store.generationOf(name), isNotNull);

      now.now = t0.add(_day * 30);
      expect(store.generationOf(name), isNull);
      await store.purgeExpired();
      now.now = t0;
      expect(store.generationOf(name), isNull);
      expect(bumps, isEmpty);
    });

    test('the scan seeds a generation without a bump', () async {
      final bytes = photoBytes(1);
      await store.put(codeA, keyOf(bytes), chunked(bytes));
      await store.markFailed(store.dirName(codeA), keyOf(bytes));
      await store.put(codeB, keyOf(bytes), chunked(bytes));
      await store.markFailed(store.dirName(codeB), keyOf(bytes));
      await Directory(p.join(dataDir.path, 'sessions', store.dirName(_codeC)))
          .create();

      final reopened = await SessionStore.open(dataDir, clock: Clock(now.call));
      final seeded = <(String, int)>[];
      reopened.onBump = (name, generation) => seeded.add((name, generation));
      expect(reopened.bootId, isNot(store.bootId));
      expect(reopened.generationOf(reopened.dirName(codeA)), isNull);

      final queue = PreviewQueue(reopened);
      await queue.scan();
      await queue.idle;
      await queue.close();

      final a = reopened.generationOf(reopened.dirName(codeA));
      final b = reopened.generationOf(reopened.dirName(codeB));
      expect(a, isNotNull);
      expect(b, isNot(a));
      expect(reopened.generationOf(reopened.dirName(_codeC)), isNull);
      expect(seeded, isEmpty);
    });

    test('snapshot calls are counted', () async {
      expect(store.snapshotCalls, 0);
      await store.snapshot(codeA);
      await store.snapshot(codeB);
      expect(store.snapshotCalls, 2);
    });
  });
}
