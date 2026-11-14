import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/session_repository.dart';
import 'package:shutterlink/data/session_seen_store.dart';
import 'package:shutterlink/data/sessions_prefetch.dart';
import 'package:shutterlink/data/sessions_upload_queue.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/live/ingest_coordinator.dart';
import 'package:shutterlink/feature/live/live_ingestor.dart';
import 'package:shutterlink/feature/sessions/clock_sync_cubit.dart';
import 'package:shutterlink/feature/sessions/clock_sync_state.dart';
import 'package:shutterlink/feature/sessions/session_collector.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/upload_queue.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/test_app.dart';
import '../../upload/upload_fakes.dart';

void main() {
  const destination = Destination(
    type: DestinationType.webdav,
    endpoint: 'https://a.example.com/dav',
  );
  final t0 = DateTime.utc(2026, 11, 13, 10);
  const cameraLag = Duration(seconds: 90);
  const second = Duration(seconds: 1);
  const noRescan = Duration(days: 1);

  late Directory root;
  late DateTime now;
  late FakeCameraClient client;
  late IngestCoordinator coordinator;
  late UploadQueue uploads;
  late SessionRepository sessions;
  late SessionSeenStore seen;
  late SessionsUploadQueue sessionsQueue;
  late SessionsPrefetch prefetch;
  late Directory prefetchDirectory;

  CameraObject shot(int handle, String extension) => cameraObject(
    handle,
    'IMG_$handle.$extension',
    captureDate: t0.add(second * 10).subtract(cameraLag).toLocal(),
  );

  Future<void> live(CameraObject object, {JpegFetched? onJpegFetched}) async {
    client.objects.add(object);
    final ingestor = LiveIngestor(
      client: client,
      format: DownloadFormat.both,
      baseline: const LiveBaseline(keys: {}),
      history: DownloadHistoryRepository(
        File(p.join(root.path, DownloadHistoryRepository.fileName)),
      ),
      queue: uploads,
      coordinator: coordinator,
      onJpegFetched: onJpegFetched,
      rescanInterval: noRescan,
    )..start();
    final ingested = ingestor.ingested.first;
    client.emitAdded(object.handle);
    await ingested;
    await ingestor.close();
    await uploads.idle;
  }

  Future<void> collect() async {
    client.cameraTimeValue = now.subtract(cameraLag);
    final clockSync = ClockSyncCubit(
      client: client,
      cameraKey: cameraKeyOf(client.deviceInfo),
      sessions: sessions,
      seen: seen,
      clock: Clock(() => now),
    );
    addTearDown(clockSync.close);
    await clockSync.start();
    expect(clockSync.state, isA<ClockResolved>());
    final collector = SessionCollector(
      client: client,
      cameraKey: cameraKeyOf(client.deviceInfo),
      clockSync: clockSync,
      sessions: sessions,
      seen: seen,
      queue: sessionsQueue,
      uploadDirectory: Directory(p.join(root.path, 'sessions_upload')),
      coordinator: coordinator,
      stagedFileOf: uploads.stagingFileFor,
      prefetch: prefetch,
      clock: Clock(() => now),
    );
    await collector.rescan();
    await collector.dispose();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('handoff');
    now = t0;
    client = FakeCameraClient([]);
    coordinator = IngestCoordinator();
    final server = FakeStorageServer();
    uploads = UploadQueue(
      repository: UploadQueueRepository.inDirectory(root),
      stagingDirectory: Directory(p.join(root.path, 'staging')),
      mediaSaver: FakeMediaSaver(),
      backendFactory: (_, {required allowMetered}) async => server.backend(),
      destination: destination,
    );
    await uploads.start();
    sessions = SessionRepository(
      File(p.join(root.path, SessionRepository.fileName)),
      clock: Clock(() => now),
    );
    seen = SessionSeenStore(
      File(p.join(root.path, SessionSeenStore.fileName)),
      clock: Clock(() => now),
    );
    sessionsQueue = SessionsUploadQueue(
      File(p.join(root.path, SessionsUploadQueue.fileName)),
      clock: Clock(() => now),
    );
    prefetchDirectory = Directory(
      p.join(root.path, SessionsPrefetch.directoryName),
    );
    prefetch = SessionsPrefetch(prefetchDirectory);
    await sessions.start();
    now = t0.add(second * 20);
  });

  tearDown(() async {
    await uploads.close();
    await root.delete(recursive: true);
  });

  test('a JPEG Live fetched reaches a Session without a second download '
      'after auto-upload removed its staging file', () async {
    final photo = shot(1, 'JPG');

    final key = SessionSeenStore.keyOf(cameraKeyOf(client.deviceInfo), photo);

    await live(photo, onJpegFetched: prefetch.keep);
    expect(await prefetch.keys(), {key});
    expect(await uploads.stagingFileFor(key, photo.filename).exists(), isFalse);
    expect(client.requestedOffsets, {
      1: [0],
    });

    await collect();

    expect(client.requestedOffsets, {
      1: [0],
    });
    final item = (await sessionsQueue.items()).single;
    expect(await File(item.filePath).readAsBytes(), contentFor(photo));
    expect(await prefetch.keys(), isEmpty);
  });

  test('without Sessions Live leaves nothing behind and the collector '
      'downloads', () async {
    await live(shot(1, 'JPG'));
    expect(await prefetchDirectory.exists(), isFalse);

    await collect();

    expect(client.requestedOffsets, {
      1: [0, 0],
    });
    expect(await sessionsQueue.items(), hasLength(1));
  });

  test('a RAW Live fetched is not handed over', () async {
    final handedOver = <String>[];

    await live(
      shot(1, 'CR3'),
      onJpegFetched: (key, _) async => handedOver.add(key),
    );

    expect(handedOver, isEmpty);
  });

  test(
    'startup sweeps prefetched photos Sessions already decided on',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dependencies = testSessionsDependencies(
        SettingsRepository(await SharedPreferences.getInstance()),
        root,
        coordinator,
      );
      final queued = shot(1, 'JPG');
      final pending = shot(2, 'JPG');
      final cameraKey = cameraKeyOf(client.deviceInfo);
      final source = File(p.join(root.path, 'source.jpg'));
      await source.writeAsBytes(contentFor(queued));
      final keys = [
        for (final photo in [queued, pending])
          SessionSeenStore.keyOf(cameraKey, photo),
      ];
      for (final key in keys) {
        await dependencies.prefetch.keep(key, source);
      }
      await dependencies.seen.markQueued(cameraKey, [keys.first]);

      await dependencies.sweepPrefetch();

      expect(await dependencies.prefetch.keys(), {keys.last});
    },
  );
}
