import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/identity_repository.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/data/ssdp_discovery.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connection_supervisor.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/recording_binder.dart'
    show RecordingBinder, cameraGateway, homeGateway, unreachable;
import '../../upload/upload_fakes.dart';

const owner = 'live';

typedef Reconnecting = ({bool unreachable, bool userActionNeeded, bool usb});

/// Records what a [ConnectionSupervisor] reports to its owner.
class SupervisorEvents {
  final connected = <CameraClient>[];
  final reconnected = <bool>[];
  final disconnected = <CameraClient>[];
  final reconnecting = <Reconnecting>[];
  int staleBindings = 0;

  void onConnected(
    CameraClient client,
    ConnectTarget? target, {
    required bool reconnected,
  }) {
    connected.add(client);
    this.reconnected.add(reconnected);
  }

  void onReconnecting({
    required bool unreachable,
    required bool userActionNeeded,
    required bool usb,
  }) => reconnecting.add((
    unreachable: unreachable,
    userActionNeeded: userActionNeeded,
    usb: usb,
  ));
}

const retrying = (unreachable: false, userActionNeeded: false, usb: false);

/// A camera on the home Wi-Fi, found by discovery rather than the gateway.
const stationHost = '192.168.1.50';

/// Another camera that happens to have the same name.
class _OtherCamera extends FakeCameraClient {
  _OtherCamera() : super([]);

  @override
  CameraDeviceInfo get deviceInfo => const CameraDeviceInfo(
    manufacturer: 'Canon Inc.',
    model: 'Canon EOS R',
    deviceVersion: '1-0',
    serialNumber: '2',
    operationsSupported: [],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final old = cameraObject(1, 'IMG_0001.JPG');

  late SharedPreferences prefs;
  late RecordingBinder binder;
  late FakeTimers timers;
  late DateTime now;
  late FakeCameraClient first;
  late List<Object> connections;
  late List<String> hosts;
  late SupervisorEvents events;
  late ClientValidator validate;
  late Completer<void>? connectGate;
  late List<DiscoveredCamera> discovered;
  late int discoveries;
  late ConnectionSupervisor supervisor;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    binder = RecordingBinder();
    timers = FakeTimers();
    now = DateTime(2026, 11, 13, 12);
    first = FakeCameraClient([old]);
    connections = [];
    hosts = [];
    events = SupervisorEvents();
    validate = (_) async => true;
    connectGate = null;
    discovered = [];
    discoveries = 0;
    supervisor = ConnectionSupervisor(
      connector: (target) async {
        hosts.add((target as WifiTarget).host);
        await connectGate?.future;
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
      validate: (client) => validate(client),
      onConnected: events.onConnected,
      onDisconnected: events.disconnected.add,
      onReconnecting: events.onReconnecting,
      releaseStale: () async {
        events.staleBindings++;
        await binder.releaseBinding(owner);
      },
      discovery: () async {
        discoveries++;
        return discovered;
      },
      clock: () => now,
      timerFactory: timers.create,
    );
  });

  tearDown(() => supervisor.stop());

  Future<void> superviseFirst() =>
      supervisor.supervise(first, null, bindingOwner: owner, holdNetwork: true);

  Future<void> superviseAt(String host) async => supervisor.supervise(
    first,
    WifiTarget(host, await IdentityRepository(prefs).identity()),
    bindingOwner: owner,
    holdNetwork: true,
  );

  Future<void> fire() async {
    timers.active!.fire();
    await pumpEventQueue();
  }

  List<Duration> delays() => [for (final timer in timers.all) timer.delay];

  // live_transfer_cubit_test.dart:274
  test('a disconnect reconnects instead of failing', () async {
    connections.add(unreachable);
    await superviseFirst();
    expect(events.connected, [first]);
    expect(events.reconnected, [false]);

    first.simulateDisconnect();
    await pumpEventQueue();

    expect(events.disconnected, [first]);
    expect(events.reconnecting, [retrying]);
    expect(supervisor.client, isNull);
    expect(binder.calls, ['acquire live hold']);
  });

  // live_transfer_cubit_test.dart:289
  test('reconnects on the third attempt', () async {
    final second = FakeCameraClient([old]);
    connections.addAll([unreachable, unreachable, second]);
    await superviseFirst();

    first.simulateDisconnect();
    await pumpEventQueue();
    await fire();
    await fire();
    expect(events.connected, [first]);
    await fire();

    expect(events.connected, [first, second]);
    expect(events.reconnected, [false, true]);
    expect(supervisor.client, second);
    expect(delays(), [
      const Duration(seconds: 2),
      const Duration(seconds: 4),
      const Duration(seconds: 8),
    ]);
  });

