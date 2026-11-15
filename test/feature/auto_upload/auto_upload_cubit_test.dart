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
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/auto_upload/auto_upload_cubit.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connect_state.dart';
import 'package:shutterlink/feature/live/ingest_coordinator.dart';
import 'package:shutterlink/feature/live/live_ingestor.dart';
import 'package:shutterlink/feature/mode/mode_cubit.dart';
import 'package:shutterlink/feature/mode/operating_mode.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/upload_queue.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_live_service.dart';
import '../../fakes/recording_binder.dart';
import '../../upload/upload_fakes.dart';

class _GatedClient extends FakeCameraClient {
  _GatedClient(super.objects);

  Completer<void>? listGate;
  int failingLists = 0;
  int listCalls = 0;

  @override
  Future<List<CameraObject>> listPhotos() async {
    listCalls++;
    await listGate?.future;
    if (failingLists > 0) {
      failingLists--;
      throw const PtpResponseException(0x1008, 0x2019);
    }
    return super.listPhotos();
  }
}

/// Waits in real time, since ingest writes files.
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(condition(), isTrue, reason: 'condition never became true');
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
  late FakeStorageServer server;
  late UploadQueue queue;
  late DownloadHistoryRepository history;
  late FakeLiveService service;
  late RecordingBinder binder;
  late FakeTimers timers;
  late _GatedClient first;
  late List<Object> connections;
  late ConnectCubit connect;
  late ModeCubit modes;
  late AutoUploadCubit cubit;
  late SharedPreferences prefs;

  final cameraKey = cameraKeyOf(FakeCameraClient(const []).deviceInfo);
  String keyOf(CameraObject object) =>
      DownloadHistoryRepository.entryKey(cameraKey, object);

  AutoUploadCubit build(LiveService liveService) => AutoUploadCubit(
    connect: connect,
    modes: modes,
    service: liveService,
    queue: queue,
    format: () => DownloadFormat.jpeg,
    ingestorFactory: (client, baseline) => LiveIngestor(
      client: client,
      format: DownloadFormat.jpeg,
      baseline: baseline,
      history: history,
      queue: queue,
      coordinator: IngestCoordinator(),
      infoRetryDelay: Duration.zero,
      rescanInterval: const Duration(days: 1),
    ),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    root = await Directory.systemTemp.createTemp('auto_upload');
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
    first = _GatedClient([old]);
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
    cubit = build(service);
  });

  tearDown(() async {
    await cubit.close();
    await modes.close();
    await connect.close();
    await pumpEventQueue();
    await queue.idle;
    await queue.close();
    await service.stopController.close();
    await root.delete(recursive: true);
  });

  Future<void> enter() async {
    modes.select(OperatingMode.autoUpload);
    await _until(() => cubit.state.phase == AutoUploadPhase.running);
  }

  Future<void> shoot(FakeCameraClient client, CameraObject object) async {
    client
      ..objects.add(object)
      ..emitAdded(object.handle);
    await _until(() => cubit.state.recent.any((r) => r.object == object));
    await queue.idle;
  }

  /// Uploads [object] as if an earlier run had sent it.
  Future<void> uploadedBefore(CameraObject object) async {
    final file = File(p.join(root.path, 'before', object.filename));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(contentFor(object));
    await queue.add(
      id: keyOf(object),
      file: file,
      filename: object.filename,
      kind: object.kind,
      captureDate: object.captureDate,
    );
    await queue.idle;
  }

  Future<void> fire() async {
    timers.active!.fire();
    await pumpEventQueue();
  }

  test(
    'uploads new shots, with the service running and the Wi-Fi held',
    () async {
      await enter();

      await shoot(first, shot);

      expect(server.files.keys, ['2026-11-13/IMG_0002.JPG']);
      expect(cubit.state.detected, 1);
      expect(cubit.state.uploaded, 1);
      expect(cubit.state.recent, [RecentShot(shot, first)]);
      expect(service.calls.first, 'start');
      expect(service.statuses.last.title, AutoUploadCubit.title);
      expect(binder.calls, contains('acquire connect hold'));
    },
  );

  test('the backlog counts photos not uploaded, downloaded or not, and Yes '
      'uploads exactly those', () async {
    final done = cameraObject(4, 'IMG_0004.JPG', captureDate: date);
    final raw = cameraObject(5, 'IMG_0005.CR3', captureDate: date);
    first.objects.addAll([done, raw, missed]);
    await history.record(cameraKey, [old]);
    await uploadedBefore(done);
    final before = Set.of(server.files.keys);

    await enter();
    expect(cubit.state.backlog, 2);

    cubit.uploadBacklog(upload: true);
    await _until(() => server.files.length == before.length + 2);
    await queue.idle;

    expect(cubit.state.backlog, isNull);
    expect(server.files.keys.toSet().difference(before), {
      '2026-11-13/IMG_0001.JPG',
      '2026-11-13/IMG_0003.JPG',
    });
    expect(first.requestedOffsets.keys, unorderedEquals([1, 3]));
  });

  test('No uploads only what is shot from now on', () async {
    await enter();
    expect(cubit.state.backlog, 1);

    await shoot(first, shot);
    cubit.uploadBacklog(upload: false);
    await pumpEventQueue();
    await queue.idle;

    expect(cubit.state.backlog, isNull);
    expect(server.files.keys, ['2026-11-13/IMG_0002.JPG']);
    expect(first.requestedOffsets.keys, [shot.handle]);
  });

  test('a card with nothing left to upload asks nothing', () async {
    await uploadedBefore(old);

    await enter();

    expect(cubit.state.backlog, isNull);
  });

  test('a reconnect keeps the counters and the card, and catches up', () async {
    final second = FakeCameraClient([old, shot, missed]);
    connections.add(second);
    await enter();
    await shoot(first, shot);

    first.simulateDisconnect();
    await pumpEventQueue();
    expect(connect.state, isA<ConnectReconnecting>());
    expect(service.statuses.last.state, LiveServiceState.reconnecting);
    await fire();
    await _until(() => cubit.state.detected == 2);
    await queue.idle;

    expect(server.files.keys.toSet(), {
      '2026-11-13/IMG_0002.JPG',
      '2026-11-13/IMG_0003.JPG',
    });
    expect(second.requestedOffsets.keys, [missed.handle]);
    expect(cubit.state.recent, [
      RecentShot(missed, second),
      RecentShot(shot, first),
    ]);
    expect(service.statuses.last.state, LiveServiceState.transferring);
  });

  test(
    'a failed card read closes the client, and the camera reconnects',
    () async {
      first.failingLists = 1;
      final second = FakeCameraClient([old]);
      connections.add(second);

      modes.select(OperatingMode.autoUpload);
      await _until(() => connect.state is ConnectReconnecting);
      expect(first.closed, isTrue);
      expect(cubit.state.phase, AutoUploadPhase.starting);
      await fire();
      await _until(() => cubit.state.phase == AutoUploadPhase.running);

      await shoot(second, shot);
      expect(server.files.keys, ['2026-11-13/IMG_0002.JPG']);
    },
  );

  test(
    'entered while reconnecting, it starts once the camera is back',
    () async {
      final second = FakeCameraClient([old]);
      connections.addAll([unreachable, second]);
      first.simulateDisconnect();
      await pumpEventQueue();

      modes.select(OperatingMode.autoUpload);
      await pumpEventQueue();
      expect(cubit.state.phase, AutoUploadPhase.starting);
      await fire();
      await fire();
      await _until(() => cubit.state.phase == AutoUploadPhase.running);

      await shoot(second, shot);
      expect(first.requestedOffsets, isEmpty);
    },
  );

  test('the notification Stop goes back to the picker with the camera '
      'connected, and ends the mode', () async {
    await enter();

    service.stopController.add(null);
    await pumpEventQueue();

    expect(modes.state, isNull);
    expect(connect.state, ConnectConnected(first));
    expect(first.closed, isFalse);
    expect(cubit.state, const AutoUploadState());
    expect(service.calls.last, 'stop');

    first
      ..objects.add(shot)
      ..emitAdded(shot.handle);
    await pumpEventQueue();
    await queue.idle;
    expect(server.files, isEmpty);
  });

  test(
    'a camera that drops after leaving reconnects without the hold',
    () async {
      connections.add(FakeCameraClient([old]));
      await enter();
      modes.leave();
      await pumpEventQueue();
      binder.calls.clear();

      first.simulateDisconnect();
      await pumpEventQueue();
      await fire();

      expect(binder.calls, ['acquire connect']);
    },
  );

  test('leaving while the card is read starts nothing', () async {
    first.listGate = Completer<void>();
    modes.select(OperatingMode.autoUpload);
    await _until(() => first.listCalls > 0);

    modes.leave();
    await pumpEventQueue();
    first.listGate!.complete();
    await pumpEventQueue();

    expect(cubit.state, const AutoUploadState());
    first
      ..objects.add(shot)
      ..emitAdded(shot.handle);
    await pumpEventQueue();
    expect(first.requestedOffsets, isEmpty);
    expect(service.calls.last, 'stop');
  });

  test('a stop request outside the mode still stops the service', () async {
    service.stopController.add(null);
    await pumpEventQueue();

    expect(service.calls, ['stop']);
    expect(modes.state, isNull);
  });

  test("another mode's stop request is left to that mode", () async {
    modes.select(OperatingMode.qrSession);
    await pumpEventQueue();

    service.stopController.add(null);
    await pumpEventQueue();

    expect(service.calls, isEmpty);
    expect(modes.state, OperatingMode.qrSession);
  });

  test('runs without notifications and says so', () async {
    service.permitted = false;

    await enter();

    expect(cubit.state.notificationsDenied, isTrue);
  });

  test('an iPhone stays awake while the mode is open', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = PlatformLiveService.idleTimerChannel;
    final disabled = <Object?>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      disabled.add(call.arguments);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await cubit.close();
    cubit = build(PlatformLiveService(isAndroid: false, isIOS: true));

    await enter();
    expect(disabled, [true]);
    modes.leave();
    await pumpEventQueue();

    expect(disabled, [true, false]);
  });

  test('an iPhone without the screen channel still uploads', () async {
    await cubit.close();
    cubit = build(PlatformLiveService(isAndroid: false, isIOS: true));

    await enter();
    await shoot(first, shot);

    expect(server.files.keys, ['2026-11-13/IMG_0002.JPG']);
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
    await cubit.close();
    cubit = build(PlatformLiveService(isAndroid: true));
    connections.add(unreachable);

    await enter();
    cubit.uploadBacklog(upload: false);
    await shoot(first, shot);
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
      'title': AutoUploadCubit.title,
      'count': count,
      'uploaded': uploaded,
      'pending': pending,
      'state': state.name,
      'text': text,
    };
    const running = LiveServiceState.transferring;
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
        running,
        'Waiting for new photos · 0 new photos · 0 uploaded · 0 waiting',
      ),
      payload(
        0,
        0,
        1,
        running,
        'Waiting for new photos · 0 new photos · 0 uploaded · 1 waiting',
      ),
      payload(
        1,
        0,
        1,
        running,
        'Waiting for new photos · 1 new photo · 0 uploaded · 1 waiting',
      ),
      payload(
        1,
        1,
        0,
        running,
        'Waiting for new photos · 1 new photo · 1 uploaded · 0 waiting',
      ),
      payload(
        1,
        1,
        0,
        LiveServiceState.reconnecting,
        'Reconnecting to the camera · 1 new photo · 1 uploaded · 0 waiting',
      ),
    ]);
    expect(modes.state, isNull);
  });
}
