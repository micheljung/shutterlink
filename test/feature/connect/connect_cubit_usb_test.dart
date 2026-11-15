import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/identity_repository.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connect_state.dart';
import 'package:shutterlink/usb/usb_camera_platform.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_usb_camera_watcher.dart';
import '../../upload/upload_fakes.dart';
import '../live/live_transfer_cubit_test.dart'
    show RecordingBinder, cameraGateway;

class _SlowClosingClient extends FakeCameraClient {
  _SlowClosingClient() : super([]);

  final closing = Completer<void>();

  @override
  Future<void> close() async {
    await closing.future;
    await super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final canon = usbCamera();
  final phone = usbCamera(vendorId: otherUsbVendor, name: 'iPhone');
  late SharedPreferences prefs;
  late RecordingBinder binder;
  late FakeUsbCameraWatcher watcher;
  late List<ConnectTarget> targets;
  late Map<Type, List<FutureOr<FakeCameraClient>>> answers;
  late int discoveries;
  late FakeTimers timers;
  late ConnectCubit cubit;

  Future<FakeCameraClient> answer(Type kind) async =>
      answers[kind]!.removeAt(0);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    binder = RecordingBinder();
    watcher = FakeUsbCameraWatcher()..permitted.addAll([canon, phone]);
    targets = [];
    answers = {WifiTarget: [], UsbTarget: []};
    discoveries = 0;
    timers = FakeTimers();
    cubit = ConnectCubit(
      connector: (target) {
        targets.add(target);
        return answer(target.runtimeType);
      },
      identity: IdentityRepository(prefs),
      hostResolver: CameraHostResolver(
        SettingsRepository(prefs),
        wifiGateway: () async => null,
      ),
      networkBinder: binder,
      claimsUsbVendor: claimsCanonOnly,
      usbWatcher: watcher,
      discovery: () async {
        discoveries++;
        return const [];
      },
      timerFactory: timers.create,
    );
  });

  tearDown(() => cubit.close());

  /// Answers the next connect over [kind] with a fresh client, or with the
  /// returned completer's client once the test completes it.
  FakeCameraClient next(Type kind) {
    final client = FakeCameraClient([]);
    answers[kind]!.add(client);
    return client;
  }

  Completer<FakeCameraClient> gated(Type kind) {
    final gate = Completer<FakeCameraClient>();
    answers[kind]!.add(gate.future);
    return gate;
  }

  Future<FakeCameraClient> connectWifi() async {
    final client = next(WifiTarget);
    await cubit.connect();
    expect(cubit.state, ConnectConnected(client));
    return client;
  }

  Future<void> plug(UsbCameraRef device, {bool enumerated = false}) async {
    watcher.attach(device, enumerated: enumerated);
    await pumpEventQueue();
  }

  Future<FakeCameraClient> connectUsb() async {
    final client = next(UsbTarget);
    await plug(canon);
    expect(cubit.state, ConnectConnected(client));
    return client;
  }

  Future<void> unplug(FakeCameraClient client) async {
    client.simulateDisconnect();
    watcher.detach(canon);
    await pumpEventQueue();
  }

  List<ConnectState> record() {
    final states = <ConnectState>[];
    cubit.stream.listen(states.add);
    return states;
  }

  test(
    'a USB camera connects without binding, discovery or identity',
    () async {
      final client = next(UsbTarget);
      final states = <ConnectState>[];
      cubit.stream.listen(states.add);

      await plug(canon);

      expect(states, [
        const ConnectConnecting(cameraName: 'Canon EOS R', usb: true),
        ConnectConnected(client),
      ]);
      expect((cubit.state as ConnectConnected).target, isA<UsbTarget>());
      expect(binder.calls, isEmpty);
      expect(discoveries, 0);
      expect(prefs.getKeys(), isEmpty, reason: 'no pairing identity is made');
      expect(targets.single, isA<UsbTarget>());
      expect((targets.single as UsbTarget).device, canon);
    },
  );

  test('USB wins over a slow Wi-Fi connect, whose client is closed', () async {
    final wifiGate = gated(WifiTarget);
    final usb = next(UsbTarget);
    final wifiConnect = cubit.connect();
    await pumpEventQueue();
    expect(cubit.state, const ConnectConnecting());

    await plug(canon);
    expect(cubit.state, ConnectConnected(usb));

    final lateWifi = FakeCameraClient([]);
    wifiGate.complete(lateWifi);
    await wifiConnect;

    expect(lateWifi.closed, isTrue);
    expect(cubit.state, ConnectConnected(usb));
    expect(binder.owners, isEmpty);
    expect(binder.calls, contains('release connect'));
  });

  test('USB takes over a connected Wi-Fi camera in place', () async {
    final wifi = await connectWifi();
    final usb = next(UsbTarget);
    final states = record();

    await plug(canon);

    expect(wifi.closed, isTrue);
    expect(states, [
      const ConnectReconnecting(usb: true),
      ConnectConnected(usb),
    ]);
    expect((cubit.state as ConnectConnected).target, isA<UsbTarget>());
    expect(binder.owners, isEmpty);
  });

  test('USB takes over a Wi-Fi camera that is reconnecting', () async {
    final wifi = await connectWifi();
    wifi.simulateDisconnect();
    await pumpEventQueue();
    expect(cubit.state, const ConnectReconnecting());
    final usb = next(UsbTarget);
    final states = record();

    await plug(canon);

    expect(states, [
      const ConnectReconnecting(usb: true),
      ConnectConnected(usb),
    ]);
    expect(binder.owners, isEmpty);
    expect(timers.active, isNull, reason: 'no Wi-Fi retry is left');
  });

  test(
    'a Wi-Fi connect wins over a USB connect, whose client is closed',
    () async {
      final usbGate = gated(UsbTarget);
      await plug(canon);
      expect(
        cubit.state,
        const ConnectConnecting(cameraName: 'Canon EOS R', usb: true),
      );

      final wifi = await connectWifi();
      final lateUsb = FakeCameraClient([]);
      usbGate.complete(lateUsb);
      await pumpEventQueue();

      expect(lateUsb.closed, isTrue);
      expect(cubit.state, ConnectConnected(wifi));
      expect(
        (cubit.state as ConnectConnected).target,
        isA<WifiTarget>().having((t) => t.host, 'host', cameraGateway),
      );
    },
  );

  test(
    'a Wi-Fi tap during a USB takeover wins and keeps its binding',
    () async {
      final slow = _SlowClosingClient();
      answers[WifiTarget]!.add(slow);
      await cubit.connect();
      expect(cubit.state, ConnectConnected(slow));
      final usbGate = gated(UsbTarget);

      await plug(canon);
      expect(cubit.state, const ConnectReconnecting(usb: true));
      final wifi = await connectWifi();
      final lateUsb = FakeCameraClient([]);
      usbGate.complete(lateUsb);
      slow.closing.complete();
      await pumpEventQueue();

      expect(lateUsb.closed, isTrue);
      expect(cubit.state, ConnectConnected(wifi));
      expect(binder.owners, {'connect'});
      expect(binder.calls.last, 'acquire connect');
    },
  );

  test('a Wi-Fi connect closes a connected USB camera', () async {
    final usb = next(UsbTarget);
    await plug(canon);
    expect(cubit.state, ConnectConnected(usb));

    await connectWifi();

    expect(usb.closed, isTrue);
  });

  test(
    'a Wi-Fi connect is ignored while Wi-Fi is already connecting',
    () async {
      final gate = gated(WifiTarget);
      final first = cubit.connect();
      await pumpEventQueue();
      await cubit.connect();
      final client = FakeCameraClient([]);
      gate.complete(client);
      await first;

      expect(targets, hasLength(1));
      expect(cubit.state, ConnectConnected(client));
    },
  );

  group('never takes over', () {
    test('for a camera that was already plugged in', () async {
      final wifi = await connectWifi();

      await plug(canon, enumerated: true);

      expect(wifi.closed, isFalse);
      expect(cubit.state, ConnectConnected(wifi));
    });

    test('for an unknown vendor while Wi-Fi is connected', () async {
      final wifi = await connectWifi();

      await plug(phone);

      expect(wifi.closed, isFalse);
      expect(cubit.state, ConnectConnected(wifi));
      expect(targets.whereType<UsbTarget>(), isEmpty);
    });

    test('for an unknown vendor while Wi-Fi is connecting', () async {
      final gate = gated(WifiTarget);
      final connecting = cubit.connect();
      await pumpEventQueue();

      await plug(phone);
      final wifi = FakeCameraClient([]);
      gate.complete(wifi);
      await connecting;

      expect(wifi.closed, isFalse);
      expect(cubit.state, ConnectConnected(wifi));
      expect(targets.whereType<UsbTarget>(), isEmpty);
    });

    test('while Live owns the camera, and leaves its drops to Live', () async {
      final wifi = await connectWifi();
      cubit.handOver('live');

      await plug(canon);
      wifi.simulateDisconnect();
      await pumpEventQueue();

      expect(cubit.state, const ConnectLiveOwned());
      expect(targets.whereType<UsbTarget>(), isEmpty);
      expect(timers.all, isEmpty, reason: 'the supervisor is paused');
    });

    test('while another USB camera is connected', () async {
      final usb = next(UsbTarget);
      await plug(canon);

      await plug(usbCamera(productId: 2));

      expect(usb.closed, isFalse);
      expect(targets, hasLength(1));
    });
  });

  test('an unknown vendor or a plugged-in camera connects from idle', () async {
    final first = next(UsbTarget);
    await plug(phone, enumerated: true);
    expect(cubit.state, ConnectConnected(first));

    await cubit.disconnect();
    final second = next(UsbTarget);
    await plug(canon, enumerated: true);
    expect(cubit.state, ConnectConnected(second));
  });

  test('unplug reconnects, and a re-plug connects at once', () async {
    final first = await connectUsb();

    await unplug(first);
    expect(cubit.state, const ConnectReconnecting(usb: true));

    watcher.permitted.add(canon);
    final second = next(UsbTarget);
    await plug(canon);
    expect(cubit.state, ConnectConnected(second));
    expect((cubit.state as ConnectConnected).target, isA<UsbTarget>());
    expect(timers.active, isNull);
    expect(binder.calls, isEmpty);
  });

  test('a re-plug of the camera while reconnecting retries at once', () async {
    final first = await connectUsb();
    await unplug(first);
    final retry = timers.active!;

    watcher.permitted.add(canon);
    final second = next(UsbTarget);
    await plug(canon);

    expect(retry.isActive, isFalse);
    expect(cubit.state, ConnectConnected(second));
  });

  test('another camera plugged in while reconnecting is ignored', () async {
    final first = await connectUsb();
    await unplug(first);

    await plug(usbCamera(productId: 2));

    expect(cubit.state, const ConnectReconnecting(usb: true));
    expect(targets, hasLength(1));
  });

  test('USB access from the background waits for the user', () async {
    final first = await connectUsb();
    await unplug(first);
    watcher.permissionAnswers.add(UsbPermission.userActionNeeded);

    await plug(canon);
    expect(
      cubit.state,
      const ConnectReconnecting(userActionNeeded: true, usb: true),
    );

    final second = next(UsbTarget);
    cubit.allowUsbAccess();
    await pumpEventQueue();
    expect(watcher.permissionRequests, [canon, canon]);
    expect(cubit.state, ConnectConnected(second));
  });

  test('abort while reconnecting over USB goes idle', () async {
    final first = await connectUsb();
    await unplug(first);

    await cubit.abortReconnect();

    expect(cubit.state, const ConnectIdle());
    expect(timers.active, isNull);
    expect(binder.calls, isEmpty);
  });

  group('the USB watch', () {
    test('starts with the cubit, before the connect screen', () {
      expect(watcher.calls.first, 'start ${ConnectCubit.usbWatchOwner}');
      expect(ConnectCubit.usbWatchOwner, isNot('connect'));
    });

    test('survives failures, drops and abort, and ends on close', () async {
      watcher
        ..permitted.clear()
        ..permissionAnswers.add(UsbPermission.denied);
      await plug(canon);
      expect(cubit.state, isA<ConnectFailed>());
      watcher.permitted.add(canon);
      final first = await connectUsb();
      await unplug(first);
      await cubit.abortReconnect();

      expect(watcher.calls, isNot(contains('stop connection')));
      await cubit.close();
      expect(watcher.calls.last, 'stop connection');
    });

    test('keeps an aborted camera idle with the cable still in', () async {
      watcher.start('connect');
      final first = await connectUsb();
      first.simulateDisconnect();
      await pumpEventQueue();
      expect(cubit.state, const ConnectReconnecting(usb: true));

      await cubit.abortReconnect();
      // The connect screen comes back.
      watcher
        ..stop('connect')
        ..start('connect');
      await pumpEventQueue();

      expect(cubit.state, const ConnectIdle());
      expect(watcher.ownersEmptied, isFalse);
      expect(targets, hasLength(1));
    });

    test('a fresh watch reports a plugged camera, which connects', () async {
      // Guards the test above: without the cubit's watch, it would fail.
      final first = await connectUsb();
      first.simulateDisconnect();
      await pumpEventQueue();
      await cubit.abortReconnect();
      next(UsbTarget);

      watcher
        ..stop(ConnectCubit.usbWatchOwner)
        ..start('connect');
      await pumpEventQueue();

      expect(cubit.state, isA<ConnectConnected>());
    });

    test('is released in the background without a camera', () async {
      cubit.appPaused();
      expect(watcher.calls.last, 'stop connection');

      cubit.appResumed();
      expect(watcher.calls.last, 'start connection');
    });

    test('is kept in the background with a camera', () async {
      await connectUsb();

      cubit.appPaused();
      cubit.appResumed();

      expect(watcher.calls, ['start connection']);
    });
  });

  group('permission', () {
    test('is asked for when missing', () async {
      watcher.permitted.clear();
      final client = next(UsbTarget);

      await plug(canon);

      expect(watcher.permissionRequests, [canon]);
      expect(cubit.state, ConnectConnected(client));
    });

    test('denied fails', () async {
      watcher
        ..permitted.clear()
        ..permissionAnswers.add(UsbPermission.denied);

      await plug(canon);

      expect(
        cubit.state,
        const ConnectFailed(ConnectCubit.usbPermissionDeniedMessage),
      );
      expect(targets, isEmpty);
    });

    test('pending in the background asks the user to act', () async {
      watcher
        ..permitted.clear()
        ..permissionAnswers.add(UsbPermission.userActionNeeded);

      await plug(canon);

      expect(
        cubit.state,
        const ConnectFailed(ConnectCubit.usbPermissionNeededMessage),
      );
    });
  });

  test('a USB camera that fails to open fails the connect', () async {
    answers[UsbTarget]!.add(Future.error(Exception('no_device')));

    await plug(canon);

    expect(cubit.state, isA<ConnectFailed>());
  });

  test('disconnecting USB releases no binding', () async {
    final usb = next(UsbTarget);
    await plug(canon);

    await cubit.disconnect();

    expect(usb.closed, isTrue);
    expect(cubit.state, const ConnectIdle());
    expect(binder.calls, isEmpty);
  });

  test('a take-back over USB after a Wi-Fi hand-over supervises USB', () async {
    final wifi = await connectWifi();
    expect(cubit.handOver('live'), wifi);
    // Live switched to the cable and released its Wi-Fi binding.
    await binder.releaseBinding('live');
    final usb = FakeCameraClient([]);

    expect(
      cubit.takeBack(usb, owner: 'live', target: UsbTarget(canon)),
      isTrue,
    );
    await pumpEventQueue();
    expect(binder.owners, isEmpty);

    final states = record();
    await unplug(usb);
    watcher.permitted.add(canon);
    final again = next(UsbTarget);
    await plug(canon);

    expect(states, [
      const ConnectReconnecting(usb: true),
      ConnectConnected(again),
    ]);
    expect(targets.whereType<WifiTarget>(), hasLength(1));
    expect(binder.owners, isEmpty);
  });

  test('hand-over and take-back of a USB camera move no binding', () async {
    final usb = next(UsbTarget);
    await plug(canon);

    expect(cubit.handOver('live'), usb);
    expect(cubit.handedOverTarget, isA<UsbTarget>());
    expect(
      cubit.takeBack(usb, owner: 'live', target: UsbTarget(canon)),
      isTrue,
    );

    expect(cubit.state, ConnectConnected(usb));
    expect((cubit.state as ConnectConnected).target, isA<UsbTarget>());
    expect(cubit.handedOverTarget, isNull);
    expect(binder.calls, isEmpty);
  });
}