  // live_transfer_cubit_test.dart:311
  test('the reconnect delay doubles up to 30 s', () async {
    await superviseFirst();
    binder.gateway = () => PlatformException(code: ConnectCubit.noWifiCode);

    first.simulateDisconnect();
    await pumpEventQueue();
    for (var i = 0; i < 6; i++) {
      await fire();
    }

    expect(delays(), [
      for (final seconds in [2, 4, 8, 16, 30, 30, 30])
        Duration(seconds: seconds),
    ]);
    expect(events.reconnecting.toSet(), {retrying});
  });

  // live_transfer_cubit_test.dart:328
  test('slows down to 60 s after 10 minutes of failures', () async {
    await superviseFirst();
    binder.gateway = () => PlatformException(code: ConnectCubit.noWifiCode);
    first.simulateDisconnect();
    await pumpEventQueue();

    now = now.add(ConnectionSupervisor.unreachableAfter);
    await fire();

    expect(
      timers.active!.delay,
      ConnectionSupervisor.unreachableReconnectDelay,
    );
    expect(events.reconnecting.last, (
      unreachable: true,
      userActionNeeded: false,
      usb: false,
    ));
  });

  // live_transfer_cubit_test.dart:346, rewritten: the camera is retried
  // where it was reached, and only a new gateway means another network.
  test('slows down after the phone joins another Wi-Fi', () async {
    connections.add(unreachable);
    await superviseAt(stationHost);
    binder.gateway = () => homeGateway;
    first.simulateDisconnect();
    await pumpEventQueue();

    await fire();

    expect(hosts.last, stationHost);
    expect(
      timers.active!.delay,
      ConnectionSupervisor.unreachableReconnectDelay,
    );
    expect(events.reconnecting.last.unreachable, isTrue);
  });

  test('retries a camera on the home Wi-Fi at its own address', () async {
    connections.addAll([unreachable, unreachable]);
    await superviseAt(stationHost);
    first.simulateDisconnect();
    await pumpEventQueue();

    await fire();
    await fire();

    expect(hosts, [stationHost, stationHost]);
    expect(events.reconnecting.toSet(), {retrying});
    expect(delays(), [
      const Duration(seconds: 2),
      const Duration(seconds: 4),
      const Duration(seconds: 8),
    ]);
  });

  test(
    'a given gateway binds no second time and escalates on change',
    () async {
      connections.add(unreachable);
      await supervisor.supervise(
        first,
        WifiTarget(stationHost, await IdentityRepository(prefs).identity()),
        bindingOwner: owner,
        gateway: homeGateway,
      );
      expect(binder.calls, isEmpty);
      first.simulateDisconnect();
      await pumpEventQueue();

      await fire();

      expect(hosts, [stationHost]);
      expect(events.reconnecting.last.unreachable, isTrue);
    },
  );

  // live_transfer_cubit_test.dart:360
  test('a lost Wi-Fi binding reconnects', () async {
    connections.add(unreachable);
    await superviseFirst();

    supervisor.bindingLost();
    await pumpEventQueue();

    expect(first.closed, isTrue);
    expect(events.disconnected, [first]);
    expect(events.reconnecting, [retrying]);
  });

  // live_transfer_cubit_test.dart:385
  test('stop while reconnecting cancels the retry', () async {
    connections.add(unreachable);
    await superviseFirst();
    first.simulateDisconnect();
    await pumpEventQueue();
    final retry = timers.active!;

    supervisor.stop();

    expect(timers.active, isNull);
    retry.fire();
    await pumpEventQueue();
    expect(hosts, isEmpty);
    expect(events.reconnecting, [retrying]);
    expect(binder.calls, isNot(contains('release live')));
  });

  // live_transfer_cubit_test.dart:438
  test('a lost binding while validating schedules one reconnect', () async {
    final gate = Completer<void>();
    validate = (_) async {
      await gate.future;
      return true;
    };
    final supervising = superviseFirst();
    await pumpEventQueue();

    supervisor.bindingLost();
    await pumpEventQueue();
    gate.complete();
    await supervising;

    expect(timers.all.where((timer) => timer.isActive), hasLength(1));
    expect(events.connected, isEmpty);
    expect(events.reconnecting, [retrying]);
  });

  // live_transfer_cubit_test.dart:465
  test('stop while reconnecting hands back the late binding', () async {
    connections.add(unreachable);
    await superviseFirst();
    first.simulateDisconnect();
    await pumpEventQueue();
    binder.acquireGate = Completer<void>();
    timers.active!.fire();
    await pumpEventQueue();

    supervisor.stop();
    binder.acquireGate!.complete();
    await pumpEventQueue();

    expect(events.staleBindings, 1);
    expect(binder.owners, isEmpty);
    expect(hosts, isEmpty);
  });

