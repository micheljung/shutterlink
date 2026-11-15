import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/session_repository.dart';
import 'package:shutterlink/data/session_seen_store.dart';
import 'package:shutterlink/data/sessions_upload_queue.dart';
import 'package:shutterlink/feature/gallery/photo_group.dart';
import 'package:shutterlink/feature/live/ingest_coordinator.dart';
import 'package:shutterlink/feature/sessions/clock_sync_cubit.dart';
import 'package:shutterlink/feature/sessions/clock_sync_state.dart';
import 'package:shutterlink/feature/sessions/session.dart';
import 'package:shutterlink/feature/sessions/session_collector.dart';
import 'package:shutterlink/feature/sessions/sessions_config.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_cr3.dart';

class _LoggingClient extends FakeCameraClient {
  _LoggingClient() : super([]);

  final log = <String>[];
  Object? failNextDownload;
  int listings = 0;

  @override
  Future<List<CameraObject>> listPhotos() {
    listings++;
    return super.listPhotos();
  }

  @override
  Future<void> download(
    CameraObject object,
    ChunkWriter write, {
    int offset = 0,
    TransferProgress? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (failNextDownload case final error?) {
      failNextDownload = null;
      throw error;
    }
    log.add('start ${object.handle}');
    await super.download(
      object,
      write,
      offset: offset,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    log.add('end ${object.handle}');
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.delay);

  final Duration delay;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() => _active = false;
}

/// A detector tick short enough for real time.
const _tick = Duration(milliseconds: 20);

/// Waits in real time, since the stores write files.
Future<void> _until(FutureOr<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(await condition(), isTrue, reason: 'condition never became true');
}

void main() {
  final t0 = DateTime.utc(2026, 11, 13, 10);
  const cameraLag = Duration(seconds: 90);
  const second = Duration(seconds: 1);
  late Directory root;
  late DateTime now;
  late _LoggingClient client;
  late SessionRepository sessions;
  late SessionSeenStore seen;
  late SessionsUploadQueue queue;
  late String cameraKey;
  late List<_FakeTimer> timers;
  late bool busy;

  SessionRepository newSessions() => SessionRepository(
    File(p.join(root.path, SessionRepository.fileName)),
    clock: Clock(() => now),
  );

  SessionSeenStore newSeen() => SessionSeenStore(
    File(p.join(root.path, SessionSeenStore.fileName)),
    clock: Clock(() => now),
  );

  SessionsUploadQueue newQueue() => SessionsUploadQueue(
    File(p.join(root.path, SessionsUploadQueue.fileName)),
    clock: Clock(() => now),
  );

  ClockSyncCubit clockSync() {
    final cubit = ClockSyncCubit(
      client: client,
      cameraKey: cameraKey,
      sessions: sessions,
      seen: seen,
      clock: Clock(() => now),
    );
    addTearDown(cubit.close);
    return cubit;
  }

  SessionCollector collector(
    ClockSyncCubit clockSync, {
    List<String>? log,
    void Function()? onYield,
    IngestCoordinator? coordinator,
    StagedFileOf? stagedFileOf,
    Set<int> baseline = const {},
    Duration detectorInterval = const Duration(days: 1),
  }) {
    final collector = SessionCollector(
      baseline: baseline,
      detectorInterval: detectorInterval,
      coordinator: coordinator,
      stagedFileOf: stagedFileOf,
      client: client,
      cameraKey: cameraKey,
      clockSync: clockSync,
      sessions: sessions,
      seen: seen,
      queue: queue,
      uploadDirectory: Directory(p.join(root.path, 'upload')),
      isBusy: () => busy,
      clock: Clock(() => now),
      delay: (duration) async {
        log?.add('yield $duration');
        onYield?.call();
      },
      timer: (delay, _) {
        final timer = _FakeTimer(delay);
        timers.add(timer);
        return timer;
      },
    );
    addTearDown(collector.dispose);
    return collector..start();
  }

  Future<ClockSyncCubit> resolvedClock() async {
    client.cameraTimeValue = now.subtract(cameraLag);
    final sync = clockSync();
    await sync.start();
    expect(sync.state, isA<ClockResolved>());
    return sync;
  }

  CameraObject shot(
    int handle,
    DateTime phoneTime, {
    String extension = 'JPG',
    int size = 10,
  }) => cameraObject(
    handle,
    'IMG_$handle.$extension',
    size: size,
    captureDate: phoneTime.subtract(cameraLag).toLocal(),
  );

  Future<List<String>> queuedCodes() async => [
    for (final item in await queue.items()) item.sessionCode,
  ];

  String keyOf(CameraObject object) =>
      SessionSeenStore.keyOf(cameraKey, object);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('collector');
    now = t0;
    client = _LoggingClient();
    cameraKey = cameraKeyOf(client.deviceInfo);
    sessions = newSessions();
    seen = newSeen();
    queue = newQueue();
    timers = [];
    busy = false;
  });

