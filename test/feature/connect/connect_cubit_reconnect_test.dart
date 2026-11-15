import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/identity_repository.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/data/ssdp_discovery.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connect_state.dart';
import 'package:shutterlink/feature/connect/connection_supervisor.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_usb_camera_watcher.dart';
import '../../fakes/recording_binder.dart'
    show RecordingBinder, cameraGateway, homeGateway, unreachable;
import '../../upload/upload_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const station = DiscoveredCamera(host: '192.168.1.50', name: 'EOS R');
  const other = DiscoveredCamera(host: '192.168.1.51', name: 'EOS R6');
  final canon = usbCamera();

  late SharedPreferences prefs;
  late RecordingBinder binder;
  late FakeTimers timers;
  late FakeUsbCameraWatcher watcher;
  late List<Object> wifiAnswers;
  late List<Object> usbAnswers;
  late List<String> hosts;
  late Completer<void>? connectGate;
  late List<DiscoveredCamera> discovered;
  late int discoveries;
  late ConnectCubit cubit;
  late List<ConnectState> states;

  Future<FakeCameraClient> answer(List<Object> answers) async {
    final next = answers.removeAt(0);
    if (next is Exception) throw next;
    return next as FakeCameraClient;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    binder = RecordingBinder();
    timers = FakeTimers();
    watcher = FakeUsbCameraWatcher()..permitted.add(canon);
    wifiAnswers = [];
    usbAnswers = [];
    hosts = [];
    connectGate = null;
    discovered = [];
    discoveries = 0;
    cubit = ConnectCubit(
      connector: (target) async {
        if (target is UsbTarget) return answer(usbAnswers);
        hosts.add((target as WifiTarget).host);
        final gate = connectGate;
        connectGate = null;
        await gate?.future;
        return answer(wifiAnswers);
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
        return discovered;
      },
      timerFactory: timers.create,
    );
    states = [];
    cubit.stream.listen(states.add);
  });

  tearDown(() => cubit.close());

  Future<FakeCameraClient> connectWifi() async {
    final client = FakeCameraClient([]);
    wifiAnswers.add(client);
    await cubit.connect();
    expect(cubit.state, ConnectConnected(client));
    return client;
  }

  /// Connects to [camera], found by discovery because the gateway refused.
  Future<FakeCameraClient> connectStation(DiscoveredCamera camera) async {
    discovered = [camera, other];
    final client = FakeCameraClient([]);
    wifiAnswers.addAll([unreachable, client]);
    await cubit.connect();
    expect(cubit.state, const ConnectChooseCamera([station, other]));
    await cubit.chooseCamera(camera);
    expect(cubit.state, ConnectConnected(client));
    return client;
  }

  Future<void> drop(FakeCameraClient client) async {
    client.simulateDisconnect();
    await pumpEventQueue();
  }

  Future<void> fire() async {
    timers.active!.fire();
    await pumpEventQueue();
  }

  test('a drop reconnects with a new client', () async {
    final first = await connectWifi();
    final second = FakeCameraClient([]);
    wifiAnswers.addAll([unreachable, second]);

    await drop(first);
    expect(cubit.state, const ConnectReconnecting());
    await fire();
    expect(cubit.state, const ConnectReconnecting());
    await fire();

    expect(cubit.state, ConnectConnected(second));
    expect((cubit.state as ConnectConnected).target, isA<WifiTarget>());
    expect(hosts, [cameraGateway, cameraGateway, cameraGateway]);
    expect(binder.owners, {ConnectCubit.bindingOwner});
  });

  test('a drop of the reconnected client reconnects again', () async {
    final first = await connectWifi();
    final second = FakeCameraClient([]);
    wifiAnswers.add(second);
    await drop(first);
    await fire();
    expect(cubit.state, ConnectConnected(second));

    await drop(second);

    expect(cubit.state, const ConnectReconnecting());
  });

  test('abort goes idle and releases the binding', () async {
    final first = await connectWifi();
    await drop(first);

    await cubit.abortReconnect();

    expect(cubit.state, const ConnectIdle());
    expect(binder.owners, isEmpty);
    expect(timers.active, isNull);
  });

  test('abort does nothing once the camera is back', () async {
    final first = await connectWifi();
    final second = FakeCameraClient([]);
    wifiAnswers.add(second);
    await drop(first);
    await fire();

    await cubit.abortReconnect();

    expect(cubit.state, ConnectConnected(second));
    expect(second.closed, isFalse);
  });

  test('abort while a retry binds leaves no binding behind', () async {
    final first = await connectWifi();
    wifiAnswers.add(FakeCameraClient([]));
    await drop(first);
    binder.acquireGate = Completer<void>();
    timers.active!.fire();
    await pumpEventQueue();

    await cubit.abortReconnect();
    binder.acquireGate!.complete();
    await pumpEventQueue();

    expect(cubit.state, const ConnectIdle());
    expect(binder.owners, isEmpty);
    expect(hosts, [cameraGateway]);
  });

  test('a Wi-Fi tap during a retry wins and closes the late client', () async {
    final first = await connectWifi();
    await drop(first);
    final gate = connectGate = Completer<void>();
    timers.active!.fire();
    await pumpEventQueue();
    expect(hosts, [cameraGateway, cameraGateway]);

    final tapped = FakeCameraClient([]);
    final late = FakeCameraClient([]);
    wifiAnswers.addAll([tapped, late]);
    await cubit.connect();
    gate.complete();
    await pumpEventQueue();

    expect(late.closed, isTrue);
    expect(cubit.state, ConnectConnected(tapped));
    expect(states.whereType<ConnectConnected>().last.client, tapped);
    expect(timers.active, isNull);
  });

  test('disconnect goes idle and starts no retry', () async {
    final client = await connectWifi();
    await pumpEventQueue();
    states.clear();

    await cubit.disconnect();
    await pumpEventQueue();

    expect(states, [const ConnectIdle()]);
    expect(client.closed, isTrue);
    expect(timers.all, isEmpty);
    expect(hosts, [cameraGateway]);
    expect(binder.owners, isEmpty);
  });

  test('close closes the client and starts no retry', () async {
    final client = await connectWifi();

    await cubit.close();
    await pumpEventQueue();

    expect(client.closed, isTrue);
    expect(timers.all, isEmpty);
    expect(hosts, [cameraGateway]);
  });

  test('close while reconnecting ends the retry quietly', () async {
    final first = await connectWifi();
    final late = FakeCameraClient([]);
    wifiAnswers.add(late);
    await drop(first);
    final gate = connectGate = Completer<void>();
    timers.active!.fire();
    await pumpEventQueue();

    await cubit.close();
    gate.complete();
    await pumpEventQueue();

    expect(late.closed, isTrue);
    expect(timers.active, isNull);
  });

  group('a camera found by discovery', () {
    test('is retried at its own address', () async {
      final first = await connectStation(station);
      wifiAnswers.addAll([unreachable, FakeCameraClient([])]);

      await drop(first);
      await fire();
      await fire();

      expect(hosts.skip(2), [station.host, station.host]);
      expect(cubit.state, isA<ConnectConnected>());
    });

    test('escalates once the phone joins another Wi-Fi', () async {
      final first = await connectStation(station);
      wifiAnswers.add(unreachable);
      binder.gateway = () => homeGateway;

      await drop(first);
      await fire();

      expect(cubit.state, const ConnectReconnecting(unreachable: true));
      expect(
        timers.active!.delay,
        ConnectionSupervisor.unreachableReconnectDelay,
      );
    });

    test('is found again after it moved to another address', () async {
      final first = await connectStation(station);
      final second = FakeCameraClient([]);
      wifiAnswers.addAll([unreachable, unreachable, unreachable, second]);
      discovered = [
        const DiscoveredCamera(host: '192.168.1.60', name: 'EOS R'),
      ];

      await drop(first);
      for (var i = 0; i < ConnectionSupervisor.rediscoverAfter; i++) {
        await fire();
      }

      expect(cubit.state, ConnectConnected(second));
      expect(hosts.last, '192.168.1.60');
      expect(
        (cubit.state as ConnectConnected).target,
        isA<WifiTarget>().having((t) => t.host, 'host', '192.168.1.60'),
      );
    });

    test('does not escalate on the same Wi-Fi', () async {
      final first = await connectStation(station);
      wifiAnswers.add(unreachable);

      await drop(first);
      await fire();

      expect(cubit.state, const ConnectReconnecting());
    });
  });

  test('a camera at the gateway is never looked for', () async {
    final first = await connectWifi();
    wifiAnswers.addAll(List.filled(4, unreachable));
    discovered = [station];

    await drop(first);
    for (var i = 0; i < 4; i++) {
      await fire();
    }

    expect(discoveries, 0);
    expect(hosts.toSet(), {cameraGateway});
  });

  group('holding the Wi-Fi', () {
    test('re-acquires the connect binding with a hold', () async {
      await connectWifi();

      await cubit.setHoldNetwork(true);

      expect(binder.calls.last, 'acquire connect hold');
      expect(binder.owners, {ConnectCubit.bindingOwner});
    });

    test('keeps holding on every retry', () async {
      final first = await connectWifi();
      await cubit.setHoldNetwork(true);
      wifiAnswers.add(FakeCameraClient([]));

      await drop(first);
      await fire();

      expect(binder.calls.last, 'acquire connect hold');
    });

    test('a lost held Wi-Fi reconnects', () async {
      final first = await connectWifi();
      await cubit.setHoldNetwork(true);

      binder.lost.add(null);
      await pumpEventQueue();

      expect(first.closed, isTrue);
      expect(cubit.state, const ConnectReconnecting());
    });

    test('leaves no binding after an abort', () async {
      final first = await connectWifi();
      await cubit.setHoldNetwork(true);
      await drop(first);

      await cubit.abortReconnect();

      expect(binder.owners, isEmpty);
    });

    test('leaves no binding after a USB takeover', () async {
      await connectWifi();
      await cubit.setHoldNetwork(true);
      usbAnswers.add(FakeCameraClient([]));

      watcher.attach(canon);
      await pumpEventQueue();

      expect(cubit.state, isA<ConnectConnected>());
      expect(binder.owners, isEmpty);
    });

    test('binds nothing for a USB camera', () async {
      usbAnswers.add(FakeCameraClient([]));
      watcher.attach(canon);
      await pumpEventQueue();

      await cubit.setHoldNetwork(true);

      expect(binder.calls, isEmpty);
    });
  });
}