  // live_transfer_cubit_test.dart:481
  test('a lost binding while validating a reconnect retries', () async {
    final second = FakeCameraClient([old]);
    final third = FakeCameraClient([old]);
    connections.addAll([second, third]);
    await superviseFirst();
    first.simulateDisconnect();
    await pumpEventQueue();
    validate = (client) async {
      if (client == second) supervisor.bindingLost();
      return true;
    };

    await fire();

    expect(second.closed, isTrue);
    expect(events.connected, [first]);
    expect(events.reconnecting.last, retrying);
    await fire();
    expect(events.connected, [first, third]);
  });

  // live_transfer_cubit_test.dart:535
  test('stop mid-reconnect leaves no timer and keeps the binding', () async {
    connections.add(unreachable);
    await superviseFirst();
    first.simulateDisconnect();
    await pumpEventQueue();

    supervisor.stop();
    supervisor.bindingLost();
    await pumpEventQueue();

    expect(timers.active, isNull);
    expect(binder.owners, {owner});
    expect(events.reconnecting, [retrying]);
  });

  // live_transfer_cubit_test.dart:556
  test('connects by itself when no client is given', () async {
    connections.add(first);

    await supervisor.supervise(null, null, bindingOwner: owner);

    expect(events.connected, [first]);
    expect(events.reconnected, [true]);
    expect(hosts.last, cameraGateway);
    expect(binder.owners, {owner});
  });

  test(
    'stop during a retry closes the late client and reports nothing',
    () async {
      final second = FakeCameraClient([old]);
      connections.add(second);
      await superviseFirst();
      first.simulateDisconnect();
      await pumpEventQueue();
      connectGate = Completer<void>();
      timers.active!.fire();
      await pumpEventQueue();
      expect(hosts, [cameraGateway]);

      supervisor.stop();
      connectGate!.complete();
      await pumpEventQueue();

      expect(second.closed, isTrue);
      expect(events.connected, [first]);
      expect(events.reconnecting, [retrying]);
      expect(timers.active, isNull);
    },
  );

  group('a camera found by discovery', () {
    const name = 'EOS R';
    const moved = DiscoveredCamera(host: '192.168.1.60', name: name);
    const namesake = DiscoveredCamera(host: '192.168.1.61', name: 'EOS R6');

    Future<void> superviseFound({String? discoveredName = name}) async =>
        supervisor.supervise(
          first,
          WifiTarget(stationHost, await IdentityRepository(prefs).identity()),
          bindingOwner: owner,
          discoveredName: discoveredName,
        );

    Future<void> failTimes(int count) async {
      for (var i = 0; i < count; i++) {
        await fire();
      }
    }

    test('is found again at a new address after three failures', () async {
      final second = FakeCameraClient([old]);
      final third = FakeCameraClient([old]);
      connections.addAll([unreachable, unreachable, unreachable, second]);
      discovered = [namesake, moved];
      await superviseFound();
      first.simulateDisconnect();
      await pumpEventQueue();

      await failTimes(2);
      expect(discoveries, 0);
      await fire();

      expect(discoveries, 1);
      expect(hosts, [stationHost, stationHost, stationHost, moved.host]);
      expect(events.connected, [first, second]);
      expect((supervisor.target! as WifiTarget).host, moved.host);

      connections.add(third);
      second.simulateDisconnect();
      await pumpEventQueue();
      await fire();
      expect(hosts.last, moved.host);
      expect(events.connected.last, third);
    });

    test('ignores another camera under the same name', () async {
      final other = _OtherCamera();
      connections.addAll([unreachable, unreachable, unreachable, other]);
      connections.add(unreachable);
      discovered = [moved];
      await superviseFound();
      first.simulateDisconnect();
      await pumpEventQueue();

      await failTimes(3);
      expect(other.closed, isTrue);
      expect(events.connected, [first]);
      await fire();

      expect(hosts.last, stationHost);
      expect((supervisor.target! as WifiTarget).host, stationHost);
    });

    test('is not looked for when the address was set by hand', () async {
      connections.addAll(List.filled(6, unreachable));
      discovered = [moved];
      await superviseFound(discoveredName: null);
      first.simulateDisconnect();
      await pumpEventQueue();

      await failTimes(6);

      expect(discoveries, 0);
      expect(hosts.toSet(), {stationHost});
    });
  });

  test('stop while connected leaves the client open', () async {
    await superviseFirst();

    supervisor.stop();
    await pumpEventQueue();

    expect(first.closed, isFalse);
    expect(supervisor.client, isNull);
    first.simulateDisconnect();
    await pumpEventQueue();
    expect(events.disconnected, isEmpty);
    expect(events.reconnecting, isEmpty);
    expect(timers.all, isEmpty);
  });

  test('a failed validation closes the client and retries', () async {
    final second = FakeCameraClient([old]);
    connections.add(second);
    validate = (client) async => client != first;

    await superviseFirst();

    expect(first.closed, isTrue);
    expect(events.reconnecting, [retrying]);
    await fire();
    expect(events.connected, [second]);
  });
}
