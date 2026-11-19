import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/identity_repository.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connect_state.dart';
import 'package:shutterlink/feature/mode/mode_cubit.dart';
import 'package:shutterlink/feature/mode/operating_mode.dart';
import 'package:shutterlink/feature/qr_session/qr_session_cubit.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_live_service.dart';
import '../../fakes/recording_binder.dart';
import '../../fakes/spy_sessions_dependencies.dart';
import '../../upload/upload_fakes.dart';

class _UnreadableClient extends FakeCameraClient {
  _UnreadableClient() : super(const []);

  @override
  Future<List<int>> newestFolderHandles() =>
      Future.error(const PtpResponseException(0x1008, 0x2019));
}

/// Waits in real time, since the Sessions stores write files.
Future<void> _until(FutureOr<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!await condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(await condition(), isTrue, reason: 'condition never became true');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late SpySessionsDependencies sessions;
  late FakeLiveService service;
  late RecordingBinder binder;
  late FakeTimers timers;
  late FakeCameraClient first;
  late List<Object> connections;
  late ConnectCubit connect;
  late ModeCubit modes;
  late QrSessionCubit cubit;

  QrSessionCubit build() => QrSessionCubit(
    connect: connect,
    modes: modes,
    service: service,
    sessions: sessions,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    root = await Directory.systemTemp.createTemp('qr_session');
    sessions = SpySessionsDependencies(
      SettingsRepository(prefs),
      root,
      token: 'token',
    );
    service = FakeLiveService();
    binder = RecordingBinder();
    timers = FakeTimers();
    first = FakeCameraClient([cameraObject(1, 'IMG_0001.JPG')]);
    connections = [first];
    connect = ConnectCubit(
      claimsUsbVendor: (_) => false,
      connector: (_) async {
        final next = connections.removeAt(0);
        if (next is Exception) throw next;
        return next as CameraClient;
      },
      identity: IdentityRepository(prefs),
      hostResolver: CameraHostResolver(
        SettingsRepository(prefs),
        wifiGateway: () async => null,
      ),
      networkBinder: binder,
      timerFactory: timers.create,
    );
    await connect.connect();
    modes = ModeCubit();
  });

  tearDown(() async {
    await cubit.close();
    await modes.close();
    await connect.close();
    await service.stopController.close();
    await pumpEventQueue();
    await root.delete(recursive: true);
  });

  Future<bool> windowOpen() async => await sessions.repository.active() != null;

  Future<void> enter() async {
    modes.select(OperatingMode.qrSession);
    await _until(() => cubit.state.client == first);
  }

  Future<void> fire() async {
    timers.active!.fire();
    await pumpEventQueue();
  }

  test('entering opens a new Session, runs the service as Live Share and '
      'holds the Wi-Fi', () async {
    cubit = build();

    await enter();

    expect(await windowOpen(), isTrue);
    expect(cubit.state.resumable, isNull);
    expect(service.calls.first, 'start');
    expect(service.statuses.first.title, QrSessionCubit.title);
    expect(binder.calls, contains('acquire connect hold'));
    expect(sessions.clockSyncs, 1);
    expect(sessions.collectors, 1);
  });

  test('leaving closes the window and stops the service', () async {
    cubit = build();
    await enter();

    modes.leave();
    await _until(
      () async => !await windowOpen() && service.calls.last == 'stop',
    );

    expect(service.calls.last, 'stop');
    expect(cubit.state, const QrSessionState());
  });

  test(
    'a camera that drops after leaving reconnects without the hold',
    () async {
      connections.add(FakeCameraClient(const []));
      cubit = build();
      await enter();
      modes.leave();
      await _until(() => service.calls.last == 'stop');
      binder.calls.clear();

      first.simulateDisconnect();
      await pumpEventQueue();
      await fire();

      expect(binder.calls, ['acquire connect']);
    },
  );

  test('Abort closes the window', () async {
    connections.add(unreachable);
    cubit = build();
    await enter();

    first.simulateDisconnect();
    await pumpEventQueue();
    expect(connect.state, isA<ConnectReconnecting>());
    modes.leave();
    await connect.abortReconnect();
    await _until(
      () async => !await windowOpen() && service.calls.last == 'stop',
    );

    expect(connect.state, const ConnectIdle());
    expect(cubit.state.active, isFalse);
  });

  test('the notification Stop goes back to the picker with the camera '
      'connected, and closes the window', () async {
    cubit = build();
    await enter();

    service.stopController.add(null);
    await _until(
      () async => !await windowOpen() && service.calls.last == 'stop',
    );

    expect(modes.state, isNull);
    expect(connect.state, ConnectConnected(first));
    expect(first.closed, isFalse);
  });

  test('a window left open by a crash is closed at startup', () async {
    await sessions.repository.start();

    cubit = build();

    await _until(() async => !await windowOpen());
    expect(service.calls, isEmpty);
  });

  test('re-entering asks to resume the previous Session, and Resume opens a '
      'new window of it', () async {
    final previous = await sessions.repository.start();
    await sessions.repository.stop();
    cubit = build();

    await enter();
    expect(cubit.state.resumable?.id, previous.id);
    expect(await windowOpen(), isFalse);

    await cubit.resume();

    final active = await sessions.repository.active();
    expect(active?.id, previous.id);
    expect(active?.intervals, hasLength(2));
    expect(cubit.state.resumable, isNull);
    expect(await sessions.repository.all(), hasLength(1));
  });

  test(
    're-entering and starting new leaves the previous Session closed',
    () async {
      final previous = await sessions.repository.start();
      await sessions.repository.stop();
      cubit = build();
      await enter();

      await cubit.startNew();

      final active = await sessions.repository.active();
      expect(active, isNotNull);
      expect(active?.id, isNot(previous.id));
      expect(cubit.state.resumable, isNull);
    },
  );

  test('an expired Session is not offered', () async {
    final previous = await sessions.repository.start();
    await sessions.repository.stop();
    await sessions.repository.markExpired(previous.code);
    cubit = build();

    await enter();
    await _until(windowOpen);

    expect(cubit.state.resumable, isNull);
    expect((await sessions.repository.active())?.id, isNot(previous.id));
  });

  test('a window that fails to open still runs the mode, and Start new '
      'can be retried', () async {
    // A directory where the store writes its temporary file fails saving.
    final blocker = Directory('${root.path}/sessions.json.tmp')..createSync();
    cubit = build();

    await enter();

    expect(service.calls.first, 'start');
    expect(sessions.collectors, 1);
    await expectLater(cubit.startNew(), completes);

    blocker.deleteSync();
    await cubit.startNew();
    expect(await windowOpen(), isTrue);
  });

  test('a failed Resume clears the prompt', () async {
    final previous = await sessions.repository.start();
    await sessions.repository.stop();
    cubit = build();
    await enter();
    expect(cubit.state.resumable?.id, previous.id);
    await _until(() => service.calls.contains('start'));
    final blocker = Directory('${root.path}/sessions.json.tmp')..createSync();

    await expectLater(cubit.resume(), completes);

    expect(cubit.state.resumable, isNull);
    blocker.deleteSync();
  });

  test('a reconnect collects from the new client only', () async {
    final second = FakeCameraClient([cameraObject(1, 'IMG_0001.JPG')]);
    connections.add(second);
    cubit = build();
    await enter();

    first.simulateDisconnect();
    await pumpEventQueue();
    expect(cubit.state.client, isNull);
    expect(cubit.state.clockSync, isNull);
    await fire();
    await _until(() => cubit.state.client == second);

    expect(sessions.collectors, 2);
    expect(sessions.clockSyncs, 2);
    expect(await windowOpen(), isTrue);
  });

  test('a failed read of the card closes the client, so the camera '
      'reconnects', () async {
    final unreadable = _UnreadableClient();
    final second = FakeCameraClient(const []);
    connections.addAll([unreadable, second]);
    cubit = build();
    await enter();
    first.simulateDisconnect();
    await pumpEventQueue();
    await fire();
    await _until(() => unreadable.closed);

    expect(cubit.state.client, isNull);
    expect(sessions.collectors, 1);
    await fire();
    await _until(() => cubit.state.client == second);
    expect(sessions.collectors, 2);
  });

  test(
    'leaving and entering again at once offers the closed Session',
    () async {
      cubit = build();
      await enter();
      final open = await sessions.repository.active();

      modes
        ..leave()
        ..select(OperatingMode.qrSession);

      await _until(() => cubit.state.resumable?.id == open?.id);
      expect(await windowOpen(), isFalse);
      expect(cubit.state.active, isTrue);
    },
  );

  group('automatic resume', () {
    test('a window cut off by a killed app is resumed once the camera is '
        'connected', () async {
      final cut = await sessions.repository.start();
      await sessions.settings.setQrSessionAliveAt(DateTime.now());

      cubit = build();

      await _until(() => cubit.state.client == first);
      expect(modes.state, OperatingMode.qrSession);
      final active = await sessions.repository.active();
      expect(active?.id, cut.id);
      expect(active?.intervals, hasLength(2));
      expect(cubit.state.resumable, isNull);
      expect(cubit.state.autoResumed, isTrue);
    });

    test('stopping the resumed Session drops the resumed notice', () async {
      await sessions.repository.start();
      await sessions.settings.setQrSessionAliveAt(DateTime.now());
      cubit = build();
      await _until(() => cubit.state.autoResumed);

      await sessions.repository.stop();

      await _until(() => !cubit.state.autoResumed);
    });

    test(
      'a cut-off Session that cannot be reopened starts nothing unasked',
      () async {
        final cut = await sessions.repository.start();
        await sessions.repository.markExpired(cut.code);
        await sessions.settings.setQrSessionAliveAt(DateTime.now());

        cubit = build();

        await _until(() => cubit.state.client == first);
        expect(modes.state, OperatingMode.qrSession);
        expect(await windowOpen(), isFalse);
        expect(cubit.state.resumable, isNull);
        expect(cubit.state.autoResumed, isFalse);
      },
    );

    test('a window cut off long ago is closed and not resumed', () async {
      await sessions.repository.start();
      await sessions.settings.setQrSessionAliveAt(
        DateTime.now().subtract(
          QrSessionCubit.autoResumeWithin + const Duration(minutes: 1),
        ),
      );

      cubit = build();

      await _until(
        () async =>
            !await windowOpen() && sessions.settings.qrSessionAliveAt == null,
      );
      expect(modes.state, isNull);
    });

    test(
      'opening a window from the resume prompt marks it alive at once',
      () async {
        await sessions.repository.start();
        await sessions.repository.stop();
        cubit = build();
        await enter();
        expect(sessions.settings.qrSessionAliveAt, isNull);

        await cubit.resume();

        await _until(() => sessions.settings.qrSessionAliveAt != null);
      },
    );

    test('a window the user stopped is not resumed after a kill', () async {
      cubit = build();
      await enter();
      await _until(() async => sessions.settings.qrSessionAliveAt != null);
      modes.leave();
      await _until(
        () async => !await windowOpen() && service.calls.last == 'stop',
      );

      expect(sessions.settings.qrSessionAliveAt, isNull);
    });

    test('a mode ended by a lost camera comes back with its Session on the '
        'next connection', () async {
      final second = FakeCameraClient(const []);
      connections.add(second);
      cubit = build();
      await enter();
      final open = await sessions.repository.active();

      first.simulateDisconnect();
      await pumpEventQueue();
      modes.connectionLost();
      await _until(() async => !await windowOpen());
      await fire();

      await _until(() => cubit.state.client == second);
      expect(modes.state, OperatingMode.qrSession);
      expect((await sessions.repository.active())?.id, open?.id);
      expect(cubit.state.autoResumed, isTrue);
    });

    test('a mode the user left stays left on the next connection', () async {
      final second = FakeCameraClient(const []);
      connections.add(second);
      cubit = build();
      await enter();

      modes.leave();
      await _until(() async => !await windowOpen());
      first.simulateDisconnect();
      await pumpEventQueue();
      await fire();
      await _until(() => connect.state == ConnectConnected(second));
      await pumpEventQueue();

      expect(modes.state, isNull);
      expect(cubit.state.active, isFalse);
    });
  });
}