  tearDown(() => root.delete(recursive: true));

  test('enqueues nothing before the clock is resolved', () async {
    await sessions.setClockOffset(
      ClockOffset(
        offset: cameraLag,
        measuredAt: t0.subtract(offsetFreshness * 2),
        source: ClockOffsetSource.syncShot,
      ),
    );
    final session = await sessions.start();
    now = t0.add(second * 20);
    client.objects.add(shot(1, now));
    now = now.add(second);
    final sync = clockSync();
    await sync.start();
    expect(sync.state, isA<ClockPrompt>());
    final collecting = collector(sync);

    await collecting.rescan();
    expect(await queue.items(), isEmpty);
    expect(client.log, isEmpty);
    expect(await seen.baseline(cameraKey), isNull);

    await sync.useLastOffset();
    await collecting.rescan();

    expect(await queuedCodes(), [session.code]);
    expect(await seen.stateOf(keyOf(client.objects.single)), SeenState.queued);
  });

  test('an offset change attributes a photo outside every Session', () async {
    final session = await sessions.start();
    now = t0.add(second * 30);
    client.objects.add(shot(1, t0.add(second * 20)));
    final sync = clockSync();
    await sync.start();
    await sync.useLastOffset();
    final collecting = collector(sync);

    await collecting.rescan();
    expect(await queue.items(), isEmpty);

    await sessions.setClockOffset(
      ClockOffset(
        offset: cameraLag,
        measuredAt: now,
        source: ClockOffsetSource.syncShot,
      ),
    );
    await sync.useLastOffset();
    await collecting.rescan();

    expect(await queuedCodes(), [session.code]);
  });

  test('photos are attributed by corrected capture time', () async {
    final a = await sessions.start();
    client.objects.add(shot(1, t0.add(second * 10)));
    now = t0.add(second * 60);
    final b = await sessions.start();
    client.objects.add(shot(2, t0.add(second * 70)));
    now = t0.add(second * 100);
    await sessions.stop();
    client.objects.add(shot(3, t0.add(second * 105)));
    now = t0.add(second * 110);
    final collecting = collector(await resolvedClock());

    await collecting.rescan();

    final items = await queue.items();
    expect(items.map((item) => item.sessionCode), [a.code, b.code]);
    expect(
      await File(items.first.filePath).readAsBytes(),
      contentFor(client.objects.first),
    );
    expect(await seen.stateOf(keyOf(client.objects.last)), isNull);
  });

  test('the sync photo and photos without a date are skipped', () async {
    await sessions.start();
    final syncPhoto = shot(1, t0.add(second * 10));
    client.objects.addAll([syncPhoto, cameraObject(2, 'IMG_2.JPG')]);
    await seen.markExcluded(cameraKey, [keyOf(syncPhoto)]);
    now = t0.add(second * 20);
    final collecting = collector(await resolvedClock());

    await collecting.rescan();

    expect(await queue.items(), isEmpty);
    expect(client.log, isEmpty);
    expect(await seen.stateOf(keyOf(syncPhoto)), SeenState.excluded);
  });

  test('a restart does not download again', () async {
    await sessions.start();
    client.objects.add(shot(1, t0.add(second * 10)));
    now = t0.add(second * 20);
    final first = collector(await resolvedClock());
    await first.rescan();
    await first.dispose();
    expect(client.log, ['start 1', 'end 1']);

    sessions = newSessions();
    seen = newSeen();
    queue = newQueue();
    final restarted = collector(await resolvedClock());
    await restarted.rescan();

    expect(client.log, ['start 1', 'end 1']);
    expect(await queue.items(), hasLength(1));
  });

