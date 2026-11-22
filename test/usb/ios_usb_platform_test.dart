import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/camera_connector.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/identity_repository.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connect_state.dart';
import 'package:shutterlink/ptp/camera_client.dart';
import 'package:shutterlink/ptp/ptp_camera_client.dart';
import 'package:shutterlink/usb/ios_usb_platform.dart';
import 'package:shutterlink/usb/usb_camera_client.dart';
import 'package:shutterlink/usb/usb_camera_platform.dart';
import 'package:shutterlink/usb/usb_container.dart';
import 'package:shutterlink/usb/usb_pipe.dart';

import '../fakes/fake_ptp_device.dart';
import '../fakes/fake_usb_camera_watcher.dart' show claimsCanonOnly;
import '../fakes/recording_binder.dart' show RecordingBinder;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const uuid = '6F1C2E2A-0000-4000-8000-000000000001';
  const camera = {
    'deviceName': uuid,
    'vendorId': 0x04A9,
    'productId': 0x32D2,
    'product': 'Canon EOS R',
    'hasPermission': false,
  };
  const cameraRef = UsbCameraRef(
    platformId: uuid,
    vendorId: 0x04A9,
    productId: 0x32D2,
    name: 'Canon EOS R',
  );

  late List<MethodCall> calls;
  late Map<String, Object? Function(MethodCall call)> answers;
  MockStreamHandlerEventSink? sink;
  late IosUsbPlatform platform;

  Future<void> emit(Map<String, Object?> event) async {
    sink!.success(event);
    await pumpEventQueue();
  }

  List<String> methods() => [for (final call in calls) call.method];

  Never fail(String code) => throw PlatformException(code: code);

  setUp(() {
    calls = [];
    sink = null;
    answers = {'requestPermission': (_) => true};
    messenger.setMockMethodCallHandler(IosUsbPlatform.channel, (call) async {
      calls.add(call);
      return answers[call.method]?.call(call);
    });
    messenger.setMockStreamHandler(
      IosUsbPlatform.events,
      MockStreamHandler.inline(
        onListen: (arguments, events) => sink = events,
        onCancel: (_) => sink = null,
      ),
    );
    platform = IosUsbPlatform();
  });

  tearDown(() async {
    await platform.dispose();
    messenger.setMockMethodCallHandler(IosUsbPlatform.channel, null);
    messenger.setMockStreamHandler(IosUsbPlatform.events, null);
  });

  /// Starts the watcher and attaches [camera].
  Future<IosUsbCameraWatcher> attach({String owner = 'connect'}) async {
    final watcher = platform.watcher..start(owner);
    await pumpEventQueue();
    await emit({'type': 'attached', 'device': camera});
    return watcher;
  }

  Future<IosUsbPassthrough> openPassthrough() async {
    final link = await platform.open(cameraRef);
    return (link as PassthroughLink).passthrough as IosUsbPassthrough;
  }

  group('UsbCameraRef', () {
    UsbCameraRef ref(String id, int vendorId, int productId) => UsbCameraRef(
      platformId: id,
      vendorId: vendorId,
      productId: productId,
      name: 'camera',
    );

    test('with USB ids, equals on vendor and product', () {
      expect(ref('a', 1, 2), ref('b', 1, 2));
      expect(ref('a', 1, 2).hashCode, ref('b', 1, 2).hashCode);
      expect(ref('a', 1, 2), isNot(ref('a', 1, 3)));
      expect(ref('a', 0, 2), ref('b', 0, 2));
    });

    test('without USB ids, equals on the platform id', () {
      expect(ref('a', 0, 0), isNot(ref('b', 0, 0)));
      expect(ref('a', 0, 0), ref('a', 0, 0));
      expect(ref('a', 0, 0).hashCode, ref('a', 0, 0).hashCode);
      expect(ref('a', 0, 0), isNot(ref('a', 1, 2)));
      expect(ref('a', 1, 2), isNot(ref('a', 0, 0)));
    });

    test('a hidden-id camera opens under its own id', () async {
      platform.watcher.start('connect');
      await pumpEventQueue();
      for (final id in ['first', 'second']) {
        await emit({
          'type': 'attached',
          'device': {
            ...camera,
            'deviceName': id,
            'vendorId': 0,
            'productId': 0,
          },
        });
      }
      await platform.open(ref('second', 0, 0));

      expect(calls.last.arguments, {'deviceName': 'second'});
    });
  });

  group('IosUsbCameraWatcher', () {
    test('browses while any owner holds it', () async {
      final watcher = platform.watcher;
      watcher
        ..start('connect')
        ..start('live');
      await pumpEventQueue();
      expect(methods(), ['start']);

      watcher
        ..stop('connect')
        ..stop('unknown');
      await pumpEventQueue();
      expect(methods(), ['start']);

      watcher.stop('live');
      await pumpEventQueue();
      expect(methods(), ['start', 'stop']);
    });

    test('reports attached cameras once, and their detach', () async {
      final watcher = platform.watcher;
      final attached = <UsbCameraRef>[];
      final detached = <UsbCameraRef>[];
      watcher.attached.listen((a) => attached.add(a.device));
      watcher.detached.listen(detached.add);
      await attach();
      await emit({'type': 'attached', 'device': camera});

      expect(attached, [cameraRef]);
      expect(attached.single.platformId, uuid);
      expect(attached.single.name, 'Canon EOS R');

      await emit({'type': 'detached', 'deviceName': uuid});
      await emit({'type': 'detached', 'deviceName': uuid});
      expect(detached, [cameraRef]);
    });

    test('marks cameras plugged in before browsing as enumerated', () async {
      final attached = <UsbAttachment>[];
      platform.watcher.attached.listen(attached.add);
      platform.watcher.start('connect');
      await pumpEventQueue();
      await emit({'type': 'attached', 'device': camera, 'enumerated': true});
      await emit({
        'type': 'attached',
        'device': {...camera, 'deviceName': 'second', 'productId': 1},
      });

      expect(attached.map((a) => a.enumerated), [true, false]);
    });

    test('is experimental', () {
      expect(platform.isExperimental, isTrue);
    });

    test('names a camera without a product name', () async {
      final attached = <UsbCameraRef>[];
      platform.watcher.attached.listen((a) => attached.add(a.device));
      platform.watcher.start('connect');
      await pumpEventQueue();
      await emit({
        'type': 'attached',
        'device': {...camera, 'product': null},
      });

      expect(attached.single.name, 'USB camera');
    });

    test('reports cameras again after browsing restarts', () async {
      final attached = <UsbCameraRef>[];
      platform.watcher.attached.listen((a) => attached.add(a.device));
      await attach();
      platform.watcher.stop('connect');
      await attach();

      expect(attached, [cameraRef, cameraRef]);
    });

    test('keeps the open camera when browsing stops', () async {
      final attached = <UsbCameraRef>[];
      final detached = <UsbCameraRef>[];
      platform.watcher.attached.listen((a) => attached.add(a.device));
      platform.watcher.detached.listen(detached.add);
      await attach();
      final passthrough = await openPassthrough();
      platform.watcher.stop('connect');
      await attach();

      expect(attached, [cameraRef]);
      await emit({'type': 'detached', 'deviceName': uuid});
      expect(detached, [cameraRef]);
      await passthrough.detached;
    });

    test('a failed start or stop is ignored', () async {
      answers['start'] = (_) => fail('busy');
      answers['stop'] = (_) => fail('busy');
      platform.watcher
        ..start('connect')
        ..stop('connect');
      await pumpEventQueue();

      expect(methods(), ['start', 'stop']);
    });

    test('permission is asked once for the app', () async {
      final watcher = await attach();
      expect(watcher.hasPermission(cameraRef), isFalse);

      expect(await watcher.requestPermission(cameraRef), UsbPermission.granted);
      expect(await watcher.requestPermission(cameraRef), UsbPermission.granted);
      expect(methods().where((m) => m == 'requestPermission'), hasLength(1));
      expect(watcher.hasPermission(cameraRef), isTrue);

      await emit({'type': 'detached', 'deviceName': uuid});
      expect(watcher.hasPermission(cameraRef), isFalse);
    });

    test('permission held at attach needs no request', () async {
      platform.watcher.start('connect');
      await pumpEventQueue();
      await emit({
        'type': 'attached',
        'device': {...camera, 'hasPermission': true},
      });

      expect(platform.watcher.hasPermission(cameraRef), isTrue);
      expect(
        await platform.watcher.requestPermission(cameraRef),
        UsbPermission.granted,
      );
      expect(methods(), ['start']);
    });

    test('a refused or failed request is denied', () async {
      final watcher = await attach();
      answers['requestPermission'] = (_) => false;
      expect(await watcher.requestPermission(cameraRef), UsbPermission.denied);

      answers['requestPermission'] = (_) => null;
      expect(await watcher.requestPermission(cameraRef), UsbPermission.denied);

      answers['requestPermission'] = (_) => fail('denied');
      expect(await watcher.requestPermission(cameraRef), UsbPermission.denied);
      expect(watcher.hasPermission(cameraRef), isFalse);
    });

    test('listening to attach subscribes to the bridge', () async {
      platform.watcher.attached.listen((_) {});
      platform.watcher.detached.listen((_) {});
      await pumpEventQueue();

      expect(sink, isNotNull);
    });
  });

  group('IosUsbPlatform', () {
    test('opens the camera under its current id', () async {
      await attach();
      const replugged = UsbCameraRef(
        platformId: 'stale',
        vendorId: 0x04A9,
        productId: 0x32D2,
        name: 'EOS R',
      );
      final link = await platform.open(replugged);

      expect(link, isA<PassthroughLink>());
      expect(calls.last.method, 'open');
      expect(calls.last.arguments, {'deviceName': uuid});
    });

    test('opens an unknown camera under its own id', () async {
      await platform.open(cameraRef);

      expect(calls.last.arguments, {'deviceName': uuid});
    });

    test('an open that never answers times out and closes', () async {
      answers['open'] = (_) => Completer<Object?>().future;
      final platform = IosUsbPlatform(
        openTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(platform.dispose);

      await expectLater(
        platform.open(cameraRef),
        throwsA(
          isA<UsbTransferException>().having(
            (e) => e.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
      expect(methods(), ['open', 'close']);
    });

    test('a timed-out open survives a failing close', () async {
      answers['open'] = (_) => Completer<Object?>().future;
      answers['close'] = (_) => fail('not_open');
      final platform = IosUsbPlatform(openTimeout: Duration.zero);
      addTearDown(platform.dispose);

      await expectLater(
        platform.open(cameraRef),
        throwsA(isA<UsbTransferException>()),
      );
    });

    test('waits 30 s for the open by default', () {
      expect(platform.openTimeout, const Duration(seconds: 30));
    });

    test('a failed open throws UsbTransferException', () async {
      answers['open'] = (_) => fail('no_device');

      await expectLater(
        platform.open(cameraRef),
        throwsA(
          isA<UsbTransferException>().having(
            (e) => e.message,
            'message',
            contains('no_device'),
          ),
        ),
      );
    });

    test('opening another session ends the previous one', () async {
      final first = await openPassthrough();
      final second = await openPassthrough();

      await first.detached;
      await first.close();
      expect(methods(), ['open', 'open']);
      await second.close();
      expect(methods(), ['open', 'open', 'close']);
    });

    test('ignores unknown events', () async {
      await attach();
      await emit({'type': 'unknown'});
      await emit({'type': 'closed', 'deviceName': 'other'});
      await emit({
        'type': 'interrupt',
        'bytes': Uint8List.fromList([1]),
      });
    });
  });

  group('IosUsbPassthrough', () {
    test('sends the command and returns both buffers', () async {
      answers['send'] = (_) => {
        'data': Uint8List.fromList([1, 2]),
        'response': Uint8List.fromList([3, 4]),
      };
      final passthrough = await openPassthrough();
      final command = Uint8List.fromList([9, 9]);
      final result = await passthrough.send(command);

      expect(calls.last.method, 'send');
      expect(calls.last.arguments, {'bytes': command});
      expect(result.data, [1, 2]);
      expect(result.response, [3, 4]);
    });

    test('sends a data-out phase along with the command', () async {
      answers['send'] = (_) => {
        'data': Uint8List(0),
        'response': Uint8List.fromList([3, 4]),
      };
      final passthrough = await openPassthrough();
      final command = Uint8List.fromList([9, 9]);
      final dataOut = Uint8List.fromList([5, 6, 7]);
      await passthrough.send(command, dataOut: dataOut);

      expect(calls.last.arguments, {'bytes': command, 'dataOut': dataOut});
    });

    test('a failed send throws UsbTransferException', () async {
      answers['send'] = (_) => fail('send_failed');
      final passthrough = await openPassthrough();

      await expectLater(
        passthrough.send(Uint8List(12)),
        throwsA(
          isA<UsbTransferException>().having(
            (e) => e.message,
            'message',
            contains('send_failed'),
          ),
        ),
      );
    });

    test('forwards events until the session ends', () async {
      final passthrough = await openPassthrough();
      final events = <Uint8List>[];
      passthrough.events.listen(events.add);
      await emit({
        'type': 'interrupt',
        'bytes': Uint8List.fromList([1, 2, 3]),
      });
      expect(events, [
        [1, 2, 3],
      ]);
    });

    test('a detach of the open camera ends it', () async {
      await attach();
      final passthrough = await openPassthrough();
      await emit({'type': 'detached', 'deviceName': uuid});

      await passthrough.detached;
      await expectLater(
        passthrough.send(Uint8List(12)),
        throwsA(isA<UsbTransferException>()),
      );
    });

    test('a session the camera closed ends it', () async {
      final watcher = await attach();
      await watcher.requestPermission(cameraRef);
      final passthrough = await openPassthrough();
      await emit({'type': 'closed', 'deviceName': uuid});

      await passthrough.detached;
      // The camera is still plugged in.
      expect(watcher.hasPermission(cameraRef), isTrue);
    });

    test('close closes the session once, even when it fails', () async {
      answers['close'] = (_) => fail('not_open');
      final passthrough = await openPassthrough();
      await passthrough.close();
      await passthrough.close();

      expect(methods().where((m) => m == 'close'), hasLength(1));
      await passthrough.detached;
    });
  });

  /// Answers `send` from a fake camera, as ImageCaptureCore would.
  void answerFrom(FakePtpDevice device) {
    answers['send'] = (call) {
      final command = UsbContainerReader()
          .add((call.arguments as Map)['bytes'] as Uint8List)
          .single;
      device.receivedOpcodes.add(command.code);
      final reply = device.handle(
        command.code,
        command.params,
        dataOut: (call.arguments as Map)['dataOut'] as Uint8List?,
      );
      return {
        'data': reply.data ?? Uint8List(0),
        'response': UsbContainer.withParams(
          UsbContainerType.response,
          reply.code,
          command.transactionId,
          reply.params,
        ).encode(),
      };
    };
  }

  test('connects a client through the bridge', () async {
    answerFrom(FakePtpDevice());
    final watcher = await attach();
    expect(await watcher.requestPermission(cameraRef), UsbPermission.granted);

    final client = await connectUsb(await platform.open(cameraRef));
    addTearDown(client.close);
    expect(client.profileId, 'canon-eos');
    expect(await client.listPhotos(), isNotEmpty);

    await emit({'type': 'detached', 'deviceName': uuid});
    await client.disconnected;
    await expectLater(
      client.listPhotos(),
      throwsA(isA<CameraDisconnectedException>()),
    );
  });

  test('a plugged-in camera connects through ConnectCubit (C3)', () async {
    answerFrom(FakePtpDevice());
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final binder = RecordingBinder();
    final cubit = ConnectCubit(
      connector: cameraConnector(usb: platform),
      identity: IdentityRepository(prefs),
      hostResolver: CameraHostResolver(
        SettingsRepository(prefs),
        wifiGateway: () async => null,
      ),
      networkBinder: binder,
      claimsUsbVendor: claimsCanonOnly,
      usbWatcher: platform.watcher,
      discovery: () async => const [],
    );
    addTearDown(cubit.close);
    final connected = cubit.stream.firstWhere((s) => s is ConnectConnected);

    await attach();
    final state = await connected as ConnectConnected;
    addTearDown(state.client.close);

    expect(methods().take(3), ['start', 'requestPermission', 'open']);
    expect(methods().skip(3).toSet(), {'send'});
    expect(state.target, isA<UsbTarget>());
    expect((state.target! as UsbTarget).device, cameraRef);
    expect((state.client as PtpCameraClient).profileId, 'canon-eos');
    expect(binder.calls, isEmpty);
  });
}
