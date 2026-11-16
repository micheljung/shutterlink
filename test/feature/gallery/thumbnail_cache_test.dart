import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/gallery/thumbnail_cache.dart';

import '../../fakes/fake_camera_client.dart';

void main() {
  late Directory directory;
  late List<int> fetched;

  Future<Uint8List?> fetch(int handle) async {
    fetched.add(handle);
    return Uint8List.fromList([handle]);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('thumbs');
    fetched = [];
  });

  tearDown(() => directory.delete(recursive: true));

  test(
    'memory never exceeds the bound and evicts least recently used',
    () async {
      const bound = 3;
      final cache = ThumbnailCache(
        directory: directory,
        maxMemoryEntries: bound,
      );
      final objects = [
        for (var i = 0; i < 5; i++) cameraObject(i, 'IMG_$i.JPG'),
      ];

      for (final object in objects.take(bound)) {
        await cache.get(object, fetch);
      }
      await cache.get(objects.first, fetch);
      for (final object in objects.skip(bound)) {
        await cache.get(object, fetch);
        expect(cache.memoryEntryCount, lessThanOrEqualTo(bound));
      }

      expect(cache.memoryEntryCount, bound);
      expect(cache.peek(objects[0]), isNotNull);
      expect(cache.peek(objects[1]), isNull);
      expect(cache.peek(objects[2]), isNull);
    },
  );

  test('evicted thumbnails come back from disk without refetching', () async {
    final cache = ThumbnailCache(directory: directory, maxMemoryEntries: 1);
    final first = cameraObject(1, 'IMG_1.JPG');
    final second = cameraObject(2, 'IMG_2.JPG');

    await cache.get(first, fetch);
    await cache.get(second, fetch);
    final again = await cache.get(first, fetch);

    expect(again, [1]);
    expect(fetched, [1, 2]);
  });

  test('concurrent requests for one thumbnail fetch once', () async {
    final cache = ThumbnailCache(directory: directory);
    final object = cameraObject(7, 'IMG_7.JPG');

    await Future.wait([cache.get(object, fetch), cache.get(object, fetch)]);

    expect(fetched, [7]);
  });

  test('disk key changes with size and capture date', () {
    final a = cameraObject(1, 'IMG_1.JPG', size: 1);
    final b = cameraObject(1, 'IMG_1.JPG', size: 2);
    final c = cameraObject(
      1,
      'IMG_1.JPG',
      size: 1,
      captureDate: DateTime(2026),
    );

    expect({
      ThumbnailCache.cacheKey(a),
      ThumbnailCache.cacheKey(b),
      ThumbnailCache.cacheKey(c),
    }, hasLength(3));
  });

  group('quarter turns', () {
    final object = cameraObject(1, 'IMG_0001.JPG');

    test('are kept across runs, upright ones too', () async {
      final cache = ThumbnailCache(directory: directory);
      final other = cameraObject(2, 'IMG_0002.JPG');
      expect(cache.turnsOf(object), isNull);

      await cache.rememberTurns(object, 1);
      await cache.rememberTurns(other, 0);

      expect(cache.turnsOf(object), 1);
      final next = ThumbnailCache(directory: directory);
      expect(next.turnsOf(object), isNull);
      expect(await next.loadTurns(object), 1);
      expect(next.turnsOf(object), 1);
      expect(await next.loadTurns(other), 0);
    });

    test('changes bump the revision, repeats do not', () async {
      final cache = ThumbnailCache(directory: directory);
      var changes = 0;
      cache.turnsRevision.addListener(() => changes++);

      await cache.rememberTurns(object, 3);
      await cache.rememberTurns(object, 3);

      expect(changes, 1);
    });

    test('a photo of another size or date has its own', () async {
      final cache = ThumbnailCache(directory: directory);
      await cache.rememberTurns(object, 1);

      expect(
        await cache.loadTurns(cameraObject(1, 'IMG_0001.JPG', size: 11)),
        isNull,
      );
    });

    test('a damaged file counts as unknown', () async {
      final cache = ThumbnailCache(directory: directory);
      await cache.rememberTurns(object, 1);
      final file = File(
        '${directory.path}/${ThumbnailCache.cacheKey(object)}.turns',
      );

      for (final content in ['x', '7', '-1', '']) {
        await file.writeAsString(content);
        expect(
          await ThumbnailCache(directory: directory).loadTurns(object),
          isNull,
          reason: content,
        );
      }
    });
  });
}
