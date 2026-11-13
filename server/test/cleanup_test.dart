import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shutterlink_server/src/cleanup.dart';
import 'package:shutterlink_server/src/pages.dart';
import 'package:test/test.dart';

import 'support.dart';

const Duration _day = Duration(days: 1);

void main() {
  late TestApp server;

  setUp(() async => server = await TestApp.open());
  tearDown(() => server.close());

  Directory dir(String name) => Directory(p.join(server.dataDir.path, name));

  test('keeps a Session until expiry and deletes it afterwards', () async {
    final bytes = photoBytes(1);
    await server.upload(codeA, bytes);

    server.now.now = t0.add(_day * 29);
    await server.app.store.purgeExpired();
    expect(
      await bodyText(await server.get('/s/$codeA')),
      contains(keyOf(bytes)),
    );

    server.now.now = t0.add(_day * 31);
    final cleanup = await Cleanup.start(server.app.store);
    await cleanup.stop();
    expect(await dir('sessions').list().isEmpty, isTrue);
    expect(await bodyBytes(await server.get('/s/$codeA')), onTheirWayPage);
    expect(
      await bodyBytes(await server.get('/s/$codeA/p/${keyOf(bytes)}.jpg')),
      onTheirWayPage,
    );
    final put = await server.upload(codeA, photoBytes(2));
    expect(put.statusCode, 410);
  });

  test('removes orphan tmp files older than the cleanup interval', () async {
    final stale = File(p.join(dir('tmp').path, 'stale'));
    final fresh = File(p.join(dir('tmp').path, 'fresh'));
    await stale.writeAsString('x');
    await fresh.writeAsString('x');
    await stale.setLastModified(t0.subtract(cleanupInterval * 2));
    await fresh.setLastModified(t0.subtract(cleanupInterval ~/ 2));
    await server.app.store.purgeExpired();
    expect(await stale.exists(), isFalse);
    expect(await fresh.exists(), isTrue);
  });

  test('drops the tombstone 60 days after the purge', () async {
    await server.upload(codeA, photoBytes(1));
    server.now.now = t0.add(_day * 31);
    await server.app.store.purgeExpired();
    expect(await dir('tombstones').list().length, 1);

    server.now.now = t0.add(_day * 90);
    await server.app.store.purgeExpired();
    expect((await server.upload(codeA, photoBytes(2))).statusCode, 410);

    server.now.now = t0.add(_day * 92);
    await server.app.store.purgeExpired();
    expect(await dir('tombstones').list().isEmpty, isTrue);
  });

  test('purge racing a PUT leaves no partial Session', () async {
    for (var i = 0; i < 5; i++) {
      final code = 'race-run-number-${'abcde'[i]}';
      server.now.now = t0;
      await server.upload(code, photoBytes(100 + i));
      server.now.now = t0.add(_day * 31);
      final put = server.upload(code, photoBytes(200 + i));
      final purge = server.app.store.purgeExpired();
      expect((await put).statusCode, anyOf(201, 410));
      await purge;
      expect(await server.app.store.snapshot(code), isNull);
      expect(await dir('sessions').list().isEmpty, isTrue);
      expect(await dir('tmp').list().isEmpty, isTrue);
    }
  });

  test('skips Sessions with a zip download in progress', () async {
    await server.upload(codeA, photoBytes(1));
    final zip = await server.get('/s/$codeA/all.zip');
    server.now.now = t0.add(_day * 31);
    await server.app.store.purgeExpired();
    expect(await dir('sessions').list().isEmpty, isFalse);
    await bodyBytes(zip);
    await server.app.store.purgeExpired();
    expect(await dir('sessions').list().isEmpty, isTrue);
  });
}
