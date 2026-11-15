import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/identity_repository.dart';
import 'package:shutterlink/data/live_service.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connect_state.dart';
import 'package:shutterlink/feature/live/ingest_coordinator.dart';
import 'package:shutterlink/feature/live/live_ingestor.dart';
import 'package:shutterlink/feature/live/live_transfer_cubit.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/upload_queue.dart';
import 'package:shutterlink/usb/usb_camera_platform.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_usb_camera_watcher.dart';
import '../../upload/upload_fakes.dart';
import 'live_transfer_cubit_test.dart' show FakeLiveService, RecordingBinder;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const destination = Destination(
    type: DestinationType.webdav,
    endpoint: 'https://a.example.com/dav',
  );
  final date = DateTime(2026, 11, 13, 10);
  final old = cameraObject(1, 'IMG_0001.JPG', captureDate: date);
  final missed = cameraObject(3, 'IMG_0003.JPG', captureDate: date);
  final canon = usbCamera();
  final phone = usbCamera(vendorId: otherUsbVendor, name: 'iPhone');

  late Directory root;
  late FakeStorageServer server;
  late UploadQueue queue;
  late FakeLiveService service;
  late RecordingBinder binder;
  late FakeTimers timers;
  late FakeUsbCameraWatcher watcher;
  late Map<Type, List<Object>> connections;
  late List<ConnectTarget> targets;
  late ConnectCubit connect;
  late LiveTransferCubit live;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    root = await Directory.systemTemp.createTemp('live_usb');
    server = FakeStorageServer();
    queue = UploadQueue(
      repository: UploadQueueRepository.inDirectory(root),
      stagingDirectory: Directory(p.join(root.path, 'staging')),
      mediaSaver: FakeMediaSaver(),
      backendFactory: (_, {required allowMetered}) async => server.backend(),
      destination: destination,
    );
    await queue.start();
    final history = DownloadHistoryRepository(
      File(p.join(root.path, DownloadHistoryRepository.fileName)),
    );
    service = FakeLiveService();
    binder = RecordingBinder();
    timers = FakeTimers();
    watcher = FakeUsbCameraWatcher()..permitted.addAll([canon, phone]);
    connections = {WifiTarget: [], UsbTarget: []};
    targets = [];
    Future<FakeCameraClient> connector(ConnectTarget target) async {
      targets.add(target);
      final next = connections[target.runtimeType]!.removeAt(0);
      if (next is Exception) throw next;
      return next as FakeCameraClient;
    }

    final identity = IdentityRepository(prefs);
    CameraHostResolver resolver() => CameraHostResolver(
      SettingsRepository(prefs),
      wifiGateway: () async => null,
    );
    connect = ConnectCubit(
      connector: connector,
      identity: identity,
      hostResolver: resolver(),
      networkBinder: binder,
      claimsUsbVendor: claimsCanonOnly,
      usbWatcher: watcher,
    );
    final coordinator = IngestCoordinator();
    live = LiveTransferCubit(
      connect: connect,
      connector: connector,
      identity: identity,
      hostResolver: resolver(),
      networkBinder: binder,
      service: service,
      queue: queue,
      claimsUsbVendor: claimsCanonOnly,
      usbWatcher: watcher,
      ingestorFactory: (client, baseline) => LiveIngestor(
        client: client,
        format: DownloadFormat.jpeg,
        baseline: baseline,
        history: history,
        queue: queue,
        coordinator: coordinator,
        infoRetryDelay: Duration.zero,
        rescanInterval: const Duration(days: 1),
      ),
      timerFactory: timers.create,
    );
  });

  tearDown(() async {
    await live.close();
    await connect.close();
    await pumpEventQueue();
    await queue.idle;
    await queue.close();
    await service.stopController.close();
    await root.delete(recursive: true);
  });

  Future<void> plug(UsbCameraRef device) async {
    watcher.attach(device);
    await pumpEventQueue();
  }

  Future<FakeCameraClient> startOverUsb() async {
    final client = FakeCameraClient([old]);
    connections[UsbTarget]!.add(client);
    await plug(canon);
    expect(connect.state, ConnectConnected(client));
    await live.start();
    expect(live.state, const LiveTransferring());
    return client;
  }

  Future<FakeCameraClient> startOverWifi() async {
    final client = FakeCameraClient([old]);
    connections[WifiTarget]!.add(client);
    await connect.connect();
    await live.start();
    expect(live.state, const LiveTransferring());
    return client;
  }

  Future<void> unplug(FakeCameraClient client) async {
    client.simulateDisconnect();
    watcher.detach(canon);
    await pumpEventQueue();
  }

  Future<void> fire() async {
    timers.active!.fire();
    await pumpEventQueue();
  }

  test('USB Live never binds and gives the camera back on stop', () async {
    final client = await startOverUsb();
    expect(watcher.calls, ['start connection', 'start live']);

    await live.stop();

    expect(watcher.calls, ['start connection', 'start live', 'stop live']);
    expect(connect.state, ConnectConnected(client));
    expect((connect.state as ConnectConnected).target, isA<UsbTarget>());
    expect(binder.calls, isEmpty);
  });

  test('a lost Wi-Fi binding does not touch a USB camera', () async {
    final client = await startOverUsb();

    binder.lost.add(null);
    await pumpEventQueue();

    expect(client.closed, isFalse);
    expect(live.state, const LiveTransferring());
  });

  test('unplugging reconnects, and waits while the camera is away', () async {
    final client = await startOverUsb();

    await unplug(client);
    expect(live.state, const LiveReconnecting());
    await fire();

    expect(live.state, const LiveReconnecting());
    expect(watcher.permissionRequests, isEmpty);
    expect(targets, hasLength(1));
  });

  test('a re-plug with permission reconnects at once and catches up', () async {
    final client = await startOverUsb();
    await unplug(client);
    final second = FakeCameraClient([old, missed]);
    connections[UsbTarget]!.add(second);
    watcher.permitted.add(canon);

    await plug(canon);

    expect(live.state, isA<LiveTransferring>());
    await until(() => server.files.isNotEmpty);
    expect(server.files.keys, ['2026-11-13/IMG_0003.JPG']);
    expect(binder.calls, isEmpty);
  });

  test('a re-plug without permission asks the user, then resumes', () async {
    final client = await startOverUsb();
    await unplug(client);
    watcher.permissionAnswers.add(UsbPermission.userActionNeeded);

    await plug(canon);

    expect(live.state, const LiveReconnecting(userActionNeeded: true));
    expect(service.statuses.last.state, LiveServiceState.reconnecting);
    expect(
      service.statuses.last.text,
      startsWith(LiveTransferCubit.userActionText),
    );
    await fire();
    expect(watcher.permissionRequests, [canon], reason: 'asked once');
    expect(timers.active!.delay, LiveTransferCubit.initialReconnectDelay);

    final second = FakeCameraClient([old]);
    connections[UsbTarget]!.add(second);
    watcher.permitted.add(canon);
    await fire();

    expect(live.state, const LiveTransferring());
    expect(watcher.permissionRequests, [canon]);
  });

  test('allowing USB access asks again and connects', () async {
    final client = await startOverUsb();
    await unplug(client);
    watcher.permissionAnswers.addAll([
      UsbPermission.userActionNeeded,
      UsbPermission.granted,
    ]);
    await plug(canon);
    await fire();
    expect(watcher.permissionRequests, [canon]);

    connections[UsbTarget]!.add(FakeCameraClient([old]));
    live.allowUsbAccess();
    await pumpEventQueue();

    expect(watcher.permissionRequests, [canon, canon]);
    expect(live.state, const LiveTransferring());
  });

  test('allowing USB access does nothing over Wi-Fi', () async {
    await startOverWifi();

    live.allowUsbAccess();
    await pumpEventQueue();

    expect(watcher.permissionRequests, isEmpty);
    expect(live.state, const LiveTransferring());
  });

  test('a Canon cable during Wi-Fi Live switches to USB', () async {
    final wifi = await startOverWifi();
    final usb = FakeCameraClient([old]);
    connections[UsbTarget]!.add(usb);

    await plug(canon);

    expect(wifi.closed, isTrue);
    expect(binder.calls, contains('release live'));
    expect(binder.owners, isEmpty);
    expect(live.state, const LiveTransferring());
    expect(targets.last, isA<UsbTarget>());

    binder.lost.add(null);
    await pumpEventQueue();
    expect(usb.closed, isFalse, reason: 'Wi-Fi no longer matters');

    await live.stop();
    expect(connect.state, ConnectConnected(usb));
    expect((connect.state as ConnectConnected).target, isA<UsbTarget>());

    final calls = [...binder.calls];
    expect(connect.handOver('live'), usb);
    expect(binder.calls, calls, reason: 'no transferBinding for USB');
  });

  test('an unknown vendor during Wi-Fi Live changes nothing', () async {
    final wifi = await startOverWifi();
    final calls = [...binder.calls];

    await plug(phone);

    expect(wifi.closed, isFalse);
    expect(live.state, const LiveTransferring());
    expect(binder.calls, calls);
    expect(targets.whereType<UsbTarget>(), isEmpty);
  });

  test(
    'an already plugged-in camera during Wi-Fi Live changes nothing',
    () async {
      final wifi = await startOverWifi();

      watcher.attach(canon, enumerated: true);
      await pumpEventQueue();

      expect(wifi.closed, isFalse);
      expect(targets.whereType<UsbTarget>(), isEmpty);
    },
  );
}