  test('downloads one file at a time with a pause between files', () async {
    await sessions.start();
    client.objects.addAll([
      shot(1, t0.add(second * 10)),
      shot(2, t0.add(second * 11)),
    ]);
    now = t0.add(second * 20);
    final log = client.log;
    final collecting = collector(await resolvedClock(), log: log);

    await collecting.rescan();

    expect(log, [
      'start 1',
      'end 1',
      'yield $collectorYield',
      'start 2',
      'end 2',
    ]);
  });

  test('copies a JPEG auto-upload staged instead of downloading it', () async {
    await sessions.start();
    final photo = shot(1, t0.add(second * 10));
    client.objects.add(photo);
    now = t0.add(second * 20);
    final staged = File(p.join(root.path, 'staged', photo.filename));
    await staged.parent.create();
    final stagedBytes = List.filled(photo.size, 7);
    await staged.writeAsBytes(stagedBytes);
    final requested = <String>[];
    final collecting = collector(
      await resolvedClock(),
      stagedFileOf: (key, filename) {
        requested.add('$key $filename');
        return staged;
      },
    );

    await collecting.rescan();

    expect(requested, ['${keyOf(photo)} ${photo.filename}']);
    expect(client.log, isEmpty);
    final item = (await queue.items()).single;
    expect(await File(item.filePath).readAsBytes(), stagedBytes);
  });

  test('downloads when the staged copy is incomplete', () async {
    await sessions.start();
    final photo = shot(1, t0.add(second * 10));
    client.objects.add(photo);
    now = t0.add(second * 20);
    final staged = File(p.join(root.path, 'staged', photo.filename));
    await staged.parent.create();
    await staged.writeAsBytes(List.filled(photo.size - 1, 7));
    final collecting = collector(
      await resolvedClock(),
      stagedFileOf: (_, _) => staged,
    );

    await collecting.rescan();

    expect(client.log, ['start 1', 'end 1']);
    final item = (await queue.items()).single;
    expect(await File(item.filePath).readAsBytes(), contentFor(photo));
  });

  test('downloads when auto-upload has no staged copy', () async {
    await sessions.start();
    client.objects.add(shot(1, t0.add(second * 10)));
    now = t0.add(second * 20);
    final collecting = collector(
      await resolvedClock(),
      stagedFileOf: (_, filename) => File(p.join(root.path, 'none', filename)),
    );

    await collecting.rescan();

    expect(client.log, ['start 1', 'end 1']);
    expect(await queue.items(), hasLength(1));
  });

  test('waits for another ingest of the same file', () async {
    await sessions.start();
    final photo = shot(1, t0.add(second * 10));
    client.objects.add(photo);
    now = t0.add(second * 20);
    final coordinator = IngestCoordinator();
    final release = Completer<void>();
    final ingest = coordinator.run([keyOf(photo)], () => release.future);
    final collecting = collector(
      await resolvedClock(),
      coordinator: coordinator,
    );

    final rescan = collecting.rescan();
    await pumpEventQueue();
    expect(client.log, isEmpty);

    release.complete();
    await ingest;
    await rescan;
    expect(client.log, ['start 1', 'end 1']);
  });

  test('a RAW-only photo uploads its embedded preview', () async {
    final session = await sessions.start();
    final raw = shot(1, t0.add(second * 10), extension: 'CR3');
    final cr3 = fakeCr3();
    client
      ..objects.add(
        CameraObject(
          handle: raw.handle,
          storageId: raw.storageId,
          filename: raw.filename,
          size: cr3.length,
          captureDate: raw.captureDate,
          kind: raw.kind,
        ),
      )
      ..contentOverrides[raw.handle] = cr3;
    now = t0.add(second * 20);
    final collecting = collector(await resolvedClock());

    await collecting.rescan();

    final item = (await queue.items()).single;
    expect(item.sessionCode, session.code);
    expect(await File(item.filePath).readAsBytes(), fakePreviewJpeg);
  });

  test('never enqueues photos older than the queue max age', () async {
    await sessions.start();
    client.objects.add(shot(1, t0.add(second * 10)));
    now = t0.add(queueMaxAge + second * 20);
    final collecting = collector(await resolvedClock());

    await collecting.rescan();

    expect(await queue.items(), isEmpty);
    expect(client.log, isEmpty);
  });

