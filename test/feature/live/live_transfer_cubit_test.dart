import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/identity_repository.dart';
import 'package:shutterlink/data/live_service.dart';
import 'package:shutterlink/data/network_binder.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connect_state.dart';
import 'package:shutterlink/feature/live/ingest_coordinator.dart';
import 'package:shutterlink/feature/live/live_ingestor.dart';
import 'package:shutterlink/feature/live/live_transfer_cubit.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/upload_queue.dart';

import '../../fakes/fake_camera_client.dart';
import '../../upload/upload_fakes.dart';

const cameraGateway = '192.168.1.2';
const homeGateway = '10.0.0.1';
const unreachable = CameraDisconnectedException(
  SocketException('Connection refused'),
);

class GatedCameraClient extends FakeCameraClient {
  GatedCameraClient(super.objects);

  Completer<void>? listGate;
  int listCalls = 0;

  @override
  Future<List<CameraObject>> listPhotos() async {
    listCalls++;
    await listGate?.future;
    if (closed) throw const CameraDisconnectedException();
    return super.listPhotos();
  }
}

class FailingCloseClient extends FakeCameraClient {
  FailingCloseClient(super.objects);

  @override
  Future<void> close() async {
    await super.close();
    throw const SocketException('close failed');
  }
}

class FakeLiveService implements LiveService {
  final calls = <String>[];
  final statuses = <LiveStatus>[];
  final stopController = StreamController<void>.broadcast();
  bool permitted = true;

  @override
  Future<void> start(LiveStatus status) async {
    calls.add('start');
    statuses.add(status);
  }

  @override
  Future<void> updateStatus(LiveStatus status) async {
    calls.add('update');
    statuses.add(status);
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<bool> requestNotificationPermission() async => permitted;

  @override
  Stream<void> get stopRequests => stopController.stream;
}

class RecordingBinder implements NetworkBinder {
  final calls = <String>[];
  final owners = <String>{};
  final lost = StreamController<void>.broadcast();
  Object? Function() gateway = () => cameraGateway;
  Completer<void>? acquireGate;

  @override
  Future<String?> acquireBinding(
    String owner, {
    bool holdNetwork = false,
  }) async {
    calls.add('acquire $owner${holdNetwork ? ' hold' : ''}');
    await acquireGate?.future;
    final result = gateway();
    if (result is Exception) throw result;
    owners.add(owner);
    return result as String?;
  }

  @override
  Future<void> releaseBinding(String owner) async {
    calls.add('release $owner');
    owners.remove(owner);
  }

  @override
  void transferBinding(String from, String to) {
    calls.add('transfer $from>$to');
    if (owners.remove(from)) owners.add(to);
  }

  @override
  Stream<void> get bindingLost => lost.stream;

  @override
  Future<void> acquireMulticastLock() async {}

  @override
  Future<void> releaseMulticastLock() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const destination = Destination(
    type: DestinationType.webdav,
    endpoint: 'https://a.example.com/dav',
  );
  final date = DateTime(2026, 11, 13, 10);
  final old = cameraObject(1, 'IMG_0001.JPG', captureDate: date);
  final shot = cameraObject(2, 'IMG_0002.JPG', captureDate: date);
  final missed = cameraObject(3, 'IMG_0003.JPG', captureDate: date);

  late Directory root;
  late SharedPreferences prefs;
  late FakeStorageServer server;
  late UploadQueue queue;
  late DownloadHistoryRepository history;
  late FakeLiveService service;
  late RecordingBinder binder;
  late FakeTimers timers;
  late DateTime now;
  late GatedCameraClient first;
  late List<Object> connections;
  late List<String> hosts;
  late ConnectCubit connect;
  late List<ConnectState> connectStates;
  late LiveTransferCubit live;
  late List<LiveTransferState> liveStates;
  late IdentityRepository identity;
  late CameraConnector connector;
  void Function(CameraClient client)? onIngestor;

  CameraHostResolver resolver() => CameraHostResolver(
    SettingsRepository(prefs),
    wifiGateway: () async => null,
  );

