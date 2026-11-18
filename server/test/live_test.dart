import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shutterlink_server/src/app.dart';
import 'package:test/test.dart';

import 'support.dart';

const String _codeC = 'lunar-magic-noble-ocean';
const String _codeD = 'quiet-river-stone-tiger';
const Duration _day = Duration(days: 1);
const Duration _lockTimeout = Duration(seconds: 1);

Request _poll(String code, [String? ifNoneMatch]) => Request(
  'GET',
  origin.resolve('/s/$code/photos.json'),
  headers: {'if-none-match': ?ifNoneMatch},
);

String _headerText(Map<String, String> headers) => ([
  for (final MapEntry(:key, :value) in headers.entries) '$key: $value',
]..sort()).join('\n');

int _generationOf(String etag) =>
    int.parse(etag.substring(etag.lastIndexOf('-') + 1, etag.length - 1));

void main() {
  late TestApp server;

  setUp(() async => server = await TestApp.open());
  tearDown(() => server.close());

  Directory sessionDir(String code) => Directory(
    p.join(server.dataDir.path, 'sessions', server.app.store.dirName(code)),
  );

  Future<String> etagOf(String code) async {
    final response = await server.call(_poll(code));
    await bodyBytes(response);
    return response.headers['etag']!;
  }

  test('lists photos in snapshot order with their preview state', () async {
    final ready = jpegBytes(1);
    final failed = photoBytes(2);
    final pending = jpegBytes(3);
    for (final bytes in [pending, failed, ready]) {
      await server.upload(codeA, bytes);
    }
    await server.awaitPreviews();
    final photos = p.join(sessionDir(codeA).path, 'photos');
    for (final (i, bytes) in [ready, failed, pending].indexed) {
      await File(p.join(photos, '${keyOf(bytes)}.jpg'))
          .setLastModified(t0.add(Duration(minutes: i)));
    }
    await for (final entity in Directory(
      p.join(sessionDir(codeA).path, 'previews'),
    ).list()) {
      if (p.basename(entity.path).startsWith(keyOf(pending))) {
        await entity.delete();
      }
    }

    final response = await server.call(_poll(codeA));
    expect(response.statusCode, 200);
    expect(response.headers['content-type'], 'application/json');
    expect(response.headers['cache-control'], 'no-cache');
    expect(
      await bodyText(response),
      jsonEncode({
        'count': 3,
        'photos': [
          {'key': keyOf(ready), 'state': 'ready', 'w': 48, 'h': 48},
          {'key': keyOf(failed), 'state': 'failed'},
          {'key': keyOf(pending), 'state': 'pending'},
        ],
      }),
    );
  });

  test('answers 304 for the current ETag without a snapshot', () async {
    await server.upload(codeA, photoBytes(1));
    await server.awaitPreviews();
    final etag = await etagOf(codeA);
    expect(etag, '"${server.app.store.bootId}-${_generationOf(etag)}"');
    expect(await etagOf(codeA), etag);

    final calls = server.app.store.snapshotCalls;
    for (final header in [
      etag,
      'W/$etag',
      '"other", W/$etag',
      '$etag , "other"',
    ]) {
      final response = await server.call(_poll(codeA, header));
      expect(response.statusCode, 304, reason: header);
      expect(response.headers['etag'], etag);
      expect(response.headers['cache-control'], 'no-cache');
      expect(await bodyBytes(response), isEmpty);
    }
    expect(server.app.store.snapshotCalls, calls);

    final stale = await server.call(_poll(codeA, '"other"'));
    expect(stale.statusCode, 200);
    expect(stale.headers['etag'], etag);
    await bodyBytes(stale);
  });

  test('the generation grows on upload, ready and failed', () async {
    final generations = <int>[];
    Future<void> record() async =>
        generations.add(_generationOf(await etagOf(codeA)));

    final store = server.app.store;
    final queue = store.onCommitted;
    store.onCommitted = null;
    final failed = photoBytes(1);
    await server.upload(codeA, failed);
    await record();
    await server.upload(codeA, failed);
    await record();
    await store.markFailed(store.dirName(codeA), keyOf(failed));
    await record();

    store.onCommitted = queue;
    await server.upload(codeA, jpegBytes(2));
    await record();
    await server.awaitPreviews();
    await record();

    expect(generations[1], generations[0]);
    expect(generations[2], greaterThan(generations[1]));
    expect(generations[3], greaterThan(generations[2]));
    expect(generations[4], greaterThan(generations[3]));
  });

  test('a throwing onCommitted does not fail the upload', () async {
    final committed = <String>[];
    server.app.store.onCommitted = (_, key) {
      committed.add(key);
      throw StateError('boom');
    };
    final bytes = photoBytes(1);
    expect((await server.upload(codeA, bytes)).statusCode, 201);
    expect((await server.upload(codeA, bytes)).statusCode, 200);
    expect(committed, [keyOf(bytes)]);
  });

  test('unknown, empty, expired and purged codes look the same', () async {
    final store = server.app.store;
    await server.upload(codeA, photoBytes(1));
    await server.upload(_codeC, photoBytes(3));
    await server.awaitPreviews();
    final purgedEtag = await etagOf(codeA);

    server.now.now = t0.add(_day * 31);
    final expiredName = store.dirName(_codeC);
    expect(await store.zipLocks.acquire(expiredName, _lockTimeout), isTrue);
    await store.purgeExpired();
    store.zipLocks.release(expiredName);
    expect(await sessionDir(codeA).exists(), isFalse);
    expect(await sessionDir(_codeC).exists(), isTrue);

    await Directory(p.join(sessionDir(_codeD).path, 'photos'))
        .create(recursive: true);
    await File(p.join(sessionDir(_codeD).path, 'created'))
        .writeAsString(server.now.now.toIso8601String());

    final answers = <(int, String, String)>{};
    for (final code in [unknownCode, _codeD, _codeC, codeA]) {
      for (final header in [
        null,
        '"${store.bootId}-0"',
        purgedEtag,
        'W/$purgedEtag',
      ]) {
        final response = await server.call(_poll(code, header));
        expect(response.headers['etag'], isNull);
        answers.add((
          response.statusCode,
          _headerText(response.headers),
          await bodyText(response),
        ));
      }
    }
    expect(answers, hasLength(1));
    final (status, headers, body) = answers.single;
    expect(status, 200);
    expect(headers, contains('cache-control: no-cache'));
    expect(body, '{"count":0,"photos":[]}');
  });

  test('purge early returns keep the generation', () async {
    final store = server.app.store;
    await server.upload(codeA, photoBytes(1));
    await server.awaitPreviews();
    final etag = await etagOf(codeA);

    server.now.now = t0.add(_day * 29);
    await store.purgeExpired();
    expect(await etagOf(codeA), etag);

    server.now.now = t0.add(_day * 31);
    final name = store.dirName(codeA);
    expect(await store.zipLocks.acquire(name, _lockTimeout), isTrue);
    await store.purgeExpired();
    store.zipLocks.release(name);
    server.now.now = t0;
    expect(await etagOf(codeA), etag);
  });

  test('an ETag from an earlier boot gets one 200', () async {
    await server.upload(codeA, photoBytes(1));
    await server.awaitPreviews();
    final old = await etagOf(codeA);

    final reopened = await ShutterlinkApp.open(
      dataDir: server.dataDir,
      uploadToken: uploadToken,
      clock: Clock(server.now.call),
    );
    addTearDown(reopened.close);
    final first = await reopened.handler(_poll(codeA, old));
    expect(first.statusCode, 200);
    final fresh = first.headers['etag']!;
    expect(fresh, isNot(old));
    expect(fresh, startsWith('"${reopened.store.bootId}-'));
    await bodyBytes(first);

    final second = await reopened.handler(_poll(codeA, fresh));
    expect(second.statusCode, 304);
  });
}