  test('never enqueues photos of an expired Session', () async {
    final session = await sessions.start();
    await sessions.markExpired(session.code);
    client.objects.add(shot(1, t0.add(second * 10)));
    now = t0.add(second * 20);
    final collecting = collector(await resolvedClock());

    await collecting.rescan();

    expect(await queue.items(), isEmpty);
  });

  test('persists the baseline after a rescan and at disconnect', () async {
    final photo = shot(1, t0.add(second * 10));
    client.objects.add(photo);
    now = t0.add(second * 20);
    final collecting = collector(await resolvedClock());

    await collecting.rescan();
    expect(await seen.baseline(cameraKey), {keyOf(photo)});

    final later = shot(2, t0.add(second * 15));
    await collecting.onGroups(groupPhotos([photo, later]));
    client.objects.add(later);
    await collecting.dispose();
    expect(await seen.baseline(cameraKey), {keyOf(photo), keyOf(later)});
  });

  test('rescans after the previous one and skips while busy', () async {
    await sessions.start();
    client.objects.add(shot(1, t0.add(second * 10)));
    now = t0.add(second * 20);
    final collecting = collector(await resolvedClock());
    expect(timers.single.delay, collectorRescanInterval);

    busy = true;
    await collecting.rescan();
    expect(client.log, isEmpty);
    expect(timers, hasLength(2));
    expect(timers.first.isActive, isFalse);

    busy = false;
    await collecting.rescan();
    expect(client.log, ['start 1', 'end 1']);
    expect(timers.last.isActive, isTrue);
  });

  test('stops transferring when a download starts mid-pass', () async {
    await sessions.start();
    final photos = [shot(1, t0.add(second * 10)), shot(2, t0.add(second * 11))];
    client.objects.addAll(photos);
    now = t0.add(second * 20);
    final collecting = collector(
      await resolvedClock(),
      onYield: () => busy = true,
    );

    await collecting.rescan();
    expect(client.log, ['start 1', 'end 1']);
    expect(await queue.items(), hasLength(1));

    await collecting.onGroups(groupPhotos(photos));
    expect(client.log, ['start 1', 'end 1']);

    busy = false;
    await collecting.rescan();
    expect(client.log, ['start 1', 'end 1', 'start 2', 'end 2']);
    expect(await queue.items(), hasLength(photos.length));
  });

  test('a camera object-added event brings the rescan forward', () async {
    await sessions.start();
    now = t0.add(second * 20);
    final collecting = collector(await resolvedClock());
    expect(timers.single.delay, collectorRescanInterval);

    client.emitAdded(1);
    await pumpEventQueue();
    expect(timers.last.delay, collectorAddedDelay);
    expect(timers.first.isActive, isFalse);

    client.objects.add(shot(1, t0.add(second * 10)));
    final rescan = collecting.rescan();
    client.emitAdded(2);
    await rescan;
    expect(client.log, ['start 1', 'end 1']);
    expect(timers.last.delay, collectorAddedDelay);
  });

  test('a camera storage change queues a new shot at once and brings the '
      'rescan forward', () async {
    final session = await sessions.start();
    now = t0.add(second * 20);
    collector(await resolvedClock());
    expect(timers.single.delay, collectorRescanInterval);

    client.objects.add(shot(1, t0.add(second * 10)));
    client.emitStorageChanged();
    await _until(() async => (await queue.items()).isNotEmpty);

    expect(await queuedCodes(), [session.code]);
    expect(client.listings, 0);
    expect(timers.last.delay, collectorAddedDelay);
    expect(timers.first.isActive, isFalse);
  });

  test('a shot found by the newest-folder diff, with no events, is queued '
      'within a tick and without listing the card (AC17)', () async {
    final session = await sessions.start();
    final old = shot(1, t0.add(second * 5));
    client.objects.add(old);
    now = t0.add(second * 20);
    collector(
      await resolvedClock(),
      baseline: {old.handle},
      detectorInterval: _tick,
    );

    final added = shot(2, t0.add(second * 10));
    client.objects.add(added);
    await _until(
      () async => await seen.stateOf(keyOf(added)) == SeenState.queued,
    );

    expect(await queuedCodes(), [session.code]);
    expect(client.log, ['start 2', 'end 2']);
    expect(client.listings, 0);
    expect(await seen.stateOf(keyOf(added)), SeenState.queued);
  });

