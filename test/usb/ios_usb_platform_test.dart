import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptp/camera_client.dart';
import 'package:shutterlink/usb/ios_usb_platform.dart';
import 'package:shutterlink/usb/usb_camera_client.dart';
import 'package:shutterlink/usb/usb_camera_platform.dart';
import 'package:shutterlink/usb/usb_container.dart';
import 'package:shutterlink/usb/usb_pipe.dart';

import '../fakes/fake_ptp_device.dart';

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
      watcher.attached.listen(attached.add);
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

    test('names a camera without a product name', () async {
      final attached = <UsbCameraRef>[];
      platform.watcher.attached.listen(attached.add);
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
      platform.watcher.attached.listen(attached.add);
      await attach();
      platform.watcher.stop('connect');
      await attach();

      expect(attached, [cameraRef, cameraRef]);
    });

    test('keeps the open camera when browsing stops', () async {
      final attached = <UsbCameraRef>[];
      final detached = <UsbCameraRef>[];
      platform.watcher.attached.listen(attached.add);
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

  test('connects a client through the bridge', () async {
    final device = FakePtpDevice();
    answers['send'] = (call) {
      final command = UsbContainerReader()
          .add((call.arguments as Map)['bytes'] as Uint8List)
          .single;
      device.receivedOpcodes.add(command.code);
      final reply = device.handle(command.code, command.params);
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
}
