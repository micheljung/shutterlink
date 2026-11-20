import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/intervalometer_repository.dart';
import 'package:shutterlink/feature/intervalometer/interval_plan.dart';
import 'package:shutterlink/feature/intervalometer/interval_presets.dart';
import 'package:shutterlink/feature/intervalometer/interval_run.dart';
import 'package:shutterlink/feature/intervalometer/intervalometer_cubit.dart';
import 'package:shutterlink/remote/shutter_remote.dart';

import '../../fakes/fake_live_service.dart';
import '../../fakes/fake_shutter_remote.dart';

void main() {
  const camera = RemoteCamera(id: 'AA:BB', name: 'EOS R');
  late SharedPreferences prefs;
  late IntervalometerRepository repository;
  late FakeRemoteBluetooth bluetooth;
  late FakeLiveService service;
  late int alarms;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    repository = IntervalometerRepository(prefs);
    bluetooth = FakeRemoteBluetooth();
    service = FakeLiveService();
    alarms = 0;
  });

  IntervalometerCubit cubitOf() => IntervalometerCubit(
    repository: repository,
    bluetooth: bluetooth,
    service: service,
    alarm: () => alarms++,
  );

  test('pairing remembers the camera and connects it', () async {
    final cubit = cubitOf();
    await cubit.paired(camera, bluetooth.remote);
    expect(cubit.state.camera, camera);
    expect(cubit.state.link, RemoteLink.connected);
    expect(repository.camera, camera);
    expect(cubitOf().state.camera, camera);
  });

  test('opening reconnects the paired camera, closing lets it go', () async {
    await repository.setCamera(camera);
    final cubit = cubitOf();
    await cubit.opened();
    expect(cubit.state.link, RemoteLink.connected);
    await cubit.closed();
    expect(bluetooth.remote.events, ['connect', 'disconnect']);
  });

  test('pairing lets the saved camera go until the sheet closes', () async {
    await repository.setCamera(camera);
    final cubit = cubitOf();
    await cubit.opened();
    await cubit.suspendForPairing();
    expect(bluetooth.remote.events, ['connect', 'disconnect']);
    expect(cubit.state.link, RemoteLink.disconnected);
    expect(cubit.state.camera, camera);

    // Nothing brings it back while the sheet is open.
    await cubit.reconnect();
    expect(bluetooth.remote.events, ['connect', 'disconnect']);

    await cubit.resumeAfterPairing();
    expect(bluetooth.remote.events, ['connect', 'disconnect', 'connect']);
    expect(cubit.state.link, RemoteLink.connected);
  });

  test('a run keeps its camera while the pairing sheet is open', () {
    fakeAsync((async) {
      final cubit = cubitOf();
      cubit.paired(camera, bluetooth.remote);
      cubit.setPlan(const IntervalPlan(interval: Duration(seconds: 5)));
      async.flushMicrotasks();
      cubit.start();
      async.elapse(Duration.zero);
      cubit.suspendForPairing();
      async.flushMicrotasks();
      expect(bluetooth.remote.events, isNot(contains('disconnect')));
      expect(cubit.state.link, RemoteLink.connected);
      cubit.stop();
      async.elapse(const Duration(seconds: 1));
    });
  });

  test('without Bluetooth access the camera stays disconnected', () async {
    await repository.setCamera(camera);
    bluetooth.granted = false;
    final cubit = cubitOf();
    await cubit.opened();
    expect(cubit.state.link, RemoteLink.disconnected);
  });

  test('presets keep the start delay and the plan is remembered', () async {
    final cubit = cubitOf();
    cubit.setPlan(const IntervalPlan(startDelay: Duration(seconds: 10)));
    cubit.applyPreset(IntervalPreset.stars);
    expect(cubit.state.plan.startDelay, const Duration(seconds: 10));
    expect(cubit.state.preset, IntervalPreset.stars);
    await pumpEventQueue();
    expect(repository.plan, cubit.state.plan);
  });

  test('a run shows in the notification and stops from it', () {
    fakeAsync((async) {
      final cubit = cubitOf();
      cubit.paired(camera, bluetooth.remote);
      cubit.setPlan(
        const IntervalPlan(interval: Duration(seconds: 5), shots: 3),
      );
      async.flushMicrotasks();
      cubit.start();
      async.elapse(Duration.zero);
      expect(service.calls.first, 'start');
      expect(cubit.state.run?.taken, 1);
      expect(service.statuses.last.text, startsWith('Shot 1 of 3'));
      service.stopController.add(null);
      async.flushMicrotasks();
      expect(cubit.state.run?.phase, RunPhase.stopped);
      expect(service.calls.last, 'stop');
    });
  });

  test('losing the camera mid-run sounds the alarm', () {
    fakeAsync((async) {
      final cubit = cubitOf();
      cubit.paired(camera, bluetooth.remote);
      async.flushMicrotasks();
      cubit.start();
      async.elapse(Duration.zero);
      bluetooth.remote.setLink(RemoteLink.connecting);
      async.flushMicrotasks();
      expect(alarms, 1);
      expect(service.statuses.last.text, contains('reconnecting'));
    });
  });

  test('cannot start without a connected camera or with a bad plan', () {
    fakeAsync((async) {
      final cubit = cubitOf();
      expect(cubit.state.canStart, isFalse);
      cubit.paired(camera, bluetooth.remote);
      async.flushMicrotasks();
      expect(cubit.state.canStart, isTrue);
      cubit.setPlan(
        const IntervalPlan(
          control: ExposureControl.bulb,
          exposure: Duration(seconds: 30),
          interval: Duration(seconds: 10),
        ),
      );
      expect(cubit.state.canStart, isFalse);
    });
  });

  test('a finished run can be dismissed back to the setup', () {
    fakeAsync((async) {
      final cubit = cubitOf();
      cubit.paired(camera, bluetooth.remote);
      cubit.setPlan(const IntervalPlan(shots: 1));
      async.flushMicrotasks();
      cubit.start();
      async.elapse(const Duration(seconds: 1));
      expect(cubit.state.run?.phase, RunPhase.finished);
      expect(service.calls.last, 'stop');
      cubit.dismissRun();
      expect(cubit.state.run, isNull);
    });
  });
}