  LiveTransferCubit buildLive(LiveService liveService) {
    final coordinator = IngestCoordinator();
    return LiveTransferCubit(
      connect: connect,
      connector: connector,
      identity: identity,
      hostResolver: resolver(),
      networkBinder: binder,
      service: liveService,
      queue: queue,
      ingestorFactory: (client, baseline) {
        onIngestor?.call(client);
        return LiveIngestor(
          client: client,
          format: DownloadFormat.jpeg,
          baseline: baseline,
          history: history,
          queue: queue,
          coordinator: coordinator,
          infoRetryDelay: Duration.zero,
          rescanInterval: const Duration(days: 1),
        );
      },
      clock: () => now,
      timerFactory: timers.create,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    root = await Directory.systemTemp.createTemp('live_transfer');
    server = FakeStorageServer();
    queue = UploadQueue(
      repository: UploadQueueRepository.inDirectory(root),
      stagingDirectory: Directory(p.join(root.path, 'staging')),
      mediaSaver: FakeMediaSaver(),
      backendFactory: (_, {required allowMetered}) async => server.backend(),
      destination: destination,
    );
    await queue.start();
    history = DownloadHistoryRepository(
      File(p.join(root.path, DownloadHistoryRepository.fileName)),
    );
    service = FakeLiveService();
    binder = RecordingBinder();
    timers = FakeTimers();
    now = DateTime(2026, 11, 13, 12);
    first = GatedCameraClient([old]);
    connections = [first];
    hosts = [];
    onIngestor = null;
    identity = IdentityRepository(prefs);
    connector = (String host, CameraIdentity _) async {
      hosts.add(host);
      final next = connections.removeAt(0);
      if (next is Exception) throw next;
      return next as CameraClient;
    };

    connect = ConnectCubit(
      connector: connector,
      identity: identity,
      hostResolver: resolver(),
      networkBinder: binder,
    );
    connectStates = [];
    connect.stream.listen(connectStates.add);
    await connect.connect();
    live = buildLive(service);
    liveStates = [];
    live.stream.listen(liveStates.add);
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

  Future<void> fire() async {
    timers.active!.fire();
    await pumpEventQueue();
  }

  List<Duration> delays() => [for (final timer in timers.all) timer.delay];

  test('takes over the connected camera and uploads new shots', () async {
    await live.start();

    expect(connect.state, const ConnectLiveOwned());
    expect(live.state, const LiveTransferring());
    expect(binder.calls, [
      'acquire connect',
      'transfer connect>live',
      'acquire live hold',
    ]);

    first.objects.add(shot);
    first.emitAdded(shot.handle);
    await until(() => server.files.isNotEmpty && live.state.ingested == 1);

    expect(server.files.keys, ['2026-11-13/IMG_0002.JPG']);
  });

  test('a disconnect reconnects instead of failing', () async {
    connections.add(unreachable);
    await live.start();

    first.simulateDisconnect();
    await pumpEventQueue();

    expect(live.state, const LiveReconnecting());
    expect(service.calls, isNot(contains('stop')));
    expect(connectStates.whereType<ConnectFailed>(), isEmpty);
    expect(connect.state, const ConnectLiveOwned());
    expect(binder.calls, isNot(contains('release live')));
    expect(service.statuses.last.state, LiveServiceState.reconnecting);
  });

  test('reconnects on the third attempt and catches up', () async {
    final second = FakeCameraClient([old, missed]);
    connections.addAll([unreachable, unreachable, second]);
    await live.start();

    first.simulateDisconnect();
    await pumpEventQueue();
    await fire();
    await fire();
    expect(live.state, isA<LiveReconnecting>());
    await fire();

    expect(live.state, isA<LiveTransferring>());
    expect(delays(), [
      const Duration(seconds: 2),
      const Duration(seconds: 4),
      const Duration(seconds: 8),
    ]);
    await until(() => server.files.isNotEmpty && live.state.ingested == 1);
    expect(server.files.keys, ['2026-11-13/IMG_0003.JPG']);
  });

  test('the reconnect delay doubles up to 30 s', () async {
    await live.start();
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
    expect(live.state, const LiveReconnecting());
  });

  test('slows down to 60 s after 10 minutes of failures', () async {
    await live.start();
    binder.gateway = () => PlatformException(code: ConnectCubit.noWifiCode);
    first.simulateDisconnect();
    await pumpEventQueue();

    now = now.add(LiveTransferCubit.unreachableAfter);
    await fire();

    expect(timers.active!.delay, LiveTransferCubit.unreachableReconnectDelay);
    expect(live.state, const LiveReconnecting(unreachable: true));
    expect(
      service.statuses.last.text,
      'Camera not reachable · 0 new photos · 0 uploaded · 0 waiting',
    );
    expect(service.statuses.last.state, LiveServiceState.unreachable);
  });

  test('slows down on a Wi-Fi without the camera', () async {
    connections.add(unreachable);
    await live.start();
    binder.gateway = () => homeGateway;
    first.simulateDisconnect();
    await pumpEventQueue();

    await fire();

    expect(hosts.last, homeGateway);
    expect(timers.active!.delay, LiveTransferCubit.unreachableReconnectDelay);
    expect(live.state, const LiveReconnecting(unreachable: true));
  });

  test('a lost Wi-Fi binding reconnects', () async {
    connections.add(unreachable);
    await live.start();

    binder.lost.add(null);
    await pumpEventQueue();

    expect(first.closed, isTrue);
    expect(live.state, const LiveReconnecting());
  });

  test('stop with the camera connected hands it back still bound', () async {
    await live.start();

    service.stopController.add(null);
    await pumpEventQueue();

    expect(live.state, const LiveIdle());
    expect(connect.state, ConnectConnected(first));
    expect(first.closed, isFalse);
    expect(service.calls.last, 'stop');
    expect(binder.calls, isNot(contains('release live')));
    expect(binder.owners, {ConnectCubit.bindingOwner});
  });

  test('stop while reconnecting releases the binding', () async {
    connections.add(unreachable);
    await live.start();
    first.simulateDisconnect();
    await pumpEventQueue();

    await live.stop();

    expect(connect.state, const ConnectIdle());
    expect(binder.calls.last, 'release live');
    expect(binder.owners, isEmpty);
    expect(timers.active, isNull);
  });

  test('a second stop during teardown still hands the camera back', () async {
    await live.start();
    first
      ..chunkGate = Completer<void>()
      ..objects.add(shot)
      ..emitAdded(shot.handle);
    await until(() => first.requestedOffsets.isNotEmpty);

    final stopping = live.stop();
    final again = live.stop();
    first.chunkGate!.complete();
    first.chunkGate = null;
    await Future.wait([stopping, again]);

    expect(connect.state, ConnectConnected(first));
    expect(first.closed, isFalse);
    expect(binder.owners, {ConnectCubit.bindingOwner});
  });

  test('a stop request while idle still stops the service', () async {
    service.stopController.add(null);
    await pumpEventQueue();

    expect(service.calls, ['stop']);
  });

  test('stop while reading the card hands the camera back open', () async {
    first.listGate = Completer<void>();
    final starting = live.start();
    await until(() => first.listCalls > 0);

    await live.stop();
    first.listGate!.complete();
    await starting;

    expect(connect.state, ConnectConnected(first));
    expect(first.closed, isFalse);
  });

  test('a lost binding while starting schedules one reconnect', () async {
    first.listGate = Completer<void>();
    final starting = live.start();
    await until(() => first.listCalls > 0);

    binder.lost.add(null);
    await pumpEventQueue();
    first.listGate!.complete();
    await starting;

    expect(timers.all.where((timer) => timer.isActive), hasLength(1));
    expect(live.state, const LiveReconnecting());
  });

  test('stop while binding drops the late live binding', () async {
    binder.acquireGate = Completer<void>();
    final starting = live.start();
    await until(() => binder.calls.contains('acquire live hold'));

    await live.stop();
    binder.acquireGate!.complete();
    await starting;

    expect(connect.state, ConnectConnected(first));
    expect(binder.owners, {ConnectCubit.bindingOwner});
  });

  test('stop while reconnecting drops the late live binding', () async {
    connections.add(unreachable);
    await live.start();
    first.simulateDisconnect();
    await pumpEventQueue();
    binder.acquireGate = Completer<void>();
    timers.active!.fire();
    await pumpEventQueue();

    await live.stop();
    binder.acquireGate!.complete();
    await pumpEventQueue();

    expect(binder.owners, isEmpty);
  });

  test('a lost binding while attaching a reconnect retries', () async {
    final second = FakeCameraClient([old]);
    connections.addAll([
      second,
      FakeCameraClient([old]),
    ]);
    await live.start();
    first.simulateDisconnect();
    await pumpEventQueue();
    onIngestor = (client) {
      if (client == second) binder.lost.add(null);
    };

    await fire();

    expect(second.closed, isTrue);
    expect(live.state, isA<LiveReconnecting>());
    await fire();
    expect(live.state, isA<LiveTransferring>());
  });

  test('a renumbered new shot after a reconnect is ingested', () async {
    final renumbered = cameraObject(7, 'IMG_0001.JPG', captureDate: date);
    final moved = cameraObject(old.handle, 'IMG_0002.JPG', captureDate: date);
    final second = FakeCameraClient([renumbered]);
    connections.add(second);
    await live.start();
    first.simulateDisconnect();
    await pumpEventQueue();
    await fire();
    await pumpEventQueue();

    second
      ..objects.add(moved)
      ..emitAdded(moved.handle);
    await until(() => server.files.isNotEmpty);

    expect(server.files.keys, ['2026-11-13/IMG_0002.JPG']);
  });

  test('a camera that fails to close still releases on stop', () async {
    await connect.disconnect();
    connections.add(FailingCloseClient([old]));
    await live.start();

    final stopping = live.stop();
    final restarting = live.start();
    await stopping;
    connections.add(FakeCameraClient([old]));
    await restarting;

    expect(live.state, isA<LiveTransferring>());
  });

  test('closing mid-reconnect releases the binding', () async {
    connections.add(unreachable);
    await live.start();
    first.simulateDisconnect();
    await pumpEventQueue();

    await live.close();

    expect(binder.owners, isEmpty);
    expect(timers.active, isNull);
    expect(service.calls.last, 'stop');
  });

  test('runs without notifications and says so', () async {
    service.permitted = false;

    await live.start();

    expect(live.state, const LiveTransferring(notificationsDenied: true));
  });

  test('connects by itself when no camera is connected', () async {
    await connect.disconnect();
    connections.add(FakeCameraClient([old]));

    await live.start();

    expect(live.state, isA<LiveTransferring>());
    expect(hosts.last, cameraGateway);
    expect(binder.owners, {LiveTransferCubit.bindingOwner});
  });

  test('AC4: the notification follows ingest, upload and reconnect', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = PlatformLiveService.channel;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'requestNotificationPermission' ? true : null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      channel.setMethodCallHandler(null);
    });
    final channelLive = buildLive(PlatformLiveService(isAndroid: true));
    connections.add(unreachable);

    await channelLive.start();
    first.objects.add(shot);
    first.emitAdded(shot.handle);
    await until(() => server.files.isNotEmpty);
    await queue.idle;
    await pumpEventQueue();
    first.simulateDisconnect();
    await pumpEventQueue();
    final reply = Completer<void>();
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        const MethodCall(PlatformLiveService.stopRequestedMethod),
      ),
      (_) => reply.complete(),
    );
    await reply.future;
    await pumpEventQueue();

