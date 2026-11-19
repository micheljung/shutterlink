import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/intervalometer/interval_plan.dart';
import 'package:shutterlink/feature/intervalometer/interval_run.dart';
import 'package:shutterlink/remote/shutter_remote.dart';

import '../../fakes/fake_shutter_remote.dart';

void main() {
  late FakeShutterRemote remote;

  setUp(() => remote = FakeShutterRemote());

  IntervalRun runOf(FakeAsync async, IntervalPlan plan) => IntervalRun(
    plan: plan,
    remote: remote,
    clock: async.getClock(DateTime(2026, 11, 19, 20)),
  )..start();

  test('fires on schedule and finishes after the last shot', () {
    fakeAsync((async) {
      final run = runOf(
        async,
        const IntervalPlan(interval: Duration(seconds: 5), shots: 3),
      );
      async.elapse(Duration.zero);
      expect(run.snapshot.taken, 1);
      async.elapse(const Duration(seconds: 5));
      expect(run.snapshot.taken, 2);
      async.elapse(const Duration(seconds: 5));
      expect(run.snapshot.taken, 3);
      async.elapse(const Duration(seconds: 1));
      expect(run.snapshot.phase, RunPhase.finished);
      expect(remote.events, ['shoot', 'shoot', 'shoot']);
    });
  });

  test('waits for the start delay', () {
    fakeAsync((async) {
      final run = runOf(
        async,
        const IntervalPlan(startDelay: Duration(seconds: 10), shots: 2),
      );
      expect(run.snapshot.phase, RunPhase.starting);
      async.elapse(const Duration(seconds: 9));
      expect(run.snapshot.taken, 0);
      async.elapse(const Duration(seconds: 1));
      expect(run.snapshot.taken, 1);
    });
  });

  test('holds a bulb exposure for its ramped length', () {
    fakeAsync((async) {
      final run = runOf(
        async,
        const IntervalPlan(
          control: ExposureControl.bulb,
          exposure: Duration(seconds: 2),
          rampTo: Duration(seconds: 8),
          interval: Duration(seconds: 10),
          shots: 3,
        ),
      );
      async.elapse(Duration.zero);
      expect(run.snapshot.phase, RunPhase.exposing);
      async.elapse(const Duration(milliseconds: 1999));
      expect(remote.events, ['shoot']);
      async.elapse(const Duration(milliseconds: 1));
      expect(remote.events, ['shoot', 'shoot']);
      expect(run.snapshot.phase, RunPhase.waiting);
      async.elapse(const Duration(seconds: 8));
      expect(
        run.snapshot.exposureEndsAt!.difference(
          run.snapshot.exposureStartedAt!,
        ),
        const Duration(seconds: 4),
      );
      async.elapse(const Duration(seconds: 10));
      async.elapse(const Duration(milliseconds: 7999));
      expect(run.snapshot.phase, RunPhase.exposing);
      async.elapse(const Duration(milliseconds: 1));
      expect(run.snapshot.phase, RunPhase.finished);
      expect(run.snapshot.taken, 3);
    });
  });

  test('counts shots due while disconnected as missed and keeps the pace', () {
    fakeAsync((async) {
      final run = runOf(
        async,
        const IntervalPlan(interval: Duration(seconds: 5), shots: 4),
      );
      async.elapse(Duration.zero);
      remote.setLink(RemoteLink.connecting);
      async.elapse(const Duration(seconds: 5));
      expect(run.snapshot.missed, 1);
      remote.setLink(RemoteLink.connected);
      async.elapse(const Duration(seconds: 5));
      expect(run.snapshot.taken, 2);
      expect(run.snapshot.nextShotAt, DateTime(2026, 11, 19, 20, 0, 15));
    });
  });

  test('a failed press counts as missed', () {
    fakeAsync((async) {
      remote.failing = true;
      final run = runOf(async, const IntervalPlan(shots: 2));
      async.elapse(Duration.zero);
      expect(run.snapshot.missed, 1);
      expect(run.snapshot.taken, 0);
    });
  });

  test('pause keeps the time left to the next shot', () {
    fakeAsync((async) {
      final run = runOf(
        async,
        const IntervalPlan(interval: Duration(seconds: 10), shots: 3),
      );
      async.elapse(const Duration(seconds: 4));
      run.pause();
      async.elapse(const Duration(minutes: 1));
      expect(run.snapshot.taken, 1);
      run.resume();
      async.elapse(const Duration(seconds: 5));
      expect(run.snapshot.taken, 1);
      async.elapse(const Duration(seconds: 1));
      expect(run.snapshot.taken, 2);
    });
  });

  test('stop closes an open bulb exposure', () {
    fakeAsync((async) {
      final run = runOf(
        async,
        const IntervalPlan(
          control: ExposureControl.bulb,
          exposure: Duration(seconds: 30),
          interval: Duration(seconds: 31),
          shots: 1,
        ),
      );
      async.elapse(const Duration(seconds: 3));
      run.stop();
      async.flushMicrotasks();
      expect(remote.events, ['shoot', 'shoot']);
      expect(run.snapshot.phase, RunPhase.stopped);
    });
  });

  test('an exposure that fails to close is closed once the camera is back', () {
    fakeAsync((async) {
      final run = runOf(
        async,
        const IntervalPlan(
          control: ExposureControl.bulb,
          exposure: Duration(seconds: 5),
          interval: Duration(seconds: 6),
          shots: 1,
        ),
      );
      async.elapse(Duration.zero);
      remote.failing = true;
      async.elapse(const Duration(seconds: 5));
      expect(run.snapshot.phase, isNot(RunPhase.finished));
      expect(run.snapshot.closeFailed, isTrue);
      remote.failing = false;
      remote.setLink(RemoteLink.connecting);
      remote.setLink(RemoteLink.connected);
      async.flushMicrotasks();
      expect(remote.events, ['shoot', 'shoot']);
      expect(run.snapshot.phase, RunPhase.finished);
    });
  });

  test('records a clip of the set length each interval', () {
    fakeAsync((async) {
      final run = runOf(
        async,
        const IntervalPlan(
          control: ExposureControl.video,
          exposure: Duration(seconds: 10),
          interval: Duration(minutes: 1),
          shots: 2,
        ),
      );
      async.elapse(const Duration(seconds: 10));
      expect(remote.events, ['record', 'record']);
      async.elapse(const Duration(minutes: 1));
      expect(run.snapshot.phase, RunPhase.finished);
      expect(remote.events, ['record', 'record', 'record', 'record']);
    });
  });

  test('wakes the camera before a shot only on long intervals', () {
    fakeAsync((async) {
      runOf(
        async,
        const IntervalPlan(interval: Duration(minutes: 3), shots: 2),
      );
      async.elapse(const Duration(minutes: 3) - IntervalRun.wakeLead);
      expect(remote.events, ['shoot', 'wake']);
      async.elapse(IntervalRun.wakeLead);
      expect(remote.events, ['shoot', 'wake', 'shoot']);
    });
  });

  test('estimates the end at the current pace', () {
    fakeAsync((async) {
      final run = runOf(
        async,
        const IntervalPlan(interval: Duration(seconds: 10), shots: 4),
      );
      async.elapse(Duration.zero);
      expect(
        run.snapshot.endsAt(DateTime(2026, 11, 19, 20)),
        DateTime(2026, 11, 19, 20, 0, 30),
      );
    });
  });

  test('stop during the opening click closes what it opened', () {
    fakeAsync((async) {
      remote.clickTime = const Duration(milliseconds: 300);
      final run = runOf(
        async,
        const IntervalPlan(
          control: ExposureControl.bulb,
          exposure: Duration(seconds: 10),
          interval: Duration(seconds: 12),
          shots: 5,
        ),
      );
      async.elapse(const Duration(milliseconds: 100));
      run.stop();
      async.elapse(const Duration(minutes: 1));
      expect(remote.events, ['shoot', 'shoot']);
      expect(run.snapshot.phase, RunPhase.stopped);
    });
  });

  test('stop during the closing click does not open another', () {
    fakeAsync((async) {
      remote.clickTime = const Duration(milliseconds: 300);
      final run = runOf(
        async,
        const IntervalPlan(
          control: ExposureControl.bulb,
          exposure: Duration(seconds: 10),
          interval: Duration(seconds: 12),
          shots: 5,
        ),
      );
      async.elapse(const Duration(seconds: 10, milliseconds: 400));
      run.stop();
      async.elapse(const Duration(minutes: 1));
      expect(remote.events, ['shoot', 'shoot']);
    });
  });

  test('a stopped run never fires again', () {
    fakeAsync((async) {
      remote.clickTime = const Duration(milliseconds: 300);
      final run = runOf(
        async,
        const IntervalPlan(interval: Duration(seconds: 2), shots: 10),
      );
      async.elapse(const Duration(milliseconds: 100));
      run.stop();
      async.elapse(const Duration(minutes: 1));
      expect(remote.events, ['shoot']);
    });
  });

  test('pause during a click holds the next shots', () {
    fakeAsync((async) {
      remote.clickTime = const Duration(milliseconds: 300);
      final run = runOf(
        async,
        const IntervalPlan(interval: Duration(seconds: 2), shots: 10),
      );
      async.elapse(const Duration(milliseconds: 100));
      run.pause();
      async.elapse(const Duration(minutes: 1));
      expect(remote.events, ['shoot']);
      expect(run.snapshot.phase, RunPhase.paused);
    });
  });

  test('an exposure that failed to close is retried at the next shot', () {
    fakeAsync((async) {
      final run = runOf(
        async,
        const IntervalPlan(
          control: ExposureControl.bulb,
          exposure: Duration(seconds: 5),
          interval: Duration(seconds: 6),
          shots: 3,
        ),
      );
      async.elapse(Duration.zero);
      remote.failing = true;
      async.elapse(const Duration(seconds: 5));
      expect(run.snapshot.closeFailed, isTrue);
      remote.failing = false;
      async.elapse(const Duration(seconds: 1));
      expect(run.snapshot.closeFailed, isFalse);
      expect(run.snapshot.missed, 1);
      async.elapse(const Duration(seconds: 6));
      expect(run.snapshot.taken, 2);
    });
  });

  test('stop before start does nothing', () {
    fakeAsync((async) {
      final run = IntervalRun(plan: const IntervalPlan(), remote: remote);
      expect(run.stop, returnsNormally);
      run.pause();
      async.flushMicrotasks();
      expect(remote.events, isEmpty);
    });
  });
}
