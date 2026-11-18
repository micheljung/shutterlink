import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shutterlink_server/shutterlink_server.dart';
import 'package:shutterlink_server/src/app.dart';
import 'package:shutterlink_server/src/doorbell.dart';
import 'package:shutterlink_server/src/limits.dart' as limits;
import 'package:test/test.dart';

import 'support.dart';

const String _codeC = 'lunar-magic-noble-ocean';
const String _codeD = 'quiet-river-stone-tiger';
const Duration _day = Duration(days: 1);
const Duration _lockTimeout = Duration(seconds: 1);
const Duration _waitBound = Duration(seconds: 5);
const Duration _pollInterval = Duration(milliseconds: 5);
const Duration _socketTick = Duration(milliseconds: 200);
const int _ticks = 3;
const int _rings = 1000;

const String _opening = 'retry: 3000\n: open\n\n';
const String _keepAlive = ':\n\n';

String _event(String bootId, int generation) =>
    'id: $bootId-$generation\ndata: $generation\n\n';

String _headerText(Map<String, String> headers) => ([
  for (final MapEntry(:key, :value) in headers.entries) '$key: $value',
]..sort()).join('\n');

/// A valid-format code for each [i], distinct from the fixed test codes.
String _numberedCode(int i) =>
    'many-test-codes-${String.fromCharCodes([for (final d in '$i'.codeUnits) d - '0'.codeUnitAt(0) + 'a'.codeUnitAt(0)])}';

Future<void> _until(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(_waitBound);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(_pollInterval);
  }
}

class _Reader {
  _Reader(this.response) {
    subscription = response.read().listen(
      _bytes.addAll,
      onDone: () => done = true,
    );
  }

  final Response response;
  final List<int> _bytes = [];
  late final StreamSubscription<List<int>> subscription;
  bool done = false;

  String get text => utf8.decode(_bytes);

  /// Waits for at least [expected]'s length, then for anything that would
  /// follow in the same turn, and returns everything read so far.
  Future<String> read(String expected) async {
    await _until(() => _bytes.length >= expected.length, 'stream bytes');
    await pumpEventQueue();
    return text;
  }

  Future<void> cancel() => subscription.cancel();
}