    Map<String, Object> payload(
      int count,
      int uploaded,
      int pending,
      LiveServiceState state,
      String text,
    ) => {
      'count': count,
      'uploaded': uploaded,
      'pending': pending,
      'state': state.name,
      'text': text,
    };
    const transferring = LiveServiceState.transferring;
    expect(calls.map((call) => call.method), [
      'requestNotificationPermission',
      'start',
      ...List.filled(5, 'updateStatus'),
      'stop',
    ]);
    expect(calls.skip(1).take(6).map((call) => call.arguments), [
      payload(
        0,
        0,
        0,
        LiveServiceState.connecting,
        'Connecting to the camera · 0 new photos · 0 uploaded · 0 waiting',
      ),
      payload(
        0,
        0,
        0,
        transferring,
        'Live transfer · 0 new photos · 0 uploaded · 0 waiting',
      ),
      payload(
        0,
        0,
        1,
        transferring,
        'Live transfer · 0 new photos · 0 uploaded · 1 waiting',
      ),
      payload(
        1,
        0,
        1,
        transferring,
        'Live transfer · 1 new photo · 0 uploaded · 1 waiting',
      ),
      payload(
        1,
        1,
        0,
        transferring,
        'Live transfer · 1 new photo · 1 uploaded · 0 waiting',
      ),
      payload(
        1,
        1,
        0,
        LiveServiceState.reconnecting,
        'Reconnecting to the camera · 1 new photo · 1 uploaded · 0 waiting',
      ),
    ]);
    expect(channelLive.state, const LiveIdle());
    await channelLive.close();
  });
}
