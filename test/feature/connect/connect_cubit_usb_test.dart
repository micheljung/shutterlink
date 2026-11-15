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

  test('USB takes over a connected Wi-Fi camera', () async {
    final wifi = await connectWifi();
    final usb = next(UsbTarget);

    await plug(canon);

    expect(wifi.closed, isTrue);
    expect(cubit.state, ConnectConnected(usb));
    expect(binder.owners, isEmpty);
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
    'a Wi-Fi tap while USB closes the old Wi-Fi client keeps its binding',
    () async {
      final slow = _SlowClosingClient();
      answers[WifiTarget]!.add(slow);
      await cubit.connect();
      expect(cubit.state, ConnectConnected(slow));

      await plug(canon);
      expect(
        cubit.state,
        const ConnectConnecting(cameraName: 'Canon EOS R', usb: true),
      );
      final wifi = await connectWifi();
      slow.closing.complete();
      await pumpEventQueue();

      expect(cubit.state, ConnectConnected(wifi));
      expect(binder.owners, {'connect'});
      expect(binder.calls.last, 'acquire connect');
      expect(targets.whereType<UsbTarget>(), isEmpty);
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

    test('while Live owns the camera', () async {
      await connectWifi();
      cubit.handOver('live');

      await plug(canon);

      expect(cubit.state, const ConnectLiveOwned());
      expect(targets.whereType<UsbTarget>(), isEmpty);
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

  test('unplug fails the connection, and a re-plug connects again', () async {
    final first = next(UsbTarget);
    await plug(canon);

    first.simulateDisconnect();
    watcher.detach(canon);
    await pumpEventQueue();
    expect(cubit.state, const ConnectFailed(ConnectCubit.disconnectedMessage));

    watcher.permitted.add(canon);
    final second = next(UsbTarget);
    await plug(canon);
    expect(cubit.state, ConnectConnected(second));
    expect(binder.calls, isEmpty);
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
