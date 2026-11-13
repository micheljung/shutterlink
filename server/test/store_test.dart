import 'dart:io';

import 'package:clock/clock.dart';
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

  test('secret is owner-only', () async {
    final mode = (await File('${dataDir.path}/secret').stat()).modeString();
    expect(mode, 'rw-------');
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
}