void main() {
  late TestApp server;
  late StreamController<void> ticks;

  void tick([int times = 1]) {
    for (var i = 0; i < times; i++) {
      ticks.add(null);
    }
  }

  Future<void> openServer({
    int sseStreamsPerSession = limits.sseStreamsPerSession,
    int sseStreamsGlobal = limits.sseStreamsGlobal,
  }) async {
    ticks = StreamController<void>();
    server = await TestApp.open(
      keepAliveTicks: ticks.stream,
      sseStreamsPerSession: sseStreamsPerSession,
      sseStreamsGlobal: sseStreamsGlobal,
    );
  }

  tearDown(() => server.close());

  String bootId() => server.app.store.bootId;
  String name(String code) => server.app.store.dirName(code);

  Request eventsRequest(String code, {String? since, String? lastEventId}) =>
      Request(
        'GET',
        origin.resolve(
          since == null
              ? '/s/$code/events'
              : '/s/$code/events?since=${Uri.encodeQueryComponent(since)}',
        ),
        headers: {'last-event-id': ?lastEventId},
      );

  Future<_Reader> listen(
    String code, {
    String? since,
    String? lastEventId,
  }) async => _Reader(
    await server.call(
      eventsRequest(code, since: since, lastEventId: lastEventId),
    ),
  );

  Future<String> etagOf(String code) async {
    final response = await server.get('/s/$code/photos.json');
    await bodyBytes(response);
    return response.headers['etag']!;
  }

  int currentGeneration(String code) =>
      server.app.store.generationOf(name(code))!;

  Future<Response> uploadQuietly(String code, List<int> bytes) async {
    final store = server.app.store;
    final queue = store.onCommitted;
    store.onCommitted = null;
    try {
      return await server.upload(code, bytes);
    } finally {
      store.onCommitted = queue;
    }
  }

  group('doorbell', () {
    setUp(openServer);

    test('opens with the same bytes for everyone', () async {
      final reader = await listen(unknownCode);
      expect(reader.response.statusCode, 200);
      expect(await reader.read(_opening), _opening);
      expect(Doorbell.opening, utf8.encode(_opening));
      await reader.cancel();
    });

    test('rings once per commit, preview and failure', () async {
      final store = server.app.store;
      final reader = await listen(codeA);
      await reader.read(_opening);

      final events = <String>[];
      Future<void> expectRing() async {
        final etag = await etagOf(codeA);
        expect(etag, '"${bootId()}-${currentGeneration(codeA)}"');
        events.add(_event(bootId(), currentGeneration(codeA)));
        final expected = '$_opening${events.join()}';
        expect(await reader.read(expected), expected);
      }

      final first = photoBytes(1);
      await uploadQuietly(codeA, first);
      await expectRing();
      await uploadQuietly(codeA, first);
      tick();
      expect(
        await reader.read('$_opening${events.join()}$_keepAlive'),
        '$_opening${events.join()}$_keepAlive',
      );
      events.add(_keepAlive);

      await store.markFailed(name(codeA), keyOf(first));
      await expectRing();

      final view = store.newTmpFile()..writeAsBytesSync(first);
      final thumbnail = store.newTmpFile()..writeAsBytesSync(first);
      await store.commitPreview(
        name(codeA),
        keyOf(first),
        thumbnail,
        view,
        1,
        1,
      );
      await expectRing();
      await reader.cancel();
    });

    test('rings for a preview made by the queue', () async {
      final reader = await listen(codeA);
      await server.upload(codeA, jpegBytes(1));
      await server.awaitPreviews();
      final generation = currentGeneration(codeA);
      final expected =
          '$_opening${_event(bootId(), generation - 1)}'
          '${_event(bootId(), generation)}';
      expect(await reader.read(expected), expected);
      await reader.cancel();
    });

    test('stays silent on seeding and on a purge', () async {
      await server.upload(codeA, photoBytes(1));
      await server.awaitPreviews();

      final reopenedTicks = StreamController<void>();
      final reopened = await ShutterlinkApp.open(
        dataDir: server.dataDir,
        uploadToken: uploadToken,
        clock: Clock(server.now.call),
        keepAliveTicks: reopenedTicks.stream,
      );
      addTearDown(reopened.close);
      final reader = _Reader(await reopened.handler(eventsRequest(codeA)));
      final page = await reopened.handler(getRequest('/s/$codeA'));
      await bodyBytes(page);
      await reopened.previews.idle;
      final json = await reopened.handler(getRequest('/s/$codeA/photos.json'));
      await bodyBytes(json);

      server.now.now = t0.add(_day * 31);
      await reopened.store.purgeExpired();
      reopenedTicks.add(null);
      expect(await reader.read('$_opening$_keepAlive'), '$_opening$_keepAlive');
      await reader.cancel();
    });

    test('a ring right after the response is delivered', () async {
      await uploadQuietly(codeA, photoBytes(1));
      final since = (await etagOf(codeA)).replaceAll('"', '');
      final response = await server.call(eventsRequest(codeA, since: since));
      await uploadQuietly(codeA, photoBytes(2));
      final reader = _Reader(response);
      final expected = '$_opening${_event(bootId(), currentGeneration(codeA))}';
      expect(await reader.read(expected), expected);
      await reader.cancel();
    });

    test('a ring never waits for a paused listener', () async {
      await uploadQuietly(codeA, photoBytes(1));
      final reader = await listen(codeA);
      reader.subscription.pause();
      final generation = currentGeneration(codeA);
      for (var i = 0; i < _rings; i++) {
        server.app.doorbell.ring(name(codeA), generation);
      }
      final upload = await uploadQuietly(
        codeA,
        photoBytes(2),
      ).timeout(_waitBound);
      expect(upload.statusCode, 201);
      reader.subscription.resume();
      final expected =
          '$_opening${_event(bootId(), generation) * _rings}'
          '${_event(bootId(), currentGeneration(codeA))}';
      expect(await reader.read(expected), expected);
      await reader.cancel();
    });

    test('sets streaming headers and disables output buffering', () async {
      final reader = await listen(codeA);
      final response = reader.response;
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], 'text/event-stream');
      expect(response.headers['cache-control'], 'no-store');
      expect(response.headers['x-accel-buffering'], 'no');
      expect(response.headers['content-length'], isNull);
      for (final MapEntry(:key, :value) in securityHeaders.entries) {
        expect(response.headers[key], value);
      }
      expect(response.context['shelf.io.buffer_output'], isFalse);
      await reader.cancel();
    });

    test('an invalid code gets "on their way" and no stream', () async {
      final response = await server.get('/s/not-a-code/events');
      expect(response.headers['content-type'], startsWith('text/html'));
      await bodyBytes(response);
      expect(server.app.doorbell.openStreams, 0);
    });
  });

  group('catch-up', () {
    setUp(openServer);

    setUp(() => uploadQuietly(codeA, photoBytes(1)));

    Future<String> firstBytes({String? since, String? lastEventId}) async {
      final reader = await listen(
        codeA,
        since: since,
        lastEventId: lastEventId,
      );
      tick();
      final text = await reader.read('$_opening$_keepAlive');
      await reader.cancel();
      return text;
    }

    String caughtUp() =>
        '$_opening${_event(bootId(), currentGeneration(codeA))}$_keepAlive';
    String quiet() => '$_opening$_keepAlive';
    String current() => '${bootId()}-${currentGeneration(codeA)}';
    String stale() => '${bootId()}-${currentGeneration(codeA) - 1}';

    test('a stale Last-Event-ID gets one event', () async {
      expect(await firstBytes(lastEventId: stale()), caughtUp());
    });

    test('a stale since gets one event', () async {
      expect(await firstBytes(since: stale()), caughtUp());
    });

    test('Last-Event-ID wins over since', () async {
      expect(await firstBytes(lastEventId: current(), since: stale()), quiet());
    });

    test('a current ID gets none, in any notation', () async {
      for (final since in [current(), '"${current()}"', 'W/"${current()}"']) {
        expect(await firstBytes(since: since), quiet(), reason: since);
      }
      expect(await firstBytes(lastEventId: '"${current()}"'), quiet());
    });

    test('a quoted stale ID gets one event', () async {
      expect(await firstBytes(since: 'W/"${stale()}"'), caughtUp());
    });

    test('an ID from an earlier boot gets one event', () async {
      final old = current();
      final reopenedTicks = StreamController<void>();
      final reopened = await ShutterlinkApp.open(
        dataDir: server.dataDir,
        uploadToken: uploadToken,
        clock: Clock(server.now.call),
        keepAliveTicks: reopenedTicks.stream,
      );
      addTearDown(reopened.close);
      await reopened.previews.idle;
      final generation = reopened.store.generationOf(name(codeA))!;
      final reader = _Reader(
        await reopened.handler(eventsRequest(codeA, since: old)),
      );
      final expected = '$_opening${_event(reopened.store.bootId, generation)}';
      expect(await reader.read(expected), expected);
      await reader.cancel();
    });
  });

  group('uniformity', () {
    setUp(openServer);

    test('no code can be told apart without a matching ID', () async {
      final store = server.app.store;
      await server.upload(codeA, photoBytes(1));
      await server.upload(_codeC, photoBytes(3));
      await server.awaitPreviews();
      final purgedId = (await etagOf(codeA)).replaceAll('"', '');

      server.now.now = t0.add(_day * 31);
      final expiredName = name(_codeC);
      expect(await store.zipLocks.acquire(expiredName, _lockTimeout), isTrue);
      await store.purgeExpired();
      store.zipLocks.release(expiredName);
      expect(store.generationOf(name(codeA)), isNull);

      await server.upload(codeB, photoBytes(2));
      final emptyDir = Directory(
        p.join(server.dataDir.path, 'sessions', name(_codeD)),
      );
      await Directory(p.join(emptyDir.path, 'photos')).create(recursive: true);
      await File(p.join(emptyDir.path, 'created'))
          .writeAsString(server.now.now.toIso8601String());
      await server.awaitPreviews();

      final ids = [null, '${bootId()}-0', 'f00dfeed-123', purgedId];
      final readers = <(String, _Reader)>[
        ('existing Session, no ID', await listen(codeB)),
        for (final code in [unknownCode, _codeD, _codeC, codeA])
          for (final id in ids) ...[
            ('$code since=$id', await listen(code, since: id)),
            if (id != null)
              ('$code Last-Event-ID=$id', await listen(code, lastEventId: id)),
          ],
      ];
      tick(_ticks);
      final expected = '$_opening${_keepAlive * _ticks}';
      final statuses = <int>{};
      final headers = <String>{};
      for (final (label, reader) in readers) {
        expect(await reader.read(expected), expected, reason: label);
        statuses.add(reader.response.statusCode);
        headers.add(_headerText(reader.response.headers));
        await reader.cancel();
      }
      expect(statuses, {200});
      expect(headers, hasLength(1));
    });

    test('a purged Session turns into an unknown-code stream', () async {
      await uploadQuietly(codeA, photoBytes(1));
      final listening = await listen(codeA);
      final unknown = await listen(unknownCode);
      await listening.read(_opening);

      server.now.now = t0.add(_day * 31);
      await server.app.store.purgeExpired();
      expect(server.app.doorbell.openStreams, 2);
      server.app.doorbell.ring(name(codeA), 1);
      tick(_ticks);
      final expected = '$_opening${_keepAlive * _ticks}';
      expect(await listening.read(expected), expected);
      expect(await unknown.read(expected), expected);
      expect(listening.done, isFalse);
      await listening.cancel();
      await unknown.cancel();
    });
  });

  group('caps', () {
    test('the stream over the per-Session cap gets 204', () async {
      await openServer();
      await uploadQuietly(codeA, photoBytes(1));
      final readers = [
        for (var i = 0; i < limits.sseStreamsPerSession; i++)
          await listen(codeA),
      ];
      expect(readers.map((r) => r.response.statusCode).toSet(), {200});
      final over = await server.call(eventsRequest(codeA));
      expect(over.statusCode, 204);
      expect(await bodyBytes(over), isEmpty);
      expect((await listen(codeB)).response.statusCode, 200);

      await readers.first.cancel();
      final freed = await listen(codeA);
      expect(freed.response.statusCode, 200);
    });

    test('the stream over the global cap gets 204', () async {
      await openServer();
      final perCode = limits.sseStreamsPerSession;
      final codes = limits.sseStreamsGlobal ~/ perCode;
      final readers = [
        for (var c = 0; c < codes; c++)
          for (var i = 0; i < perCode; i++) await listen(_numberedCode(c)),
      ];
      expect(readers.map((r) => r.response.statusCode).toSet(), {200});
      expect(server.app.doorbell.openStreams, limits.sseStreamsGlobal);
      final over = await server.call(eventsRequest(_numberedCode(codes)));
      expect(over.statusCode, 204);
      await bodyBytes(over);

      await readers.last.cancel();
      expect(server.app.doorbell.openStreams, limits.sseStreamsGlobal - 1);
      final freed = await listen(_numberedCode(codes));
      expect(freed.response.statusCode, 200);
    });

    test('the 204 is the same for every code', () async {
      await openServer(sseStreamsPerSession: 0);
      await uploadQuietly(codeA, photoBytes(1));
      final answers = <(int, String, List<int>)>[];
      for (final code in [codeA, unknownCode]) {
        final response = await server.call(
          eventsRequest(code, since: '${bootId()}-0'),
        );
        answers.add((
          response.statusCode,
          _headerText(response.headers),
          await bodyBytes(response),
        ));
      }
      expect(answers.first.$1, 204);
      expect(answers.last.$1, answers.first.$1);
      expect(answers.last.$2, answers.first.$2);
      expect(answers.last.$3, answers.first.$3);
      expect(server.app.doorbell.openStreams, 0);
    });

    test('detached streams count only globally', () async {
      await openServer(sseStreamsPerSession: 2, sseStreamsGlobal: 3);
      await uploadQuietly(codeA, photoBytes(1));
      final detached = [await listen(codeA), await listen(codeA)];
      expect((await server.call(eventsRequest(codeA))).statusCode, 204);

      server.now.now = t0.add(_day * 31);
      await server.app.store.purgeExpired();
      expect((await listen(codeA)).response.statusCode, 200);
      expect((await server.call(eventsRequest(codeA))).statusCode, 204);
      expect(server.app.doorbell.openStreams, 3);

      await detached.first.cancel();
      expect((await listen(codeA)).response.statusCode, 200);
    });
  });

  test('close ends every stream and stops the ticks', () async {
    await openServer();
    await uploadQuietly(codeA, photoBytes(1));
    final detached = await listen(codeA);
    server.now.now = t0.add(_day * 31);
    await server.app.store.purgeExpired();
    final open = [detached, await listen(codeB), await listen(unknownCode)];
    expect(ticks.hasListener, isTrue);

    await server.app.close();
    expect(server.app.doorbell.openStreams, 0);
    expect(ticks.hasListener, isFalse);
    await _until(() => open.every((r) => r.done), 'streams to end');
    expect((await server.call(eventsRequest(codeB))).statusCode, 204);
  });

  test('a client that goes away frees its slot', () async {
    final dataDir = await tempDataDir();
    final shutterlink = await ShutterlinkServer.start(
      dataDir: dataDir,
      uploadToken: uploadToken,
      keepAliveTicks: Stream<void>.periodic(_socketTick),
    );
    server = await TestApp.open();
    addTearDown(() async {
      await shutterlink.close();
      await dataDir.delete(recursive: true);
    });

    final client = HttpClient();
    final request = await client.getUrl(
      shutterlink.url.resolve('/s/$codeA/events'),
    );
    final response = await request.close();
    expect(response.statusCode, 200);
    expect(response.headers.value('content-type'), 'text/event-stream');
    expect(response.headers.value('transfer-encoding'), 'chunked');
    final first = await response.first;
    expect(utf8.decode(first), _opening);
    expect(shutterlink.app.doorbell.openStreams, 1);

    client.close(force: true);
    await _until(
      () => shutterlink.app.doorbell.openStreams == 0,
      'the slot to free',
    );
  });
}
