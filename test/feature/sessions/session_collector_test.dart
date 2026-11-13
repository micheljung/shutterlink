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
  }) {
    final collector = SessionCollector(
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
