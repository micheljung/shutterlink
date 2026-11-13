import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:shutterlink/feature/sessions/clock_sync_state.dart';
import 'package:shutterlink/feature/sessions/session_code.dart';
import 'package:shutterlink/feature/sessions/session_collector.dart';
import 'package:shutterlink/feature/sessions/wordlist.dart';
import 'package:shutterlink/ptpip/canon_eos.dart';
import 'package:shutterlink/ptpip/dataset.dart';
import 'package:shutterlink/upload/network_policy.dart';
import 'package:shutterlink/upload/tcp_connector.dart';
import 'package:shutterlink_server/shutterlink_server.dart';

import '../fakes/fake_sessions_credentials.dart';
import '../ptpip/fake_camera.dart';

class _IdleTimer implements Timer {
  @override
  bool get isActive => false;

  @override
  int get tick => 0;

  @override
  void cancel() {}
}

const _token = 'e2e-upload-token';
const _photoSize = 4096;
const _firstShotHandle = 0x1000;
const _drainPoll = Duration(milliseconds: 20);
const _drainTimeout = Duration(seconds: 10);
final _zipLocalHeader = ascii.encode('PK\x03\x04');

int _count(List<int> haystack, List<int> needle) {
  var count = 0;
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length && match; j++) {
      match = haystack[i + j] == needle[j];
    }
    if (match) count++;
  }
  return count;
}

void main() {
  final t0 = DateTime.utc(2026, 11, 13, 10);
  const cameraLag = Duration(seconds: 90);
  const delta = Duration(milliseconds: 500);
  late DateTime now;
  late Directory root;
  late ShutterlinkServer server;
  late FakeCamera camera;
  final client = HttpClient();

  Future<Uint8List> get(String path) async {
    final request = await client.getUrl(server.url.resolve(path));
    final response = await request.close();
    final builder = BytesBuilder(copy: false);
    await response.forEach(builder.add);
    return builder.takeBytes();
  }

  setUp(() async {
    now = t0;
    root = await Directory.systemTemp.createTemp('sessions_e2e');
    server = await ShutterlinkServer.start(
      dataDir: Directory(p.join(root.path, 'server')),
      uploadToken: _token,
      clock: Clock(() => now),
    );
    camera = FakeCamera(
      pairedGuids: [pairedGuid],
      objects: FakeCamera.defaultObjects()
          .where((object) => object.format == PtpObjectFormat.association)
          .toList(),
      devicePropertyValues: {
        PtpDeviceProperty.dateTime: ptpStringValue(
          formatPtpDateTime(t0.subtract(cameraLag).toLocal()),
        ),
      },
    );
    await camera.start();
  });

  tearDown(() async {
    await camera.stop();
    await server.close();
    await root.delete(recursive: true);
  });

  test('photos reach exactly their Session gallery', () async {
    final clock = Clock(() => now);
    File file(String name) => File(p.join(root.path, 'app', name));
    SharedPreferences.setMockInitialValues({
      SettingsRepository.sessionsEnabledKey: true,
      SettingsRepository.sessionsServerUrlKey: server.url.toString(),
    });
    final settings = SettingsRepository(await SharedPreferences.getInstance());
    final sessions = SessionRepository(
      file(SessionRepository.fileName),
      clock: clock,
      codes: SessionCodeGenerator(words: effWords),
    );
    final seen = SessionSeenStore(
      file(SessionSeenStore.fileName),
      clock: clock,
    );
    final queue = SessionsUploadQueue(
      file(SessionsUploadQueue.fileName),
      clock: clock,
    );
    final network = ValueNotifier(NetworkStatus.offline);
    final transport = TunnelTransport(
      network,
      connector: directNetworkConnector,
    );
    final worker = UploadWorker(
      queue: queue,
      transport: transport,
      sessions: sessions,
      settings: settings,
      credentials: FakeSessionsCredentials(_token),
      clock: clock,
      timer: (_, _) => _IdleTimer(),
    );
    addTearDown(() async {
      await worker.dispose();
      transport.dispose();
      network.dispose();
    });

    worker.start();
    final cameraClient = await connectTo(camera);
    final cameraKey = cameraKeyOf(cameraClient.deviceInfo);
    final clockSync = ClockSyncCubit(
      client: cameraClient,
      cameraKey: cameraKey,
      sessions: sessions,
      seen: seen,
      clock: clock,
    );
    await clockSync.start();
    expect(
      clockSync.state,
      const ClockResolved(ClockResolution.fresh, cameraLag),
    );
    final collector = SessionCollector(
      client: cameraClient,
      cameraKey: cameraKey,
      clockSync: clockSync,
      sessions: sessions,
      seen: seen,
      queue: queue,
      uploadDirectory: Directory(p.join(root.path, 'app', 'upload')),
      clock: clock,
      delay: (_) async {},
      timer: (_, _) => _IdleTimer(),
    )..start();

    Uint8List shoot(int seed) {
      final content = patternBytes(_photoSize, seed: seed);
      final handle = _firstShotHandle + seed;
      camera.addObject(
        FakeObject(
          handle: handle,
          format: PtpObjectFormat.exifJpeg,
          filename: 'IMG_$handle.JPG',
          parent: FakeCamera.folderHandle,
          captureDate: formatPtpDateTime(
            now.subtract(cameraLag + delta).toLocal(),
          ),
          content: content,
        ),
      );
      return content;
    }

    now = t0.add(const Duration(seconds: 10));
    final a = await sessions.start();
    now = t0.add(const Duration(seconds: 20));
    final photoA = shoot(1);
    now = t0.add(const Duration(seconds: 60));
    final b = await sessions.start();
    now = t0.add(const Duration(seconds: 70));
    final photoB = shoot(2);
    now = t0.add(const Duration(seconds: 100));
    await sessions.stop();
    now = t0.add(const Duration(seconds: 105));
    final trap = shoot(3);

    await collector.rescan();
    final queued = {
      for (final item in await queue.items()) item.photoKey: item.sessionCode,
    };
    final keyA = sha256.convert(photoA).toString();
    final keyB = sha256.convert(photoB).toString();
    final keyTrap = sha256.convert(trap).toString();
    expect(queued, {keyA: a.code, keyB: b.code});
    expect(worker.status.value, UploadWorkerStatus.waitingForNetwork);
    expect(utf8.decode(await get('/s/${a.code}')), isNot(contains(keyA)));

    await collector.dispose();
    await clockSync.close();
    await cameraClient.close();
    network.value = const NetworkStatus.unrestricted();
    final deadline = DateTime.now().add(_drainTimeout);
    while ((await queue.items()).isNotEmpty) {
      expect(DateTime.now().isBefore(deadline), isTrue);
      await Future<void>.delayed(_drainPoll);
    }

    final pageA = utf8.decode(await get('/s/${a.code}'));
    final pageB = utf8.decode(await get('/s/${b.code}'));
    expect(pageA, contains('/p/$keyA.jpg'));
    expect(pageA, isNot(contains(keyB)));
    expect(pageB, contains('/p/$keyB.jpg'));
    expect(pageB, isNot(contains(keyA)));
    expect(pageA + pageB, isNot(contains(keyTrap)));
    expect(await get('/s/${a.code}/p/$keyA.jpg'), photoA);

    final zip = await get('/s/${a.code}/all.zip');
    expect(_count(zip, _zipLocalHeader), 1);
    expect(_count(zip, photoA), 1);
    expect(_count(zip, photoB) + _count(zip, trap), 0);
  });
}