  test('on a cold cache a new shot is queued before the card is listed, and '
      'the full pass neither queues it again nor drops older folders '
      '(AC17)', () async {
    final session = await sessions.start();
    final card = [
      for (var handle = 1; handle <= 1000; handle++)
        shot(handle, t0.subtract(const Duration(hours: 1))),
    ];
    final syncPhoto = shot(1001, t0.subtract(const Duration(hours: 2)));
    client
      ..objects.addAll([syncPhoto, ...card])
      ..folderOf[syncPhoto.handle] = 100
      ..folderOf.addAll({for (final photo in card) photo.handle: 101});
    await seen.markExcluded(cameraKey, [keyOf(syncPhoto)]);
    now = t0.add(second * 20);
    final collecting = collector(
      await resolvedClock(),
      baseline: (await client.newestFolderHandles()).toSet(),
    );
    client.listPhotosGate = Completer<void>();
    final walk = collecting.rescan();
    await pumpEventQueue();
    expect(client.listings, 1);

    final added = shot(2000, t0.add(second * 10));
    client
      ..objects.add(added)
      ..emitAdded(added.handle);
    await _until(() async => (await queue.items()).isNotEmpty);

    expect(await queuedCodes(), [session.code]);
    expect(client.listPhotosGate!.isCompleted, isFalse);
    expect(await seen.baseline(cameraKey), isNull);
    expect(await seen.stateOf(keyOf(syncPhoto)), SeenState.excluded);

    client.listPhotosGate!.complete();
    await walk;

    expect(await queuedCodes(), [session.code]);
    expect(client.log, ['start 2000', 'end 2000']);
    expect(await seen.stateOf(keyOf(syncPhoto)), SeenState.excluded);
    expect(await seen.baseline(cameraKey), hasLength(card.length + 2));
  });

  test('a shot offered twice during a cold walk is queued once', () async {
    await sessions.start();
    now = t0.add(second * 20);
    final collecting = collector(await resolvedClock());
    client.listPhotosGate = Completer<void>();
    final walk = collecting.rescan();

    final added = shot(1, t0.add(second * 10));
    client
      ..objects.add(added)
      ..emitAdded(added.handle);
    await _until(() async => (await queue.items()).isNotEmpty);
    client.emitAdded(added.handle);
    await _until(() => client.log.isNotEmpty);
    await Future<void>.delayed(_tick);

    expect(await queue.items(), hasLength(1));
    expect(client.log, ['start 1', 'end 1']);
    client.listPhotosGate!.complete();
    await walk;
    expect(await queue.items(), hasLength(1));
  });

  test('the fast and the full pass racing for one shot send it once', () async {
    await sessions.start();
    now = t0.add(second * 20);
    final collecting = collector(await resolvedClock());
    final added = shot(1, t0.add(second * 10));
    client
      ..objects.add(added)
      ..chunkGate = Completer<void>()
      ..emitAdded(added.handle);
    await _until(() => client.log.isNotEmpty);

    final walk = collecting.rescan();
    await Future<void>.delayed(_tick);
    client.chunkGate!.complete();
    await walk;
    await _until(() async => (await queue.items()).isNotEmpty);
    await Future<void>.delayed(_tick);

    expect(await queue.items(), hasLength(1));
    expect(client.log, ['start 1', 'end 1']);
    expect(client.requestedOffsets[added.handle], [0]);
  });

  test('a shot that arrives while a fast pass runs is queued too', () async {
    await sessions.start();
    now = t0.add(second * 20);
    collector(await resolvedClock());
    final first = shot(1, t0.add(second * 10));
    final second_ = shot(2, t0.add(second * 11));
    client
      ..objects.addAll([first, second_])
      ..chunkGate = Completer<void>()
      ..emitAdded(first.handle);
    await _until(() => client.log.isNotEmpty);

    client.emitAdded(second_.handle);
    await pumpEventQueue();
    client.chunkGate!.complete();

    await _until(() async => (await queue.items()).length == 2);
    expect(client.log, ['start 1', 'end 1', 'start 2', 'end 2']);
  });

