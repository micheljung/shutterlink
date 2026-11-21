import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/download/download_cubit.dart';
import 'package:shutterlink/feature/download/download_state.dart';
import 'package:shutterlink/feature/gallery/photo_group.dart';
import 'package:shutterlink/feature/live/ingest_coordinator.dart';
import 'package:shutterlink/feature/live/live_ingestor.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/upload_queue.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_periodic_timer.dart';
import '../../upload/upload_fakes.dart';

/// Answers objectInfo from a script before falling back to the real objects.
class _ScriptedClient extends FakeCameraClient {
  _ScriptedClient(super.objects);

  final script = <Object?>[];
  int infoCalls = 0;
  int failingDownloads = 0;
  int rescans = 0;

  @override
  Future<List<int>> newestFolderHandles() {
    rescans++;
    return super.newestFolderHandles();
  }

  @override
  Future<void> download(
    CameraObject object,
    ChunkWriter write, {
    int offset = 0,
    int? length,
    TransferProgress? onProgress,
    CancelToken? cancelToken,
    int? chunkSize,
  }) {
    if (failingDownloads > 0) {
      failingDownloads--;
      throw const FileSystemException('busy');
    }
    return super.download(
      object,
      write,
      offset: offset,
      length: length,
      onProgress: onProgress,
      cancelToken: cancelToken,
      chunkSize: chunkSize,
    );
  }

  @override
  Future<CameraObject?> objectInfo(int handle) async {
    infoCalls++;
    if (script.isEmpty) return super.objectInfo(handle);
    final next = script.removeAt(0);
    if (next is Exception) throw next;
    return next as CameraObject?;
  }
}

const noRescan = Duration(days: 1);

