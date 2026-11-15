import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/usb/android_usb_platform.dart';
import 'package:shutterlink/usb/usb_camera_platform.dart';
import 'package:shutterlink/usb/usb_pipe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const canon = {
    'deviceName': '/dev/bus/usb/001/002',
    'vendorId': 0x04A9,
    'productId': 0x32D2,
    'serial': null,
    'product': 'Canon EOS R',
    'hasPermission': false,
  };
  const canonRef = UsbCameraRef(
    platformId: '/dev/bus/usb/001/002',
    vendorId: 0x04A9,
    productId: 0x32D2,
    name: 'Canon EOS R',
  );

  late List<MethodCall> calls;
  late Map<String, Object? Function(MethodCall call)> answers;
  late List<Map<String, Object?>> buffered;
  MockStreamHandlerEventSink? sink;
  late bool foreground;
  late AndroidUsbPlatform platform;

  Future<void> emit(Map<String, Object?> event) async {
    sink!.success(event);
    await pumpEventQueue();
  }

  List<String> methods() => [for (final call in calls) call.method];

  setUp(() {
    calls = [];
    buffered = [];
    sink = null;
    foreground = true;
    var sessions = 0;
    answers = {
      'list': (_) => <Object?>[],
      'open': (_) => {
        'sessionId': ++sessions,
        'maxPacketSize': 512,
        'maxTransfer': 131072,
      },
      'requestPermission': (_) => false,
    };
    messenger.setMockMethodCallHandler(AndroidUsbPlatform.channel, (
      call,
    ) async {
      calls.add(call);
      return answers[call.method]?.call(call);
    });
    messenger.setMockStreamHandler(
      AndroidUsbPlatform.events,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          sink = events;
          buffered.forEach(events.success);
        },
        onCancel: (_) => sink = null,
      ),
    );
    platform = AndroidUsbPlatform(isForeground: () => foreground);
  });

  tearDown(() async {
    await platform.dispose();
    messenger.setMockMethodCallHandler(AndroidUsbPlatform.channel, null);
    messenger.setMockStreamHandler(AndroidUsbPlatform.events, null);
  });

  Future<AndroidUsbPipe> openPipe() async {
    final link = await platform.open(canonRef);
    await pumpEventQueue();
    return (link as BulkLink).pipe as AndroidUsbPipe;
  }

  group('UsbCameraRef', () {
    test('equals on vendor and product only', () {
      const replugged = UsbCameraRef(
        platformId: '/dev/bus/usb/001/007',
        vendorId: 0x04A9,
        productId: 0x32D2,
        name: 'EOS R',
        serial: '123',
      );
      const other = UsbCameraRef(
        platformId: '/dev/bus/usb/001/002',
        vendorId: 0x04A9,
        productId: 0x0001,
        name: 'Canon EOS R',
      );

      expect(replugged, canonRef);
      expect(replugged.hashCode, canonRef.hashCode);
      expect(other, isNot(canonRef));
      expect(canonRef.toString(), contains('04a9:32d2'));
    });
  });

  group('NoUsbCameraPlatform', () {
    test('finds nothing and opens nothing', () async {
      const platform = NoUsbCameraPlatform();
      final watcher = platform.watcher;
      expect(platform.isExperimental, isFalse);
      expect(AndroidUsbPlatform().isExperimental, isFalse);
      watcher.start('connect');
      watcher.stop('connect');

      expect(await watcher.attached.isEmpty, isTrue);
      expect(await watcher.detached.isEmpty, isTrue);
      expect(watcher.hasPermission(canonRef), isFalse);
      expect(await watcher.requestPermission(canonRef), UsbPermission.denied);
      await expectLater(
        platform.open(canonRef),
        throwsA(isA<UsbTransferException>()),
      );
    });
  });

  group('pipe', () {
    test('open passes the device and reports the transfer sizes', () async {
      final pipe = await openPipe();

      expect(calls.single.method, 'open');
      expect(calls.single.arguments, {'deviceName': canon['deviceName']});
      expect(pipe.maxPacketSize, 512);
      expect(pipe.maxTransfer, 131072);
      expect(pipe.deviceName, canon['deviceName']);
    });

    test('open uses the current device name of an equal camera', () async {
      answers['list'] = (_) => [
        {...canon, 'deviceName': '/dev/bus/usb/001/009'},
      ];
      platform.watcher.start('connect');
      await pumpEventQueue();

      await platform.open(canonRef);

      expect(calls.last.arguments, {'deviceName': '/dev/bus/usb/001/009'});
    });

    test('a failed open throws UsbTransferException', () async {
      answers['open'] = (_) =>
          throw PlatformException(code: 'no_permission', message: 'nope');

      await expectLater(
        platform.open(canonRef),
        throwsA(
          isA<UsbTransferException>().having(
            (e) => e.message,
            'message',
            contains('no_permission'),
          ),
        ),
      );
    });

    test('bulkIn maps bytes, a zero-length packet and errors', () async {
      final pipe = await openPipe();
      final reads = <Object? Function(MethodCall)>[
        (_) => {
          'bytes': Uint8List.fromList([1, 2, 3]),
        },
        (_) => {'bytes': Uint8List(0)},
        (_) => throw PlatformException(code: 'usb_io'),
      ];
      answers['bulkIn'] = (call) => reads.removeAt(0)(call);

      final data = await pipe.bulkIn(4096);
      expect(data, isA<UsbData>());
      expect((data as UsbData).bytes, [1, 2, 3]);
      expect(calls.last.arguments, {'sessionId': 1, 'maxLength': 4096});
      expect(await pipe.bulkIn(4096), isA<UsbZeroLength>());
      final error = await pipe.bulkIn(4096);
      expect(error, isA<UsbReadError>());
      expect(
        (error as UsbReadError).cause,
        isA<PlatformException>().having((e) => e.code, 'code', 'usb_io'),
      );
    });

    test('bulkOut, clearHalt and drainIn pass through', () async {
      final pipe = await openPipe();
      answers['drainIn'] = (_) => 42;

      await pipe.bulkOut(Uint8List.fromList([9, 8]));
      await pipe.clearHalt();
      await pipe.drainIn();

      expect(methods(), ['open', 'bulkOut', 'clearHalt', 'drainIn']);
      expect(calls[1].arguments, {
        'sessionId': 1,
        'bytes': Uint8List.fromList([9, 8]),
      });
      expect(calls[2].arguments, {'sessionId': 1});
      expect(calls[3].arguments, {'sessionId': 1});
    });

    test('a failed transfer throws UsbTransferException', () async {
      final pipe = await openPipe();
      answers['bulkOut'] = (_) => throw PlatformException(code: 'usb_io');
      answers['clearHalt'] = (_) => throw PlatformException(code: 'not_open');

      await expectLater(
        pipe.bulkOut(Uint8List(1)),
        throwsA(isA<UsbTransferException>()),
      );
      await expectLater(
        pipe.clearHalt(),
        throwsA(
          isA<UsbTransferException>().having(
            (e) => e.toString(),
            'toString',
            contains('not_open'),
          ),
        ),
      );
    });

    test('classRequest passes its arguments and returns the bytes', () async {
      final pipe = await openPipe();
      answers['classRequest'] = (_) => {
        'bytes': Uint8List.fromList([4, 0, 1, 0x20]),
      };

      final status = await pipe.classRequest(
        0x67,
        deviceToHost: true,
        length: 20,
      );
      final cancel = Uint8List.fromList([1, 0x40, 7, 0, 0, 0]);
      await pipe.classRequest(0x64, deviceToHost: false, data: cancel);

      expect(status, [4, 0, 1, 0x20]);
      expect(calls[1].arguments, {
        'sessionId': 1,
        'request': 0x67,
        'deviceToHost': true,
        'value': 0,
        'length': 20,
        'data': null,
      });
      expect(calls[2].arguments, {
        'sessionId': 1,
        'request': 0x64,
        'deviceToHost': false,
        'value': 0,
        'length': 0,
        'data': cancel,
      });
    });

    test('a stalled class request throws UsbTransferException', () async {
      final pipe = await openPipe();
      answers['classRequest'] = (_) => throw PlatformException(code: 'usb_io');

      await expectLater(
        pipe.classRequest(0x66, deviceToHost: false),
        throwsA(isA<UsbTransferException>()),
      );
    });

    test('interrupt events reach the open pipe', () async {
      final pipe = await openPipe();
      final received = <Uint8List>[];
      pipe.interrupt.listen(received.add);

      await emit({
        'type': 'interrupt',
        'bytes': Uint8List.fromList([12, 0, 0, 0]),
      });

      expect(received.single, [12, 0, 0, 0]);
    });

    test('unplugging the open device completes detached', () async {
      final pipe = await openPipe();
      final received = <Uint8List>[];
      pipe.interrupt.listen(received.add);
      var detached = false;
      unawaited(pipe.detached.then((_) => detached = true));

      await emit({'type': 'detached', 'deviceName': '/dev/bus/usb/009/009'});
      expect(detached, isFalse);
      await emit({'type': 'detached', 'deviceName': canon['deviceName']});
      await emit({'type': 'interrupt', 'bytes': Uint8List(4)});

      expect(detached, isTrue);
      expect(received, isEmpty);
    });

    test('close releases the device and completes detached', () async {
      final pipe = await openPipe();

      await pipe.close();
      await pipe.detached;
      await pipe.close();

      expect(methods(), ['open', 'close']);
      expect(calls.last.arguments, {'sessionId': 1});
    });

    test('a failing close still ends the pipe', () async {
      final pipe = await openPipe();
      answers['close'] = (_) => throw PlatformException(code: 'usb_io');

      await pipe.close();

      await pipe.detached;
    });

    test(
      'opening again ends the previous pipe without closing the new one',
      () async {
        final first = await openPipe();
        final second = await openPipe();

        await first.detached;
        await first.close();

        expect(methods(), ['open', 'open']);
        expect(second.sessionId, isNot(first.sessionId));
        await second.close();
        expect(methods().last, 'close');
        expect(calls.last.arguments, {'sessionId': second.sessionId});
      },
    );

    test('a replaced pipe never reaches the bridge again', () async {
      final first = await openPipe();
      await openPipe();
      calls.clear();

      final read = await first.bulkIn(4096);
      expect(read, isA<UsbReadError>());
      expect((read as UsbReadError).cause, isA<UsbTransferException>());
      for (final call in <Future<Object?> Function()>[
        () => first.bulkOut(Uint8List(1)),
        first.clearHalt,
        () => first.classRequest(0x67, deviceToHost: true, length: 20),
        first.drainIn,
      ]) {
        await expectLater(call(), throwsA(isA<UsbTransferException>()));
      }

      expect(calls, isEmpty);
    });

    test('an unplugged pipe fails without calling the bridge', () async {
      final pipe = await openPipe();
      await emit({'type': 'detached', 'deviceName': canon['deviceName']});
      calls.clear();

      expect(await pipe.bulkIn(4096), isA<UsbReadError>());
      await expectLater(pipe.drainIn(), throwsA(isA<UsbTransferException>()));
      expect(calls, isEmpty);
    });
  });

  group('watcher', () {
    test('the first owner enumerates, others share the watch', () async {
      answers['list'] = (_) => [canon];
      final enumerated = <bool>[];
      platform.watcher.attached.listen((a) => enumerated.add(a.enumerated));
      final attached = <UsbCameraRef>[];
      platform.watcher.attached.map((a) => a.device).listen(attached.add);

      platform.watcher.start('connect');
      platform.watcher.start('live');
      await pumpEventQueue();

      expect(methods(), ['list']);
      expect(attached, [canonRef]);
      expect(attached.single.name, 'Canon EOS R');
      expect(enumerated, [true]);

      platform.watcher.stop('connect');
      platform.watcher.start('connect');
      await pumpEventQueue();
      expect(methods(), ['list']);

      platform.watcher.stop('connect');
      platform.watcher.stop('live');
      platform.watcher.start('connect');
      await pumpEventQueue();
      expect(methods(), ['list', 'list']);
      expect(attached, [canonRef], reason: 'already reported');
    });

    test('a failed enumeration reports nothing', () async {
      answers['list'] = (_) => throw PlatformException(code: 'boom');
      final attached = <UsbCameraRef>[];
      platform.watcher.attached.map((a) => a.device).listen(attached.add);

      platform.watcher.start('connect');
      await pumpEventQueue();

      expect(attached, isEmpty);
    });

    test('an attach that started the app arrives once listened', () async {
      buffered.add({'type': 'attached', 'device': canon});
      answers['list'] = (_) => [canon];
      final attached = <UsbCameraRef>[];
      final plugged = <UsbAttachment>[];
      platform.watcher.attached.listen(plugged.add);

      platform.watcher.attached.map((a) => a.device).listen(attached.add);
      await pumpEventQueue();
      platform.watcher.start('connect');
      await pumpEventQueue();

      expect(attached, [canonRef]);
      expect(plugged, [const UsbAttachment(canonRef)]);
    });

    test('attach, detach and re-attach are each reported', () async {
      final attached = <UsbCameraRef>[];
      final detached = <UsbCameraRef>[];
      platform.watcher.attached.map((a) => a.device).listen(attached.add);
      platform.watcher.detached.listen(detached.add);
      await pumpEventQueue();

      await emit({'type': 'attached', 'device': canon});
      await emit({'type': 'attached', 'device': canon});
      await emit({'type': 'detached', 'deviceName': canon['deviceName']});
      await emit({'type': 'detached', 'deviceName': canon['deviceName']});
      await emit({
        'type': 'attached',
        'device': {...canon, 'deviceName': '/dev/bus/usb/001/003'},
      });

      expect(attached, [canonRef, canonRef]);
      expect(attached.last.platformId, '/dev/bus/usb/001/003');
      expect(detached, [canonRef]);
    });

    test('a nameless device gets a default name', () async {
      final attached = <UsbCameraRef>[];
      platform.watcher.attached.map((a) => a.device).listen(attached.add);
      await pumpEventQueue();

      await emit({
        'type': 'attached',
        'device': {...canon, 'product': null, 'serial': 'ABC'},
      });

      expect(attached.single.name, 'USB camera');
      expect(attached.single.serial, 'ABC');
    });

    test(
      'permission is tracked across a re-plug by vendor and product',
      () async {
        platform.watcher.attached.listen((_) {});
        await pumpEventQueue();

        await emit({
          'type': 'attached',
          'device': {...canon, 'hasPermission': true},
        });
        expect(platform.watcher.hasPermission(canonRef), isTrue);
        expect(
          await platform.watcher.requestPermission(canonRef),
          UsbPermission.granted,
        );
        expect(methods(), isEmpty);

        await emit({'type': 'detached', 'deviceName': canon['deviceName']});
        expect(platform.watcher.hasPermission(canonRef), isFalse);

        await emit({
          'type': 'attached',
          'device': {...canon, 'deviceName': '/dev/bus/usb/001/005'},
        });
        expect(platform.watcher.hasPermission(canonRef), isFalse);
        await emit({
          'type': 'permission',
          'deviceName': '/dev/bus/usb/001/005',
          'granted': true,
        });
        expect(platform.watcher.hasPermission(canonRef), isTrue);
      },
    );

    test('permission held by the system is granted at once', () async {
      answers['requestPermission'] = (_) => true;

      expect(
        await platform.watcher.requestPermission(canonRef),
        UsbPermission.granted,
      );
      expect(calls.single.arguments, {'deviceName': canon['deviceName']});
    });

    test('in the foreground the user\'s answer is awaited', () async {
      final granted = platform.watcher.requestPermission(canonRef);
      await pumpEventQueue();
      await emit({
        'type': 'permission',
        'deviceName': canon['deviceName'],
        'granted': true,
      });
      expect(await granted, UsbPermission.granted);

      await emit({'type': 'attached', 'device': canon});
      await emit({
        'type': 'permission',
        'deviceName': canon['deviceName'],
        'granted': false,
      });
      final denied = platform.watcher.requestPermission(canonRef);
      await pumpEventQueue();
      await emit({
        'type': 'permission',
        'deviceName': canon['deviceName'],
        'granted': false,
      });
      expect(await denied, UsbPermission.denied);
    });

    test('unplugging during a permission request denies it', () async {
      platform.watcher.attached.listen((_) {});
      await pumpEventQueue();
      await emit({'type': 'attached', 'device': canon});

      final answer = platform.watcher.requestPermission(canonRef);
      await pumpEventQueue();
      await emit({'type': 'detached', 'deviceName': canon['deviceName']});

      expect(await answer, UsbPermission.denied);
    });

    test('in the background the user is asked without waiting', () async {
      foreground = false;

      expect(
        await platform.watcher.requestPermission(canonRef),
        UsbPermission.userActionNeeded,
      );
      expect(methods(), ['requestPermission']);
    });

    test('a gone device is denied', () async {
      answers['requestPermission'] = (_) =>
          throw PlatformException(code: 'no_device');

      expect(
        await platform.watcher.requestPermission(canonRef),
        UsbPermission.denied,
      );
    });

    test('an unanswered request needs user action after the timeout', () async {
      final patient = AndroidUsbPlatform(
        isForeground: () => true,
        permissionTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(patient.dispose);

      expect(
        await patient.watcher.requestPermission(canonRef),
        UsbPermission.userActionNeeded,
      );
      expect(patient.watcher.hasPermission(canonRef), isFalse);
    });
  });
}
