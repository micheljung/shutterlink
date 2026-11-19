import 'dart:io';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink_server/src/store.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory dataDir;
  late MutableClockSource now;
  late SessionStore store;

  setUp(() async {
    dataDir = await tempDataDir();
    now = MutableClockSource(t0);
    store = await SessionStore.open(
      dataDir,
      clock: Clock(now.call),
      maxPhotoBytes: 4096,
      maxSessionBytes: 5000,
    );
  });

  tearDown(() => dataDir.delete(recursive: true));

  test('stores a verified photo and reports expiry', () async {
    final bytes = photoBytes(1);
    final result = await store.put(codeA, keyOf(bytes), chunked(bytes));
    expect(result.error, isNull);
    expect(result.created, isTrue);
    expect(result.expiresAt, t0.add(const Duration(days: 30)));

    now.now = t0.add(const Duration(hours: 1));
    final again = await store.put(codeA, keyOf(bytes), chunked(bytes));
    expect(again.created, isFalse);
    expect(again.expiresAt, t0.add(const Duration(days: 30)));

    final snapshot = await store.snapshot(codeA);
    expect(snapshot!.photos.map((p) => p.key), [keyOf(bytes)]);
    expect(await snapshot.photos.single.file.readAsBytes(), bytes);
  });

  test('secret is owner-only and leaves no tmp file', () async {
    final mode = (await File('${dataDir.path}/secret').stat()).modeString();
    expect(mode, 'rw-------');
    expect(await Directory('${dataDir.path}/tmp').list().isEmpty, isTrue);
  });

  test('a secret of the wrong length stops the server', () async {
    final secret = File('${dataDir.path}/secret');
    final original = await secret.readAsBytes();
    await secret.writeAsBytes(original.sublist(1));

    await expectLater(SessionStore.open(dataDir), throwsStateError);
    expect(await secret.readAsBytes(), original.sublist(1));
  });

  test('photo reads only the requested file of a live Session', () async {
    final bytes = photoBytes(1);
    await store.put(codeA, keyOf(bytes), chunked(bytes));

    final photo = await store.photo(codeA, keyOf(bytes));
    expect(photo!.size, bytes.length);
    expect(await photo.file.readAsBytes(), bytes);
    expect(await store.photo(codeA, keyOf(photoBytes(2))), isNull);
    expect(await store.photo(codeB, keyOf(bytes)), isNull);
    expect(await store.photo(codeA, '../secret'), isNull);
  });

  test('created is written before the first photo', () async {
    final bytes = photoBytes(1);
    await store.put(codeA, keyOf(bytes), chunked(bytes));
    final session = Directory(
      '${dataDir.path}/sessions/${store.dirName(codeA)}',
    );
    final created = await File('${session.path}/created').stat();
    final photos = await Directory('${session.path}/photos').stat();

    expect(created.changed.isAfter(photos.changed), isFalse);
  });

  test(
    'rejects too large and mismatching bodies, leaving no tmp files',
    () async {
      final big = photoBytes(2, 5000);
      expect(
        (await store.put(codeA, keyOf(big), chunked(big))).error,
        PutError.tooLarge,
      );
      final bytes = photoBytes(3);
      expect(
        (await store.put(codeA, keyOf(photoBytes(4)), chunked(bytes))).error,
        PutError.shaMismatch,
      );
      expect(await Directory('${dataDir.path}/tmp').list().isEmpty, isTrue);
      expect(await store.snapshot(codeA), isNull);
    },
  );

  test('concurrent uploads respect the session byte cap', () async {
    final photos = [for (var i = 0; i < 6; i++) photoBytes(10 + i, 2000)];
    final results = await Future.wait([
      for (final bytes in photos)
        store.put(codeA, keyOf(bytes), chunked(bytes)),
    ]);
    expect(results.where((r) => r.error == null), hasLength(2));
    expect(results.where((r) => r.error == PutError.sessionFull), hasLength(4));
    expect((await store.snapshot(codeA))!.photos, hasLength(2));
  });

  Directory sessionDir(String code) =>
      Directory(p.join(dataDir.path, 'sessions', store.dirName(code)));

  Future<void> put(String code, List<int> bytes) async {
    expect((await store.put(code, keyOf(bytes), chunked(bytes))).error, isNull);
  }

  group('deletePhoto', () {
    test('removes the original and its previews for good', () async {
      final kept = photoBytes(1);
      final deleted = photoBytes(2);
      await put(codeA, kept);
      await put(codeA, deleted);
      final key = keyOf(deleted);
      final previews = Directory(p.join(sessionDir(codeA).path, 'previews'));
      for (final name in [
        '$key.t.jpg',
        '$key.v.jpg',
        '$key.4x3.ready',
        '$key.failed',
        '$key.${store.bootId}.attempt',
        '${keyOf(kept)}.t.jpg',
      ]) {
        await File(p.join(previews.path, name)).create();
      }

      await store.deletePhoto(codeA, key);

      expect(await store.photo(codeA, key), isNull);
      expect(await store.previewFile(codeA, key, PreviewKind.view), isNull);
      expect((await store.snapshot(codeA))!.photos.map((p) => p.key), [
        keyOf(kept),
      ]);
      expect(await previews.list().map((e) => p.basename(e.path)).toList(), [
        '${keyOf(kept)}.t.jpg',
      ]);
      expect(
        await File(p.join(sessionDir(codeA).path, 'deleted', key)).exists(),
        isTrue,
      );
    });

    test('previews are served only while the original exists', () async {
      await put(codeA, photoBytes(1));
      final orphan = keyOf(photoBytes(2));
      await File(p.join(sessionDir(codeA).path, 'previews', '$orphan.t.jpg'))
          .create();
      expect(
        await store.previewFile(codeA, orphan, PreviewKind.thumbnail),
        isNull,
      );
    });

    test('a re-upload is accepted but not stored', () async {
      final bytes = photoBytes(1);
      await put(codeA, photoBytes(2));
      await put(codeA, bytes);
      await store.deletePhoto(codeA, keyOf(bytes));

      now.now = t0.add(const Duration(hours: 1));
      final again = await store.put(codeA, keyOf(bytes), chunked(bytes));
      expect(again.error, isNull);
      expect(again.created, isFalse);
      expect(again.expiresAt, t0.add(const Duration(days: 30)));
      expect(await store.photo(codeA, keyOf(bytes)), isNull);
      expect(await Directory('${dataDir.path}/tmp').list().isEmpty, isTrue);
    });

    test('the limits count only the remaining photos', () async {
      final first = photoBytes(1, 2000);
      await put(codeA, first);
      await put(codeA, photoBytes(2, 2000));
      final third = photoBytes(3, 2000);
      expect(
        (await store.put(codeA, keyOf(third), chunked(third))).error,
        PutError.sessionFull,
      );

      await store.deletePhoto(codeA, keyOf(first));
      await put(codeA, third);
      expect((await store.snapshot(codeA))!.photos, hasLength(2));
    });

    test('the photo cap counts only the remaining photos', () async {
      store = await SessionStore.open(
        dataDir,
        clock: Clock(now.call),
        maxSessionPhotos: 1,
      );
      final first = photoBytes(1);
      final second = photoBytes(2);
      await put(codeA, first);
      expect(
        (await store.put(codeA, keyOf(second), chunked(second))).error,
        PutError.sessionFull,
      );

      await store.deletePhoto(codeA, keyOf(first));
      await put(codeA, second);
    });

    test('bumps the generation once', () async {
      final bumps = <int>[];
      store.onBump = (_, generation) => bumps.add(generation);
      final bytes = photoBytes(1);
      await put(codeA, photoBytes(2));
      await put(codeA, bytes);
      bumps.clear();

      await store.deletePhoto(codeA, keyOf(bytes));
      await store.deletePhoto(codeA, keyOf(bytes));
      expect(bumps, [store.generationOf(store.dirName(codeA))]);
    });

    test('an unknown Session or photo is left alone', () async {
      final bytes = photoBytes(1);
      await put(codeA, bytes);

      await store.deletePhoto(codeB, keyOf(bytes));
      await store.deletePhoto(codeA, keyOf(photoBytes(2)));
      await store.deletePhoto(codeA, '../created');

      expect(await sessionDir(codeB).exists(), isFalse);
      expect(
        await Directory(p.join(sessionDir(codeA).path, 'deleted')).exists(),
        isFalse,
      );
      expect(await store.photo(codeA, keyOf(bytes)), isNotNull);
    });
  });

  group('deleteSession', () {
    test('removes the Session like an expiry', () async {
      final bytes = photoBytes(1);
      await put(codeA, bytes);
      await put(codeB, photoBytes(2));
      final purged = <String>[];
      store.onPurged = purged.add;

      await store.deleteSession(codeA);

      expect(await sessionDir(codeA).exists(), isFalse);
      expect(
        await File(p.join(dataDir.path, 'tombstones', store.dirName(codeA)))
            .readAsString(),
        t0.toIso8601String(),
      );
      expect(await store.snapshot(codeA), isNull);
      expect(await store.photo(codeA, keyOf(bytes)), isNull);
      expect(store.generationOf(store.dirName(codeA)), isNull);
      expect(purged, [store.dirName(codeA)]);
      expect(await store.snapshot(codeB), isNotNull);
      expect(await Directory('${dataDir.path}/tmp').list().isEmpty, isTrue);
      expect(
        (await store.put(codeA, keyOf(bytes), chunked(bytes))).error,
        PutError.expired,
      );
    });

    test('does not wait for a zip', () async {
      await put(codeA, photoBytes(1));
      final name = store.dirName(codeA);
      expect(await store.zipLocks.acquire(name, Duration.zero), isTrue);
      addTearDown(() => store.zipLocks.release(name));

      await store.deleteSession(codeA);
      expect(await sessionDir(codeA).exists(), isFalse);
    });

    test('a purge racing the deletion leaves the cleanup running', () async {
      await put(codeA, photoBytes(1));
      await put(codeB, photoBytes(2));
      now.now = t0.add(const Duration(days: 31));
      Future<void>? purging;
      store.onBump = (_, _) => purging ??= store.purgeExpired();

      await store.deleteSession(codeA);
      await purging;
      expect(await sessionDir(codeA).exists(), isFalse);
      expect(await sessionDir(codeB).exists(), isFalse);
    });

    test('an unknown Session gets no tombstone', () async {
      await store.deleteSession(codeB);
      expect(
        await Directory(p.join(dataDir.path, 'tombstones')).list().isEmpty,
        isTrue,
      );
      await put(codeB, photoBytes(1));
    });
  });

  test('the cleanup removes a directory left in tmp', () async {
    final leftover = Directory(p.join(dataDir.path, 'tmp', 'leftover'));
    await File(p.join(leftover.path, 'photos', 'a.jpg'))
        .create(recursive: true);
    now.now = DateTime.now().add(const Duration(hours: 2));
    await store.purgeExpired();
    expect(await leftover.exists(), isFalse);
  });
}
