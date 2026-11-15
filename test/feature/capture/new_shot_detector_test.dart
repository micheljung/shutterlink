import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/capture/new_shot_detector.dart';

import '../../fakes/fake_camera_client.dart';

class _CountingClient extends FakeCameraClient {
  _CountingClient(super.objects);

  int diffs = 0;
  Completer<void>? diffGate;
  Object? failNextDiff;

  @override
  Future<List<int>> newestFolderHandles() async {
    diffs++;
    await diffGate?.future;
    final failure = failNextDiff;
    failNextDiff = null;
    if (failure != null) throw failure;
    return super.newestFolderHandles();
  }
}

const _tick = Duration(milliseconds: 20);

void main() {
  late _CountingClient client;
  late List<NewShotDetector> detectors;
  late List<int> emitted;

  setUp(() {
    client = _CountingClient([
      cameraObject(1, 'IMG_0001.JPG'),
      cameraObject(2, 'IMG_0002.JPG'),
    ]);
    detectors = [];
    emitted = [];
  });

  tearDown(() async {
    for (final detector in detectors) {
      await detector.close();
    }
  });

  NewShotDetector detector({
    Set<int> baseline = const {},
    Set<int>? resolved,
    bool Function()? busy,
    Duration interval = _tick,
  }) {
    final created = NewShotDetector(
      client: client,
      baseline: baseline,
      isResolved: (resolved ?? <int>{}).contains,
      consumerBusy: busy ?? () => false,
      interval: interval,
    );
    detectors.add(created);
    created.handles.listen(emitted.add);
    return created..start();
  }

  Future<void> ticks(int count) => Future<void>.delayed(_tick * count);

  test('an event emits its handle', () async {
    detector(interval: const Duration(days: 1));

    client.emitAdded(7);
    await pumpEventQueue();

    expect(emitted, [7]);
  });

  test('the diff finds a shot with no events', () async {
    detector(baseline: {1, 2});
    client.objects.add(cameraObject(3, 'IMG_0003.JPG'));

    await ticks(3);

    expect(emitted, isNotEmpty);
    expect(emitted.toSet(), {3});
  });

  test(
    'an unresolved handle is emitted again, a resolved one is not',
    () async {
      final resolved = <int>{};
      detector(resolved: resolved);

      await ticks(4);
      expect(emitted.where((h) => h == 1).length, greaterThan(1));

      resolved.add(1);
      await pumpEventQueue();
      emitted.clear();
      await ticks(3);

      expect(emitted, isNotEmpty);
      expect(emitted, everyElement(2));
    },
  );

  test('a storage change diffs at once, before the timer fires', () async {
    detector(baseline: {1, 2}, interval: const Duration(days: 1));
    client.objects.add(cameraObject(3, 'IMG_0003.JPG'));

    client.emitStorageChanged();
    await pumpEventQueue();

    expect(emitted, [3]);
  });

  test('a storage change while the consumer is busy waits for idle', () async {
    var busy = true;
    final live = detector(
      baseline: {1, 2},
      busy: () => busy,
      interval: const Duration(days: 1),
    );
    client.objects.add(cameraObject(3, 'IMG_0003.JPG'));

    client.emitStorageChanged();
    await pumpEventQueue();
    expect(client.diffs, 0);

    busy = false;
    live.notifyIdle();
    await pumpEventQueue();

    expect(emitted, [3]);
  });

  test('a diff that fails with an Error is retried on the next tick', () async {
    client.failNextDiff = StateError('broken');
    detector(baseline: {1});

    await ticks(4);

    expect(client.diffs, greaterThan(1));
    expect(emitted, contains(2));
  });

  test('baseline handles are never emitted by a diff', () async {
    detector(baseline: {1, 2});

    await ticks(4);

    expect(emitted, isEmpty);
  });

  test('close stops the timer', () async {
    final live = detector();
    await ticks(2);
    await live.close();
    await pumpEventQueue();
    final diffs = client.diffs;

    await ticks(4);

    expect(client.diffs, diffs);
  });

  test('a disconnect stops the timer', () async {
    detector();
    await ticks(2);
    client.simulateDisconnect();
    await pumpEventQueue();
    final diffs = client.diffs;

    await ticks(4);

    expect(client.diffs, diffs);
  });

  test('a busy consumer defers the diff to one run when it is idle', () async {
    var busy = true;
    final live = detector(busy: () => busy);

    await ticks(5);
    expect(client.diffs, 0);
    expect(emitted, isEmpty);

    busy = false;
    live.notifyIdle();
    expect(client.diffs, 1);
    await pumpEventQueue();

    expect(emitted.take(2), [1, 2]);
  });

  test('ticks during a running diff coalesce into one more diff', () async {
    client.diffGate = Completer<void>();
    detector();

    await ticks(5);
    expect(client.diffs, 1);

    client.diffGate!.complete();
    await pumpEventQueue();

    expect(client.diffs, 2);
  });
}
