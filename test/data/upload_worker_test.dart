import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/session_repository.dart';
import 'package:shutterlink/data/sessions_upload_queue.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/data/upload_transport.dart';
import 'package:shutterlink/data/upload_worker.dart';
import 'package:shutterlink/upload/network_policy.dart';
import 'package:shutterlink/upload/tcp_connector.dart';

import '../fakes/fake_sessions_credentials.dart';

class _FakeTransport implements UploadTransport {
  _FakeTransport(this._client);

  final http.Client _client;

  @override
  final ValueNotifier<bool> available = ValueNotifier(true);

  @override
  http.Client client() => _client;
}

class _FakeTimer implements Timer {
  _FakeTimer(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const serverUrl = 'https://photos.example.com';
  const token = 'secret';
  const html = '<html><body>413 Request Entity Too Large</body></html>';
  final t0 = DateTime.utc(2026, 11, 13, 10);
  final expiresAt = t0.add(const Duration(days: 30));
  final created = http.Response(
    '{"expiresAt":"${expiresAt.toIso8601String()}"}',
    HttpStatus.created,
  );

  late Directory root;
  late DateTime now;
  late SessionsUploadQueue queue;
  late SessionRepository sessions;
  late SettingsRepository settings;
  late List<_FakeTimer> timers;
  late List<http.Request> requests;
  late FutureOr<http.Response> Function(http.Request request) respond;
  late MockClient client;
  late String code;
  var photoCount = 0;

  UploadWorker worker(UploadTransport transport) => UploadWorker(
    queue: queue,
    transport: transport,
    sessions: sessions,
    settings: settings,
    credentials: FakeSessionsCredentials(token),
    clock: Clock(() => now),
    random: Random(1),
    timer: (delay, callback) {
      final timer = _FakeTimer(delay, callback);
      timers.add(timer);
      return timer;
    },
  );

  Future<UploadItem> enqueue([String? content]) async {
    final file = File(p.join(root.path, 'upload', '${photoCount++}.jpg'));
    await file.parent.create(recursive: true);
    file.writeAsStringSync(content ?? 'photo $photoCount');
    return (await queue.enqueue(sessionCode: code, file: file))!;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('worker');
    now = t0;
    queue = SessionsUploadQueue(
      File(p.join(root.path, SessionsUploadQueue.fileName)),
      clock: Clock(() => now),
    );
    sessions = SessionRepository(
      File(p.join(root.path, SessionRepository.fileName)),
      clock: Clock(() => now),
    );
    code = (await sessions.start()).code;
    SharedPreferences.setMockInitialValues({
      SettingsRepository.sessionsEnabledKey: true,
      SettingsRepository.sessionsServerUrlKey: serverUrl,
    });
    settings = SettingsRepository(await SharedPreferences.getInstance());
    timers = [];
    requests = [];
    respond = (_) => created;
    client = MockClient((request) async {
      requests.add(request);
      return respond(request);
    });
  });

  tearDown(() => root.delete(recursive: true));

  test('uploads, records expiresAt and removes the item', () async {
    final uploads = worker(_FakeTransport(client));
    final item = await enqueue();

    await uploads.drain();

    expect(
      requests.single.url.path,
      endsWith('/$code/photos/${item.photoKey}'),
    );
    expect(await queue.items(), isEmpty);
    expect((await sessions.active())!.expiresAt, expiresAt);
    expect(uploads.status.value, UploadWorkerStatus.idle);
  });

  group('over the tunnel', () {
    const offlineStatus = NetworkStatus.offline;
    const cameraWifi = NetworkStatus([
      NetworkInfo(
        transport: NetworkTransport.wifi,
        validated: false,
        metered: false,
      ),
    ]);
    const cellular = NetworkStatus([
      NetworkInfo(
        transport: NetworkTransport.wifi,
        validated: false,
        metered: false,
      ),
      NetworkInfo(
        transport: NetworkTransport.cellular,
        validated: true,
        metered: true,
      ),
    ]);
    late ValueNotifier<NetworkStatus> network;
    late TunnelTransport transport;

    setUp(() {
      network = ValueNotifier(offlineStatus);
      transport = TunnelTransport(
        network,
        connector: directNetworkConnector,
        newClient: () => client,
      );
    });

    tearDown(() {
      transport.dispose();
      network.dispose();
    });

    test('waits without a validated network and uploads over mobile data '
        'while bound to the camera', () async {
      final uploads = worker(transport)..start();
      await enqueue();
      await uploads.drain();
      expect(requests, isEmpty);
      expect(uploads.status.value, UploadWorkerStatus.waitingForNetwork);

      network.value = cameraWifi;
      await uploads.drain();
      expect(requests, isEmpty);

      network.value = cellular;
      await settle();
      await uploads.drain();
      expect(requests, hasLength(1));
      expect(await queue.items(), isEmpty);
      await uploads.dispose();
    });
  });

  group('binding mid-request', () {
    late _FakeTransport transport;
    late Completer<http.Response> response;

    setUp(() {
      transport = _FakeTransport(client);
      response = Completer();
      respond = (_) => response.future;
    });

    test('cancels nothing and starts no new request', () async {
      final uploads = worker(transport)..start();
      await enqueue();
      final draining = uploads.drain();
      while (requests.isEmpty) {
        await settle();
      }

      transport.available.value = false;
      await enqueue();
      response.complete(created);
      await draining;

      expect(requests, hasLength(1));
      expect(await queue.items(), hasLength(1));
      await uploads.dispose();
    });

    test('a failure while bound keeps attempts', () async {
      final uploads = worker(transport);
      await enqueue();
      final draining = uploads.drain();
      while (requests.isEmpty) {
        await settle();
      }

      transport.available.value = false;
      response.completeError(const SocketException('network changed'));
      await draining;

      final item = (await queue.items()).single;
      expect(item.attempts, 0);
      expect(item.nextAttemptAt, t0);
      expect(requests, hasLength(1));

      respond = (_) => created;
      transport.available.value = true;
      await uploads.drain();
      expect(await queue.items(), isEmpty);
    });
  });