void main() {
  const destination = Destination(
    type: DestinationType.webdav,
    endpoint: 'https://a.example.com/dav',
  );
  final date = DateTime(2026, 11, 13, 10);
  final jpeg = cameraObject(1, 'IMG_0001.JPG', captureDate: date);
  final raw = cameraObject(2, 'IMG_0001.CR3', captureDate: date);
  final old = cameraObject(3, 'IMG_0000.JPG', captureDate: date);

  late Directory root;
  late FakeStorageServer server;
  late FakeMediaSaver media;
  late DownloadHistoryRepository history;
  late IngestCoordinator coordinator;
  late UploadQueue queue;
  late _ScriptedClient client;
  late List<LiveIngestor> ingestors;
  late FakePeriodicTimers timers;

  final cameraKey = cameraKeyOf(FakeCameraClient(const []).deviceInfo);
  String keyOf(CameraObject object) =>
      DownloadHistoryRepository.entryKey(cameraKey, object);

  LiveIngestor ingestor({
    DownloadFormat format = DownloadFormat.both,
    Set<String> baseline = const {},
  }) {
    final created = LiveIngestor(
      client: client,
      format: format,
      baseline: LiveBaseline(keys: baseline),
      history: history,
      queue: queue,
      coordinator: coordinator,
      infoRetryDelay: Duration.zero,
      rescanInterval: noRescan,
      periodicTimer: timers.create,
    );
    ingestors.add(created);
    return created..start();
  }

  /// Waits on the wall clock, not on a count of event-loop turns, so a loaded
  /// machine only makes it slower. With [tick] it fires the rescan timer on
  /// every poll, which the detector coalesces while it is busy.
  Future<void> eventually(
    bool Function() condition, {
    bool tick = false,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('condition never became true');
      if (tick) timers.tick();
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  Future<void> settle() async {
    await pumpEventQueue();
    await queue.idle;
  }

  /// Fires [count] rescan ticks, letting each diff and its ingest finish.
  Future<void> tickAndSettle(int count) async {
    for (var i = 0; i < count; i++) {
      timers.tick();
      await settle();
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('live');
    server = FakeStorageServer();
    media = FakeMediaSaver();
    history = DownloadHistoryRepository(
      File(p.join(root.path, DownloadHistoryRepository.fileName)),
    );
    coordinator = IngestCoordinator();
    queue = UploadQueue(
      repository: UploadQueueRepository.inDirectory(root),
      stagingDirectory: Directory(p.join(root.path, 'staging')),
      mediaSaver: media,
      backendFactory: (_, {required allowMetered}) async => server.backend(),
      destination: destination,
    );
    await queue.start();
    client = _ScriptedClient([old, jpeg, raw]);
    ingestors = [];
    timers = FakePeriodicTimers();
  });

  tearDown(() async {
    for (final ingestor in ingestors) {
      await ingestor.close();
    }
    await settle();
    await queue.close();
    await root.delete(recursive: true);
  });

  test('a new shot is downloaded, saved, recorded and uploaded', () async {
    final live = ingestor();
    final ingested = live.ingested.first;

    client.emitAdded(1);

    expect(await ingested, jpeg);
    await settle();
    expect(server.files.keys, ['2026-11-13/IMG_0001.JPG']);
    expect(server.files.values.single, contentFor(jpeg));
    expect(media.published, hasLength(1));
    expect(await history.contains(cameraKey, jpeg), isTrue);
  });

  test('skips the baseline, filtered kinds, unknown handles', () async {
    ingestor(format: DownloadFormat.raw, baseline: {keyOf(old), keyOf(raw)});

    client
      ..emitAdded(3)
      ..emitAdded(1)
      ..emitAdded(2)
      ..emitAdded(99);
    await settle();

    expect(server.files, isEmpty);
    expect(client.requestedOffsets, isEmpty);
    expect(client.infoCalls, 4);
  });

  test('a photo only downloaded to the phone is still uploaded', () async {
    await history.record(cameraKey, [jpeg]);
    final live = ingestor(baseline: {keyOf(old), keyOf(raw)});
    final ingested = live.ingested.first;

    client.emitAdded(jpeg.handle);

    expect(await ingested, jpeg);
    await settle();
    expect(server.files.keys, ['2026-11-13/IMG_0001.JPG']);
  });

  test('a photo uploaded to the destination before is skipped', () async {
    final first = ingestor(baseline: {keyOf(old), keyOf(raw)});
    final ingested = first.ingested.first;
    client.emitAdded(jpeg.handle);
    await ingested;
    await settle();
    await first.close();
    final fetched = client.requestedOffsets.length;

    ingestor();
    client.emitAdded(jpeg.handle);
    await settle();

    expect(client.requestedOffsets, hasLength(fetched));
    expect(server.files, hasLength(1));
  });

  test(
    'the backlog counts wanted photos not uploaded, downloaded or not',
    () async {
      final live = ingestor(baseline: {keyOf(old), keyOf(raw)});
      final ingested = live.ingested.first;
      client.emitAdded(jpeg.handle);
      await ingested;
      await settle();
      await history.record(cameraKey, [old]);
      final photos = [
        old,
        jpeg,
        raw,
        cameraObject(4, 'IMG_0004.JPG', captureDate: date),
      ];

      Future<int> backlog(DownloadFormat format) => LiveIngestor.backlogOf(
        photos,
        cameraKey: cameraKey,
        format: format,
        queue: queue,
      );

      expect(await backlog(DownloadFormat.jpeg), 2);
      expect(await backlog(DownloadFormat.raw), 1);
      expect(await backlog(DownloadFormat.both), 3);
    },
  );

  test('waits while the camera is still writing the file', () async {
    client.script.addAll([
      cameraObject(1, 'IMG_0001.JPG', size: 0, captureDate: date),
      const PtpResponseException(0x1008, 0x2019),
    ]);
    ingestor();

    client.emitAdded(1);
    await eventually(() => server.files.isNotEmpty);

    expect(client.infoCalls, 3);
  });

  test('gives up on unreadable objects until the catch-up', () async {
    client.script.addAll(
      List.filled(LiveIngestor.infoRetries + 1, Exception('busy')),
    );
    final live = ingestor(baseline: {keyOf(old)});

    client.emitAdded(1);
    await settle();
    expect(server.files, isEmpty);
    expect(client.infoCalls, LiveIngestor.infoRetries + 1);

    await live.catchUp();
    await eventually(() => server.files.length == 2);
    expect(server.files.keys.toSet(), {
      '2026-11-13/IMG_0001.JPG',
      '2026-11-13/IMG_0001.CR3',
    });
  });

  test('a disconnect while asking for the object stops retrying', () async {
    client.script.add(const CameraDisconnectedException());
    final live = ingestor(baseline: {keyOf(old), keyOf(raw)});

    client.emitAdded(1);
    await settle();
    expect(client.infoCalls, 1);

    await live.catchUp();
    await eventually(() => server.files.isNotEmpty);
    expect(server.files.keys, ['2026-11-13/IMG_0001.JPG']);
  });

  test('the rescan finds shots the camera never announced', () async {
    final shot = cameraObject(4, 'IMG_0002.JPG', captureDate: date);
    ingestor(baseline: {keyOf(old), keyOf(jpeg), keyOf(raw)});

    client.objects.add(shot);
    await eventually(() => server.files.isNotEmpty, tick: true);

    expect(server.files.keys, ['2026-11-13/IMG_0002.JPG']);
    expect(client.requestedOffsets.keys, [shot.handle]);
  });

  test('the rescan asks for each handle once', () async {
    ingestor(baseline: {keyOf(old), keyOf(jpeg), keyOf(raw)});
    await eventually(
      () => client.infoCalls == client.objects.length,
      tick: true,
    );
    await tickAndSettle(3);

    client.emitAdded(jpeg.handle);
    await settle();

    expect(client.infoCalls, client.objects.length);
    expect(server.files, isEmpty);
  });

  test('the rescan retries a handle an event gave up on', () async {
    client.script.addAll(
      List.filled(LiveIngestor.infoRetries + 1, Exception('busy')),
    );
    ingestor(baseline: {keyOf(old), keyOf(raw)});

    client.emitAdded(jpeg.handle);
    await eventually(() => server.files.isNotEmpty, tick: true);

    expect(server.files.keys, ['2026-11-13/IMG_0001.JPG']);
  });

  test('the rescan ingests a shot after a failed attempt, no events', () async {
    client.script.addAll([
      for (var i = 0; i <= LiveIngestor.infoRetries; i++)
        cameraObject(1, 'IMG_0001.JPG', size: 0, captureDate: date),
    ]);
    ingestor(baseline: {keyOf(old), keyOf(raw)});

    await eventually(() => server.files.isNotEmpty, tick: true);

    expect(server.files.keys, ['2026-11-13/IMG_0001.JPG']);
    expect(client.infoCalls, greaterThan(LiveIngestor.infoRetries + 1));
  });

  test('a slow ingest does not pile up rescans behind it', () async {
    client.chunkGate = Completer<void>();
    ingestor(baseline: {keyOf(old), keyOf(raw)});
    await eventually(() => client.requestedOffsets.isNotEmpty, tick: true);
    final rescans = client.rescans;

    await tickAndSettle(5);
    expect(client.rescans, rescans);

    client.chunkGate!.complete();
    client.chunkGate = null;
    await eventually(() => server.files.isNotEmpty);
  });

  test('the rescan stops once the camera disconnects', () async {
    ingestor();
    client.simulateDisconnect();
    await pumpEventQueue();
    await tickAndSettle(3);

    expect(client.infoCalls, 0);
  });

  test('an interrupted download resumes in the catch-up', () async {
    LiveIngestor direct(CameraClient camera) {
      final created = LiveIngestor(
        client: camera,
        format: DownloadFormat.both,
        baseline: LiveBaseline(keys: const {}),
        history: history,
        queue: queue,
        coordinator: coordinator,
        rescanInterval: noRescan,
      );
      ingestors.add(created);
      return created;
    }

    final dropping = FakeCameraClient([jpeg], disconnectAfterChunks: 1);
    await direct(dropping).catchUp();
    expect(server.files, isEmpty);
    expect(await history.contains(cameraKey, jpeg), isFalse);

    final reconnected = FakeCameraClient([jpeg]);
    await direct(reconnected).catchUp();
    await settle();

    expect(reconnected.requestedOffsets[1], [fakeChunkSize]);
    expect(server.files.values.single, contentFor(jpeg));
  });

  test('baseline holds the entry keys and handles on the card', () async {
    final baseline = LiveBaseline.of(cameraKey, await client.listPhotos());

    expect(baseline.keys, {keyOf(old), keyOf(jpeg), keyOf(raw)});
    expect(baseline.handles, {old.handle, jpeg.handle, raw.handle});
  });

  test('a failed download stays retryable', () async {
    client.failingDownloads = 1;
    final live = ingestor(baseline: {keyOf(old), keyOf(raw)});
    final ingested = live.ingested.first;

    client.emitAdded(jpeg.handle);
    await settle();
    expect(server.files, isEmpty);
    client.emitAdded(jpeg.handle);

    expect(await ingested, jpeg);
  });

  test('the rescan never asks about the baseline handles', () async {
    final baseline = LiveBaseline.of(cameraKey, await client.listPhotos());
    final shot = cameraObject(4, 'IMG_0002.JPG', captureDate: date);
    LiveIngestor rescanning() {
      final created = LiveIngestor(
        client: client,
        format: DownloadFormat.both,
        baseline: baseline,
        history: history,
        queue: queue,
        coordinator: coordinator,
        rescanInterval: noRescan,
        periodicTimer: timers.create,
      );
      ingestors.add(created);
      return created..start();
    }

    final first = rescanning();
    client.objects.add(shot);
    await eventually(() => server.files.isNotEmpty, tick: true);
    await first.close();
    await rescanning().catchUp();
    await tickAndSettle(3);

    expect(client.infoCalls, 1);
  });

  test('a closed ingestor never starts', () async {
    final live = LiveIngestor(
      client: client,
      format: DownloadFormat.both,
      baseline: LiveBaseline(keys: const {}),
      history: history,
      queue: queue,
      coordinator: coordinator,
      rescanInterval: noRescan,
      periodicTimer: timers.create,
    );
    ingestors.add(live);
    await live.close();

    live.start();
    await tickAndSettle(3);

    expect(timers.created, isEmpty);
    expect(client.rescans, 0);
  });

  test('the catch-up resolves the handles it lists', () async {
    ingestor(baseline: {keyOf(old), keyOf(jpeg), keyOf(raw)}).catchUp();
    await eventually(() => client.rescans > 1, tick: true);

    expect(client.infoCalls, 0);
  });

  test('close abandons the rest of a catch-up', () async {
    final live = ingestor();
    client.chunkGate = Completer<void>();
    final catchUp = live.catchUp();
    await eventually(() => client.requestedOffsets.isNotEmpty);

    final closed = live.close();
    client.chunkGate!.complete();
    client.chunkGate = null;
    await closed;
    await catchUp;

    expect(client.requestedOffsets.keys, [old.handle]);
  });

  test('manual download and Live of the same shot run once', () async {
    client.chunkGate = Completer<void>();
    final saver = RecordingPhotoSaver();
    final cubit = DownloadCubit(
      saver: saver,
      workDirectory: Directory(p.join(root.path, 'work')),
      history: history,
      coordinator: coordinator,
      uploadQueue: queue,
    );
    ingestor(format: DownloadFormat.jpeg);
    client.emitAdded(1);
    await eventually(() => coordinator.isInFlight(keyOf(jpeg)));

    final manual = cubit.start(
      client,
      groupPhotos([jpeg]),
      DownloadFormat.jpeg,
    );
    await pumpEventQueue();
    client.chunkGate!.complete();
    client.chunkGate = null;
    await manual;
    await settle();

    expect(cubit.state.status, DownloadStatus.completed);
    expect(cubit.state.saved, hasLength(1));
    expect(client.requestedOffsets[1], [0]);
    expect(saver.saved, isEmpty);
    expect(media.published, hasLength(1));
    expect(server.files, hasLength(1));
    expect(server.tempWrites, hasLength(1));
    await cubit.close();
  });
}
