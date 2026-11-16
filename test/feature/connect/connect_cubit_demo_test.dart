import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/identity_repository.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/demo/demo_camera_client.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connect_state.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_usb_camera_watcher.dart';
import '../../fakes/recording_binder.dart' show RecordingBinder;
import '../../upload/upload_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late List<File> photos;
  late SharedPreferences prefs;
  late RecordingBinder binder;
  late FakeUsbCameraWatcher watcher;
  late List<ConnectTarget> targets;
  late FakeCameraClient other;
  late int discoveries;
  late FakeTimers timers;
  late ConnectCubit cubit;
  Exception? demoFailure;
  Completer<CameraClient>? demoGate;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('shutterlink_demo');
    photos = [
      File(p.join(directory.path, 'IMG_0001.JPG'))..writeAsBytesSync([1, 2]),
    ];
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    binder = RecordingBinder();
    watcher = FakeUsbCameraWatcher()..permitted.add(usbCamera());
    targets = [];
    other = FakeCameraClient([]);
    discoveries = 0;
    timers = FakeTimers();
    demoFailure = null;
    demoGate = null;
    cubit = ConnectCubit(
      connector: (target) async {
        targets.add(target);
        if (target is! DemoTarget) return other;
        final failure = demoFailure;
        if (failure != null) throw failure;
        final gate = demoGate;
        if (gate != null) return gate.future;
        return DemoCameraClient.open(target.photos);
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

  tearDown(() async {
    await cubit.close();
    directory.deleteSync(recursive: true);
  });

  Future<CameraClient> connectDemo() async {
    await cubit.connectDemo(photos);
    final state = cubit.state as ConnectConnected;
    expect(state.target, isA<DemoTarget>());
    return state.client;
  }

  test('opens the picked photos without network or identity', () async {
    final client = await connectDemo();

    expect(client, isA<DemoCameraClient>());
    expect((targets.single as DemoTarget).photos, photos);
    expect((await client.listPhotos()).single.filename, 'IMG_0001.JPG');
    expect(binder.calls, isEmpty);
    expect(discoveries, 0);
    expect(prefs.getKeys(), isEmpty, reason: 'no pairing identity is made');
  });

  test('holding the network and disconnecting leave the binding', () async {
    final client = await connectDemo();

    await cubit.setHoldNetwork(true);
    await cubit.disconnect();
    await pumpEventQueue();

    expect(cubit.state, const ConnectIdle());
    await expectLater(client.disconnected, completes);
    expect(binder.calls, isEmpty);
    expect(timers.all, isEmpty, reason: 'nothing reconnects');
  });

  test('a USB camera takes over without unbinding', () async {
    await connectDemo();

    watcher.attach(usbCamera());
    await pumpEventQueue();

    expect(cubit.state, ConnectConnected(other));
    expect(targets.last, isA<UsbTarget>());
    expect(binder.calls, isEmpty);
  });

  test('a camera on the cable without a takeover leaves the demo', () async {
    final demo = await connectDemo();

    watcher.attach(usbCamera(), enumerated: true);
    await pumpEventQueue();

    expect(cubit.state, ConnectConnected(demo));
    expect(targets.single, isA<DemoTarget>());
    expect(binder.calls, isEmpty);
  });

  test('a demo that Connect overtook is closed when it opens', () async {
    final gate = demoGate = Completer();
    final late = FakeCameraClient([]);
    final states = <ConnectState>[];
    cubit.stream.listen(states.add);

    final opening = cubit.connectDemo(photos);
    await cubit.connect();
    gate.complete(late);
    await opening;

    expect(cubit.state, ConnectConnected(other));
    expect(late.closed, isTrue);
    expect(states.whereType<ConnectConnected>(), [ConnectConnected(other)]);
  });

  test('Connect leaves the demo for the Wi-Fi camera', () async {
    final demo = await connectDemo();

    await cubit.connect();

    expect(cubit.state, ConnectConnected(other));
    await expectLater(demo.disconnected, completes);
    expect(binder.calls, ['acquire connect']);
  });

  test('is ignored while a camera is connected', () async {
    await cubit.connect();

    await cubit.connectDemo(photos);

    expect(cubit.state, ConnectConnected(other));
    expect(targets.whereType<DemoTarget>(), isEmpty);
  });

  test('says when the photos cannot be opened', () async {
    demoFailure = const FileSystemException('gone');

    await cubit.connectDemo(photos);

    expect(cubit.state, isA<ConnectFailed>());
    expect(binder.calls, isEmpty);
  });
}