  test('retries a socket error with backoff, then succeeds', () async {
    final uploads = worker(_FakeTransport(client));
    respond = (_) => throw const SocketException('unreachable');
    await enqueue();

    await uploads.drain();

    final item = (await queue.items()).single;
    expect(item.attempts, 1);
    expect(item.lastStatus, startsWith('socket'));
    final retryIn = item.nextAttemptAt.difference(t0);
    expect(
      retryIn,
      greaterThanOrEqualTo(initialRetryDelay * (1 - retryJitter)),
    );
    expect(retryIn, lessThanOrEqualTo(initialRetryDelay * (1 + retryJitter)));
    expect(timers.last.delay, retryIn);

    respond = (_) => created;
    now = item.nextAttemptAt;
    timers.last.fire();
    await uploads.drain();

    expect(requests, hasLength(2));
    expect(await queue.items(), isEmpty);
  });

  test('caps the retry delay', () async {
    final uploads = worker(_FakeTransport(client));
    respond = (_) => http.Response('', HttpStatus.serviceUnavailable);
    final item = await enqueue();
    await queue.reschedule(item.copyWith(attempts: 20));

    await uploads.drain();

    final retried = (await queue.items()).single;
    expect(retried.attempts, 21);
    expect(
      retried.nextAttemptAt.difference(t0),
      lessThanOrEqualTo(maxRetryDelay * (1 + retryJitter)),
    );
  });

  test('410 expired marks the Session expired and counts it', () async {
    final uploads = worker(_FakeTransport(client));
    respond = (_) => http.Response('{"error":"expired"}', HttpStatus.gone);
    await enqueue();

    await uploads.drain();

    expect(await queue.items(), isEmpty);
    expect(await queue.expiredCount(), 1);
    expect((await sessions.all()).single.expired, isTrue);
  });

  test('a tagged server error drops the item', () async {
    final uploads = worker(_FakeTransport(client));
    respond = (_) => http.Response(
      '{"error":"too_large"}',
      HttpStatus.requestEntityTooLarge,
    );
    await enqueue();
    await enqueue();

    await uploads.drain();

    expect(await queue.items(), isEmpty);
    expect(await queue.droppedCount(), 2);
  });

  test('401 pauses the queue until woken', () async {
    final uploads = worker(_FakeTransport(client));
    respond = (_) => http.Response('', HttpStatus.unauthorized);
    await enqueue();
    await enqueue();

    await uploads.drain();
    await uploads.drain();

    expect(requests, hasLength(1));
    expect(uploads.status.value, UploadWorkerStatus.unauthorized);
    expect(await queue.items(), hasLength(2));

    respond = (_) => created;
    await uploads.wake();
    expect(await queue.items(), isEmpty);
  });

  test('a bare 413 pauses, then re-probes after maxRetryDelay', () async {
    final uploads = worker(_FakeTransport(client));
    respond = (_) => http.Response(html, HttpStatus.requestEntityTooLarge);
    await enqueue();

    await uploads.drain();

    expect(uploads.status.value, UploadWorkerStatus.serverConfiguration);
    expect(await queue.droppedCount(), 0);
    final item = (await queue.items()).single;
    expect(item.attempts, 0);
    expect(item.lastStatus, '413');
    await uploads.drain();
    expect(requests, hasLength(1));

    respond = (_) => created;
    now = t0.add(maxRetryDelay);
    expect(timers.last.delay, maxRetryDelay);
    timers.last.fire();
    await uploads.drain();

    expect(requests, hasLength(2));
    expect(await queue.items(), isEmpty);
    expect(uploads.status.value, UploadWorkerStatus.idle);
  });

  test('does nothing until a server URL and token are set', () async {
    await settings.setSessionsServerUrl(null);
    final uploads = worker(_FakeTransport(client));
    await enqueue();

    await uploads.drain();

    expect(requests, isEmpty);
    expect(uploads.status.value, UploadWorkerStatus.notConfigured);

    await settings.setSessionsServerUrl(serverUrl);
    await uploads.wake();
    expect(requests, hasLength(1));
  });

  test('resumes the persisted queue on start', () async {
    await enqueue();
    final uploads = worker(_FakeTransport(client))..start();

    await uploads.drain();

    expect(requests, hasLength(1));
    expect(await queue.items(), isEmpty);
    await uploads.dispose();
  });

  test('wakes on enqueue after start', () async {
    final uploads = worker(_FakeTransport(client))..start();
    await uploads.drain();

    await enqueue();
    while (requests.isEmpty) {
      await settle();
    }
    await uploads.drain();

    expect(await queue.items(), isEmpty);
    await uploads.dispose();
  });

  test('a failure while available counts an attempt', () async {
    final uploads = worker(_FakeTransport(client));
    respond = (_) => http.Response('', HttpStatus.tooManyRequests);
    await enqueue();

    await uploads.drain();

    expect((await queue.items()).single.attempts, 1);
  });
}
