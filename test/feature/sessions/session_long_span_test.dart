import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/session_repository.dart';
import 'package:shutterlink/data/session_seen_store.dart';
import 'package:shutterlink/data/sessions_upload_queue.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/data/upload_transport.dart';
import 'package:shutterlink/data/upload_worker.dart';
import 'package:shutterlink/feature/sessions/clock_sync_cubit.dart';
import 'package:shutterlink/feature/sessions/session_collector.dart';
import 'package:shutterlink/feature/sessions/sessions_config.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_sessions_credentials.dart';

class _Transport implements UploadTransport {
  _Transport(this._client);

  final http.Client _client;

  @override
  final ValueNotifier<bool> available = ValueNotifier(true);

  @override
  http.Client client() => _client;
}

class _IdleTimer implements Timer {
  @override
  bool get isActive => false;

  @override
  int get tick => 0;

  @override
  void cancel() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day0 = DateTime.utc(2026, 11, 13, 10);
  const cameraLag = Duration(seconds: 90);
  late Directory root;
  late DateTime now;
  late FakeCameraClient client;
  late SessionRepository sessions;
  late SessionSeenStore seen;
  late SessionsUploadQueue queue;
  late UploadWorker worker;
  late List<http.BaseRequest> requests;
  late String cameraKey;
  DateTime? firstUploadAt;

  CameraObject shot(int handle, DateTime phoneTime) => cameraObject(
    handle,
    'IMG_$handle.JPG',
    captureDate: phoneTime.subtract(cameraLag).toLocal(),
  );

  Future<void> connectAndCollect() async {
    client.cameraTimeValue = now.subtract(cameraLag);
    final clockSync = ClockSyncCubit(
      client: client,
      cameraKey: cameraKey,
      sessions: sessions,
      seen: seen,
      clock: Clock(() => now),
    );
    await clockSync.start();
    final collector = SessionCollector(
      client: client,
      cameraKey: cameraKey,
      clockSync: clockSync,
      sessions: sessions,
      seen: seen,
      queue: queue,
      uploadDirectory: Directory(p.join(root.path, 'upload')),
      clock: Clock(() => now),
      delay: (_) async {},
      timer: (_, _) => _IdleTimer(),
    )..start();
    await collector.rescan();
    await collector.dispose();
    await clockSync.close();
    await worker.drain();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('long_span');
    now = day0;
    client = FakeCameraClient([]);
    cameraKey = cameraKeyOf(client.deviceInfo);
    sessions = SessionRepository(
      File(p.join(root.path, SessionRepository.fileName)),
      clock: Clock(() => now),
    );
    seen = SessionSeenStore(
      File(p.join(root.path, SessionSeenStore.fileName)),
      clock: Clock(() => now),
    );
    queue = SessionsUploadQueue(
      File(p.join(root.path, SessionsUploadQueue.fileName)),
      clock: Clock(() => now),
    );
    SharedPreferences.setMockInitialValues({
      SettingsRepository.sessionsEnabledKey: true,
      SettingsRepository.sessionsServerUrlKey: 'https://photos.example.com',
    });
    requests = [];
    firstUploadAt = null;
    worker = UploadWorker(
      queue: queue,
      transport: _Transport(
        MockClient((request) async {
          requests.add(request);
          final expiresAt = (firstUploadAt ??= now).add(retention);
          return http.Response(
            '{"expiresAt":"${expiresAt.toIso8601String()}"}',
            HttpStatus.created,
          );
        }),
      ),
      sessions: sessions,
      settings: SettingsRepository(await SharedPreferences.getInstance()),
      credentials: FakeSessionsCredentials('token'),
      clock: Clock(() => now),
      timer: (_, _) => _IdleTimer(),
    );
  });

  tearDown(() async {
    await worker.dispose();
    await root.delete(recursive: true);
  });

  test('late connects upload once and never leak the sync photo', () async {
    final a = await sessions.start();
    final photo = shot(1, day0.add(const Duration(minutes: 10)));
    final syncPhoto = shot(2, day0.add(const Duration(minutes: 20)));
    client.objects.addAll([photo, syncPhoto]);
    await seen.markExcluded(cameraKey, [
      SessionSeenStore.keyOf(cameraKey, syncPhoto),
    ]);
    now = day0.add(const Duration(hours: 1));
    await sessions.stop();

    now = day0.add(const Duration(days: 29));
    await connectAndCollect();
    expect(client.requestedOffsets.keys, [photo.handle]);
    expect(requests, hasLength(1));
    expect(requests.single.url.path, contains(a.code));
    expect(await queue.items(), isEmpty);

    now = day0.add(const Duration(days: 31));
    final neverQueued = shot(3, day0.add(const Duration(minutes: 30)));
    client.objects.add(neverQueued);
    await connectAndCollect();
    expect(client.requestedOffsets.keys, [photo.handle]);
    expect(requests, hasLength(1));

    for (final day in [61, 91]) {
      now = day0.add(Duration(days: day));
      await connectAndCollect();
      expect(client.requestedOffsets.keys, [photo.handle], reason: 'day $day');
      expect(requests, hasLength(1), reason: 'day $day');
      expect(
        await seen.stateOf(SessionSeenStore.keyOf(cameraKey, syncPhoto)),
        SeenState.excluded,
        reason: 'day $day',
      );
    }
    expect(
      await seen.stateOf(SessionSeenStore.keyOf(cameraKey, photo)),
      isNull,
      reason: 'queued entries are pruned after the queue max age',
    );
    expect((await sessions.all()).single.isRetainedAt(now), isFalse);
  });
}