  test('dispose during a fast pass queues nothing', () async {
    await sessions.start();
    now = t0.add(second * 20);
    final collecting = collector(await resolvedClock());
    final added = cameraObject(
      1,
      'IMG_1.JPG',
      size: fakeChunkSize,
      captureDate: t0.add(second * 10).subtract(cameraLag).toLocal(),
    );
    client
      ..objects.add(added)
      ..chunkGate = Completer<void>()
      ..emitAdded(added.handle);
    await _until(() => client.requestedOffsets.isNotEmpty);

    final disposing = collecting.dispose();
    client.chunkGate!.complete();
    await disposing;

    expect(await queue.items(), isEmpty);
    expect(await seen.stateOf(keyOf(added)), isNull);
  });

  test('a RAW too young to send waits for the next diff, not for the next '
      'rescan', () async {
    final session = await sessions.start();
    now = t0.add(second * 20);
    final cr3 = fakeCr3();
    final young = shot(1, now, extension: 'CR3');
    final raw = CameraObject(
      handle: young.handle,
      storageId: young.storageId,
      filename: young.filename,
      size: cr3.length,
      captureDate: young.captureDate,
      kind: young.kind,
    );
    client
      ..objects.add(raw)
      ..contentOverrides[raw.handle] = cr3;
    now = now.add(second);
    final collecting = collector(
      await resolvedClock(),
      detectorInterval: _tick,
    );
    await collecting.rescan();
    await Future<void>.delayed(_tick * 3);
    expect(await queue.items(), isEmpty);
    final listings = client.listings;

    now = now.add(collectorSettleDelay);
    await _until(() async => (await queue.items()).isNotEmpty);

    expect(await queuedCodes(), [session.code]);
    expect(client.listings, listings);
  });

  test('a RAW followed by its JPEG sends the JPEG', () async {
    await sessions.start();
    now = t0.add(second * 20);
    collector(await resolvedClock());
    final raw = shot(1, now.subtract(second), extension: 'CR3');
    client
      ..objects.add(raw)
      ..emitAdded(raw.handle);
    await Future<void>.delayed(_tick);
    expect(await queue.items(), isEmpty);

    final jpeg = cameraObject(2, 'IMG_1.JPG', captureDate: raw.captureDate);
    client
      ..objects.add(jpeg)
      ..emitAdded(jpeg.handle);
    await _until(() async => (await queue.items()).isNotEmpty);

    final item = (await queue.items()).single;
    expect(await File(item.filePath).readAsBytes(), contentFor(jpeg));
    expect(client.log, ['start 2', 'end 2']);
  });

  test('a RAW listed after its JPEG was sent is not sent again', () async {
    await sessions.start();
    now = t0.add(second * 20);
    final collecting = collector(await resolvedClock());
    final jpeg = shot(1, t0.add(second * 10));
    client.objects.add(jpeg);
    await collecting.rescan();
    expect(await queue.items(), hasLength(1));

    final cr3 = fakeCr3();
    final raw = CameraObject(
      handle: 2,
      storageId: jpeg.storageId,
      filename: 'IMG_1.CR3',
      size: cr3.length,
      captureDate: jpeg.captureDate,
      kind: CameraObjectKind.raw,
    );
    client
      ..objects.add(raw)
      ..contentOverrides[raw.handle] = cr3
      ..emitAdded(raw.handle);
    await Future<void>.delayed(_tick * 3);

    expect(await queue.items(), hasLength(1));
    expect(client.requestedOffsets.keys, [jpeg.handle]);
  });

  test('a shot outside every Session is settled by the pass and not offered '
      'again', () async {
    now = t0.add(second * 20);
    final collecting = collector(
      await resolvedClock(),
      detectorInterval: _tick,
    );
    client.objects.add(shot(1, t0.add(second * 10)));
    await _until(() => timers.length > 1);
    await collecting.rescan();
    final scheduled = timers.length;
    final listings = client.listings;

    await Future<void>.delayed(_tick * 10);

    expect(timers, hasLength(scheduled));
    expect(client.listings, listings);
    expect(await queue.items(), isEmpty);
  });

  test('an error in a pass is survived and the next pass retries', () async {
    await sessions.start();
    client.objects.add(shot(1, t0.add(second * 10)));
    now = t0.add(second * 20);
    final collecting = collector(await resolvedClock());
    client.failNextDownload = StateError('broken pipe');

    await collecting.rescan();
    expect(await queue.items(), isEmpty);
    expect(timers.last.isActive, isTrue);

    await collecting.rescan();
    expect(client.log, ['start 1', 'end 1']);
    expect(await queue.items(), hasLength(1));
  });
}
