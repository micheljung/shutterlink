import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/session_repository.dart';
import 'package:shutterlink/data/session_seen_store.dart';
import 'package:shutterlink/feature/sessions/clock_sync_cubit.dart';
import 'package:shutterlink/feature/sessions/clock_sync_state.dart';
import 'package:shutterlink/feature/sessions/session.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

import '../../fakes/fake_camera_client.dart';

class _TimedClient extends FakeCameraClient {
  _TimedClient(this.advance) : super([]);

  final void Function(Duration duration) advance;
  Duration listDuration = Duration.zero;
  void Function(int listing)? onList;
  int listings = 0;

  @override
  Future<List<CameraObject>> listPhotos() async {
    final snapshot = List.of(objects);
    advance(listDuration);
    onList?.call(listings++);
    return [...snapshot, ...objects.skip(snapshot.length)];
  }
}

void main() {
  final t0 = DateTime.utc(2026, 11, 13, 10);
  const cameraLag = Duration(seconds: 90);
  late Directory root;
  late DateTime now;
  late _TimedClient client;
  late SessionRepository sessions;
  late SessionSeenStore seen;
  late String cameraKey;

  void advance(Duration duration) => now = now.add(duration);

  ClockSyncCubit cubit() {
    final cubit = ClockSyncCubit(
      client: client,
      cameraKey: cameraKey,
      sessions: sessions,
      seen: seen,
      clock: Clock(() => now),
      delay: (duration) async => advance(duration),
    );
    addTearDown(cubit.close);
    return cubit;
  }

  CameraObject shot(int handle, DateTime phoneTime) => cameraObject(
    handle,
    'IMG_$handle.JPG',
    captureDate: phoneTime.subtract(cameraLag).toLocal(),
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('clock_sync');
    now = t0;
    client = _TimedClient(advance);
    cameraKey = cameraKeyOf(client.deviceInfo);
    sessions = SessionRepository(
      File(p.join(root.path, SessionRepository.fileName)),
      clock: Clock(() => now),
    );
    seen = SessionSeenStore(
      File(p.join(root.path, SessionSeenStore.fileName)),
      clock: Clock(() => now),
    );
  });

  tearDown(() => root.delete(recursive: true));

  Future<void> storeOffset(Duration offset, {DateTime? measuredAt}) =>
      sessions.setClockOffset(
        ClockOffset(
          offset: offset,
          measuredAt: measuredAt ?? t0,
          source: ClockOffsetSource.syncShot,
        ),
      );

  group('standard read', () {
    test('measures the offset on first connect', () async {
      client.cameraTimeValue = t0.subtract(cameraLag).toLocal();
      final sync = cubit();

      await sync.start();

      expect(sync.state, const ClockResolved(ClockResolution.fresh, cameraLag));
      final stored = await sessions.clockOffset();
      expect(stored?.offset, cameraLag);
      expect(stored?.source, ClockOffsetSource.standardRead);
    });

    test('keeps the stored offset within the tolerance', () async {
      const storedOffset = Duration(seconds: 89);
      await storeOffset(storedOffset);
      client.cameraTimeValue = t0.subtract(cameraLag);
      final sync = cubit();

      await sync.start();

      expect(
        sync.state,
        const ClockResolved(ClockResolution.fresh, storedOffset),
      );
      expect((await sessions.clockOffset())?.offset, storedOffset);
    });

    test('auto-applies drift above the tolerance', () async {
      await storeOffset(Duration.zero);
      client.cameraTimeValue = t0.subtract(cameraLag);
      final sync = cubit();

      await sync.start();

      expect(
        sync.state,
        const ClockResolved(
          ClockResolution.corrected,
          cameraLag,
          previous: Duration.zero,
        ),
      );
      expect((await sessions.clockOffset())?.offset, cameraLag);
    });
  });

  group('without a camera clock', () {
    test('prompts without an offset and can assume zero', () async {
      final sync = cubit();

      await sync.start();
      expect(sync.state, const ClockPrompt());

      await sync.useLastOffset();
      expect(
        sync.state,
        const ClockResolved(ClockResolution.assumed, Duration.zero),
      );
      expect(await sessions.clockOffset(), isNull);
    });

    test('uses a fresh stored offset without prompting', () async {
      await storeOffset(cameraLag);
      now = t0.add(offsetFreshness);
      final sync = cubit();

      await sync.start();

      expect(
        sync.state,
        const ClockResolved(ClockResolution.stored, cameraLag),
      );
    });

    test('prompts for a stale offset and can use it', () async {
      await storeOffset(cameraLag);
      now = t0.add(offsetFreshness + const Duration(seconds: 1));
      final sync = cubit();

      await sync.start();
      expect(sync.state, const ClockPrompt(lastOffset: cameraLag));

      await sync.useLastOffset();
      expect(
        sync.state,
        const ClockResolved(
          ClockResolution.assumed,
          cameraLag,
          previous: cameraLag,
        ),
      );
    });
  });

  group('sync shot', () {
    test('uses the midpoint of the listing window', () async {
      final sync = cubit();
      await sync.start();
      client.onList = (listing) {
        if (listing == 2) {
          client.objects.add(shot(1, t0.add(const Duration(seconds: 3))));
        }
      };

      await sync.syncShot();

      expect(
        sync.state,
        const ClockResolved(ClockResolution.syncShot, cameraLag),
      );
      expect(
        (await sessions.clockOffset())?.source,
        ClockOffsetSource.syncShot,
      );
      expect(
        await seen.stateOf(
          SessionSeenStore.keyOf(cameraKey, client.objects.single),
        ),
        SeenState.excluded,
      );
    });

    test('spans whole listings slower than the poll interval', () async {
      client.listDuration = const Duration(seconds: 3);
      final sync = cubit();
      await sync.start();
      client.onList = (listing) {
        if (listing == 1) {
          client.objects.add(shot(1, t0.add(const Duration(seconds: 4))));
        }
      };

      await sync.syncShot();

      expect(
        sync.state,
        const ClockResolved(ClockResolution.syncShot, cameraLag),
      );
    });

    test('asks to retry when the window is too long', () async {
      client.listDuration = const Duration(seconds: 6);
      final sync = cubit();
      await sync.start();
      client.onList = (listing) {
        if (listing == 1) {
          client.objects.add(shot(1, t0.add(const Duration(seconds: 7))));
        }
      };

      await sync.syncShot();

      expect(
        sync.state,
        const ClockPrompt(failure: ClockSyncFailure.windowTooLong),
      );
      expect(await sessions.clockOffset(), isNull);
      expect(
        await seen.stateOf(
          SessionSeenStore.keyOf(cameraKey, client.objects.single),
        ),
        isNull,
      );
    });

    test('excludes only the sync photo among new photos', () async {
      final sync = cubit();
      await sync.start();
      client.onList = (listing) {
        if (listing == 2) {
          client.objects.addAll([
            shot(1, t0.add(const Duration(seconds: 3))),
            shot(2, t0.add(const Duration(seconds: 3))),
          ]);
        }
      };

      await sync.syncShot();

      expect(sync.state, isA<ClockResolved>());
      final [syncPhoto, other] = client.objects;
      expect(
        await seen.stateOf(SessionSeenStore.keyOf(cameraKey, syncPhoto)),
        SeenState.excluded,
      );
      expect(
        await seen.stateOf(SessionSeenStore.keyOf(cameraKey, other)),
        isNull,
      );
    });

    test('gives up after the timeout', () async {
      final sync = cubit();
      await sync.start();

      await sync.syncShot();

      expect(sync.state, const ClockPrompt(failure: ClockSyncFailure.timeout));
      expect(now.difference(t0), greaterThanOrEqualTo(syncShotTimeout));
    });
  });

  group('mark then reconnect', () {
    final markedAt = t0.add(const Duration(hours: 1));
    late CameraObject old;
    late CameraObject first;
    late CameraObject second;

    setUp(() async {
      old = shot(1, t0);
      first = shot(5, markedAt.add(const Duration(seconds: 30)));
      second = shot(3, markedAt.add(const Duration(minutes: 5)));
      client.objects.addAll([old, first, second]);
      await sessions.setMarkedAt(markedAt);
      now = markedAt.add(const Duration(hours: 1));
    });

    test('proposes the earliest new photo and pages to the next', () async {
      await seen.setBaseline(cameraKey, [
        SessionSeenStore.keyOf(cameraKey, old),
      ]);
      final sync = cubit();

      await sync.start();
      final proposed = sync.state as ClockAwaitingMarkedPhoto;
      expect(proposed.candidate.jpeg, second);

      await sync.nextMarkedPhoto();
      expect((sync.state as ClockAwaitingMarkedPhoto).candidate.jpeg, first);

      await sync.confirmMarkedPhoto();
      final expected = markedAt.difference(first.captureDate!.toUtc());
      expect(sync.state, ClockResolved(ClockResolution.markedPhoto, expected));
      expect((await sessions.clockOffset())?.offset, expected);
      expect(await sessions.markedAt(), isNull);
      expect(
        await seen.stateOf(SessionSeenStore.keyOf(cameraKey, first)),
        SeenState.excluded,
      );
    });

    test('orders candidates newest first without a baseline', () async {
      final sync = cubit();

      await sync.start();
      expect((sync.state as ClockAwaitingMarkedPhoto).candidate.jpeg, second);
      await sync.nextMarkedPhoto();
      expect((sync.state as ClockAwaitingMarkedPhoto).candidate.jpeg, first);
      await sync.nextMarkedPhoto();
      expect((sync.state as ClockAwaitingMarkedPhoto).candidate.jpeg, old);

      await sync.nextMarkedPhoto();
      expect(sync.state, const ClockPrompt(failure: ClockSyncFailure.noPhoto));
      expect(await sessions.markedAt(), isNull);
    });
  });
}
