import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/identity_repository.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connection_supervisor.dart';
import 'package:shutterlink/usb/usb_camera_platform.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_usb_camera_watcher.dart';
import '../../upload/upload_fakes.dart';
import '../live/live_transfer_cubit_test.dart' show RecordingBinder;
import 'connection_supervisor_test.dart' show SupervisorEvents, owner;

const usbRetrying = (unreachable: false, userActionNeeded: false, usb: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final old = cameraObject(1, 'IMG_0001.JPG');
  final canon = usbCamera();
  final other = usbCamera(productId: 0x3299, name: 'Canon EOS RP');

  late RecordingBinder binder;
  late FakeTimers timers;
  late FakeUsbCameraWatcher watcher;
  late Map<Type, List<Object>> connections;
  late List<ConnectTarget> targets;
  late SupervisorEvents events;
  late ConnectionSupervisor supervisor;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    binder = RecordingBinder();
    timers = FakeTimers();
    watcher = FakeUsbCameraWatcher()..permitted.add(canon);
    connections = {WifiTarget: [], UsbTarget: []};
    targets = [];
    events = SupervisorEvents();
    supervisor = ConnectionSupervisor(
      connector: (target) async {
        targets.add(target);
        final next = connections[target.runtimeType]!.removeAt(0);
        if (next is Exception) throw next;
        return next as FakeCameraClient;
      },
      identity: IdentityRepository(prefs),
      hostResolver: CameraHostResolver(
        SettingsRepository(prefs),
        wifiGateway: () async => null,
      ),
      networkBinder: binder,
      usbWatcher: watcher,
      onConnected: events.onConnected,
      onDisconnected: events.disconnected.add,
      onReconnecting: events.onReconnecting,
      releaseStale: () async => events.staleBindings++,
      timerFactory: timers.create,
    );
  });

  tearDown(() => supervisor.stop());

  Future<FakeCameraClient> superviseUsb() async {
    final client = FakeCameraClient([old]);
    await supervisor.supervise(client, UsbTarget(canon), bindingOwner: owner);
    expect(events.connected, [client]);
    return client;
  }

  Future<FakeCameraClient> superviseWifi() async {
    final client = FakeCameraClient([old]);
    await supervisor.supervise(client, null, bindingOwner: owner);
    expect(events.connected, [client]);
    return client;
  }

  /// The owner forwards the watcher's events, as Live does.
  Future<void> plug(UsbCameraRef device) async {
    watcher.attach(device);
    supervisor.usbAttached(device);
    await pumpEventQueue();
  }

  Future<void> unplug(FakeCameraClient client) async {
    client.simulateDisconnect();
    watcher.detach(canon);
    supervisor.usbDetached(canon);
    await pumpEventQueue();
  }

  Future<void> fire() async {
    timers.active!.fire();
    await pumpEventQueue();
  }

  // live_transfer_cubit_usb_test.dart:161, the "never binds" half
  test('a USB camera never binds, not even to reconnect', () async {
    final client = await superviseUsb();
    connections[UsbTarget]!.add(FakeCameraClient([old]));

    client.simulateDisconnect();
    await pumpEventQueue();
    await fire();

    expect(events.connected, hasLength(2));
    expect(binder.calls, isEmpty);
  });

  // live_transfer_cubit_usb_test.dart:173
  test('a lost Wi-Fi binding does not touch a USB camera', () async {
    final client = await superviseUsb();

    supervisor.bindingLost();
    await pumpEventQueue();

    expect(client.closed, isFalse);
    expect(events.reconnecting, isEmpty);
  });

  // live_transfer_cubit_usb_test.dart:183
  test('unplugging reconnects, and waits while the camera is away', () async {
    final client = await superviseUsb();

    await unplug(client);
    expect(events.reconnecting, [usbRetrying]);
    await fire();

    expect(events.reconnecting.toSet(), {usbRetrying});
    expect(watcher.permissionRequests, isEmpty);
    expect(targets, isEmpty);
  });

  // live_transfer_cubit_usb_test.dart:195
  test('a re-plug with permission reconnects at once', () async {
    final client = await superviseUsb();
    await unplug(client);
    final second = FakeCameraClient([old]);
    connections[UsbTarget]!.add(second);
    watcher.permitted.add(canon);

    await plug(canon);

    expect(events.connected, [client, second]);
    expect(events.reconnected, [false, true]);
    expect(binder.calls, isEmpty);
  });

  // live_transfer_cubit_usb_test.dart:210
  test('a re-plug without permission asks the user, then resumes', () async {
    final client = await superviseUsb();
    await unplug(client);
    watcher.permissionAnswers.add(UsbPermission.userActionNeeded);

    await plug(canon);

    expect(events.reconnecting.last, (
      unreachable: false,
      userActionNeeded: true,
      usb: true,
    ));
    await fire();
    expect(watcher.permissionRequests, [canon], reason: 'asked once');
    expect(timers.active!.delay, ConnectionSupervisor.initialReconnectDelay);

    final second = FakeCameraClient([old]);
    connections[UsbTarget]!.add(second);
    watcher.permitted.add(canon);
    await fire();

    expect(events.connected, [client, second]);
    expect(watcher.permissionRequests, [canon]);
  });

  // live_transfer_cubit_usb_test.dart:236
  test('allowing USB access asks again and connects', () async {
    final client = await superviseUsb();
    await unplug(client);
    watcher.permissionAnswers.addAll([
      UsbPermission.userActionNeeded,
      UsbPermission.granted,
    ]);
    await plug(canon);
    await fire();
    expect(watcher.permissionRequests, [canon]);

    final second = FakeCameraClient([old]);
    connections[UsbTarget]!.add(second);
    supervisor.allowUsbAccess();
    await pumpEventQueue();

    expect(watcher.permissionRequests, [canon, canon]);
    expect(events.connected, [client, second]);
  });

  // live_transfer_cubit_usb_test.dart:255
  test('allowing USB access does nothing over Wi-Fi', () async {
    await superviseWifi();

    supervisor.allowUsbAccess();
    await pumpEventQueue();

    expect(watcher.permissionRequests, isEmpty);
    expect(targets, isEmpty);
  });

  // live_transfer_cubit_usb_test.dart:265; the owner takes over
  test('a takeover supervises the USB camera instead of Wi-Fi', () async {
    final wifi = await superviseWifi();
    final usb = FakeCameraClient([old]);
    connections[UsbTarget]!.add(usb);

    supervisor.stop();
    await supervisor.supervise(null, UsbTarget(canon), bindingOwner: owner);

    expect(wifi.closed, isFalse, reason: 'the owner closes it');
    expect(events.connected, [wifi, usb]);
    expect(targets.single, isA<UsbTarget>());
    expect(supervisor.target, isA<UsbTarget>());

    supervisor.bindingLost();
    await pumpEventQueue();
    expect(usb.closed, isFalse, reason: 'Wi-Fi no longer matters');
  });

  test('a Wi-Fi retry that binds after a takeover releases it', () async {
    final wifi = await superviseWifi();
    wifi.simulateDisconnect();
    await pumpEventQueue();
    binder.acquireGate = Completer<void>();
    timers.active!.fire();
    await pumpEventQueue();

    connections[UsbTarget]!.add(FakeCameraClient([old]));
    supervisor.stop();
    await supervisor.supervise(null, UsbTarget(canon), bindingOwner: owner);
    await binder.releaseBinding(owner);
    binder.acquireGate!.complete();
    await pumpEventQueue();

    expect(binder.owners, isEmpty);
    expect(events.staleBindings, 0);
    expect(targets.whereType<WifiTarget>(), isEmpty);
  });

  // live_transfer_cubit_usb_test.dart:291
  test('another USB camera does not retry the supervised one', () async {
    final client = await superviseUsb();
    await unplug(client);
    final retry = timers.active;

    await plug(other);

    expect(timers.active, retry);
    expect(targets, isEmpty);
  });

  // live_transfer_cubit_usb_test.dart:303
  test('a USB camera during Wi-Fi changes nothing by itself', () async {
    final wifi = await superviseWifi();

    await plug(canon);

    expect(wifi.closed, isFalse);
    expect(supervisor.client, wifi);
    expect(targets, isEmpty);
  });

  test('an unplugged camera backs off until it is plugged in again', () async {
    final client = await superviseUsb();
    await unplug(client);
    await fire();
    await fire();
    expect(delays(timers), [
      const Duration(seconds: 2),
      const Duration(seconds: 4),
      const Duration(seconds: 8),
    ]);

    final second = FakeCameraClient([old]);
    connections[UsbTarget]!.add(second);
    watcher.permitted.add(canon);
    await plug(canon);

    expect(events.connected, [client, second]);
    expect(timers.active, isNull);
  });
}

List<Duration> delays(FakeTimers timers) => [
  for (final timer in timers.all) timer.delay,
];
