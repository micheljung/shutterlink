import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/download/object_fetcher.dart';
import 'package:shutterlink/ptp/camera_client.dart';
import 'package:shutterlink/ptp/profile_registry.dart';
import 'package:shutterlink/ptp/ptp_camera_client.dart';
import 'package:shutterlink/ptp/ptp_constants.dart';
import 'package:shutterlink/ptp/ptp_session.dart';
import 'package:shutterlink/usb/usb_bulk_transport.dart';
import 'package:shutterlink/usb/usb_camera_client.dart';
import 'package:shutterlink/usb/usb_container.dart';
import 'package:shutterlink/usb/usb_pipe.dart';

import '../fakes/fake_ptp_device.dart';
import '../fakes/fake_usb_pipe.dart';

const _resetSequence = ['clearHalt', 'class 0x66', 'class 0x67', 'drain'];
const _watchdog = Duration(milliseconds: 100);
const _slowRead = Duration(milliseconds: 40);

/// Standard PTP only, so the tests see no Canon event polling.
const _genericOnly = ProfileRegistry([]);

void main() {
  late FakePtpDevice device;

  setUp(() => device = FakePtpDevice());

  Future<PtpCameraClient> connect(FakeUsbPipe pipe) async {
    final client = await connectUsb(BulkLink(pipe), registry: _genericOnly);
    addTearDown(client.close);
    return client;
  }

  Future<(PtpSession, UsbBulkTransport)> openSession(FakeUsbPipe pipe) async {
    final transport = await UsbBulkTransport.open(pipe);
    addTearDown(transport.close);
    return (PtpSession(transport, responseTimeout: _watchdog), transport);
  }

  Uint8List contentOf(int handle) =>
      device.objects.firstWhere((o) => o.handle == handle).content;

  Future<CameraObject> photo(CameraClient client, int handle) async =>
      (await client.listPhotos()).firstWhere((o) => o.handle == handle);

  int count(int opcode) =>
      device.receivedOpcodes.where((op) => op == opcode).length;

  group('reset sequence', () {
    test('runs before the first transaction', () async {
      final pipe = FakeUsbPipe(device);
      await connect(pipe);
      expect(pipe.calls.take(4), _resetSequence);
      expect(device.receivedOpcodes.first, PtpOperation.openSession);
    });

    test('discards stale data from an earlier session', () async {
      final stale = UsbContainer.withParams(
        UsbContainerType.response,
        PtpResponseCode.deviceBusy,
        0,
      ).encode();
      final pipe = FakeUsbPipe(device, staleInData: stale);
      final client = await connect(pipe);
      expect(client.profileId, 'generic-ptp');
      expect(pipe.calls, contains('drain'));
    });

    test('sends Cancel when Device Reset stalls', () async {
      final pipe = FakeUsbPipe(device, resetStalls: true);
      await connect(pipe);
      expect(pipe.calls.take(5), [
        'clearHalt',
        'class 0x66',
        'class 0x64',
        'class 0x67',
        'drain',
      ]);
    });

    test('polls a busy device until it is ready', () async {
      final pipe = FakeUsbPipe(device, deviceStatusBusyPolls: 3);
      await connect(pipe);
      expect(pipe.calls.where((c) => c == 'class 0x67'), hasLength(4));
    });

    test('gives up on a device that stays busy, and closes the pipe', () async {
      final pipe = FakeUsbPipe(device, deviceStatusBusyPolls: 1 << 30);
      final started = DateTime.now();
      await expectLater(
        UsbBulkTransport.open(pipe),
        throwsA(isA<CameraDisconnectedException>()),
      );
      expect(
        DateTime.now().difference(started),
        greaterThanOrEqualTo(const Duration(seconds: 2)),
      );
      expect(pipe.isClosed, isTrue);
    });
  });

  group('over an unmodified PtpSession', () {
    test('downloads from an offset with containers split mid-read', () async {
      // 16 KiB reads never line up with the 12-byte container headers.
      final client = await connect(FakeUsbPipe(device, maxTransfer: 16384));
      const offset = 1000;
      final object = await photo(client, FakePtpDevice.largeJpegHandle);
      final bytes = BytesBuilder(copy: false);
      await client.download(
        object,
        (chunk) async => bytes.add(chunk),
        offset: offset,
      );
      expect(
        bytes.takeBytes(),
        Uint8List.sublistView(contentOf(object.handle), offset),
      );
    });

    test('a cancel between chunks stops the download', () async {
      final client = await connect(FakeUsbPipe(device));
      final object = await photo(client, FakePtpDevice.largeJpegHandle);
      final token = CancelToken();
      await expectLater(
        client.download(
          object,
          (_) async => token.cancel(),
          cancelToken: token,
        ),
        throwsA(isA<TransferCancelledException>()),
      );
      expect(count(PtpOperation.getPartialObject), 1);
    });

    test('a thumbnail waits behind a held download', () async {
      final client = await connect(FakeUsbPipe(device, maxTransfer: 16384));
      final object = await photo(client, FakePtpDevice.largeJpegHandle);
      final downloaded = client.download(object, (_) async {});
      final thumbnail = client.thumbnail(FakePtpDevice.jpegHandle);
      expect(await thumbnail, isNotEmpty);
      await downloaded;
      expect(
        device.receivedOpcodes.indexOf(PtpOperation.getThumb),
        greaterThan(
          device.receivedOpcodes.lastIndexOf(PtpOperation.getPartialObject),
        ),
      );
    });

    test('a busy delete is asked again', () async {
      device.deleteBusyResponses = 1;
      final client = await connect(FakeUsbPipe(device));
      await client.delete(FakePtpDevice.jpegHandle);
      expect(count(PtpOperation.deleteObject), 2);
    });
  });

  group('watchdog', () {
    test('is re-armed by slow non-empty reads', () async {
      final (session, _) = await openSession(
        FakeUsbPipe(device, maxTransfer: 512, readDelay: _slowRead),
      );
      final started = DateTime.now();
      final result = await session.execute(
        PtpOperation.getPartialObject,
        params: const [FakePtpDevice.jpegHandle, 0, FakePtpDevice.jpegSize],
      );
      expect(DateTime.now().difference(started), greaterThan(_watchdog * 2));
      expect(result.data, contentOf(FakePtpDevice.jpegHandle));
    });

    test('is not re-armed by zero-length packets', () async {
      final pipe = FakeUsbPipe(
        device,
        readDelay: _slowRead,
        onlyZeroLengthReads: true,
      );
      final (session, transport) = await openSession(pipe);
      await expectLater(
        session.execute(PtpOperation.getStorageIds),
        throwsA(isA<CameraDisconnectedException>()),
      );
      expect(transport.disconnectCause, isA<TimeoutException>());
      expect(pipe.isClosed, isTrue);
    });

    test('trips on a stalled pipe and closes it', () async {
      final pipe = FakeUsbPipe(
        device,
        maxTransfer: 16384,
        stallAfterBytes: 20000,
      );
      final (session, transport) = await openSession(pipe);
      await expectLater(
        session.execute(
          PtpOperation.getPartialObject,
          params: const [FakePtpDevice.largeJpegHandle, 0, 100000],
        ),
        throwsA(isA<CameraDisconnectedException>()),
      );
      expect(transport.disconnectCause, isA<TimeoutException>());
      expect(transport.isConnected, isFalse);
      expect(pipe.isClosed, isTrue);
      await expectLater(
        session.execute(PtpOperation.getStorageIds),
        throwsA(isA<CameraDisconnectedException>()),
      );
    });
  });

  test('an unplug mid-download fails it, and a new pipe resumes it', () async {
    final directory = await Directory.systemTemp.createTemp('usb_resume');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/IMG_0003.JPG');
    final first = FakeUsbPipe(
      device,
      maxTransfer: 16384,
      unplugAfterBytes: ptpDownloadChunkSize + 300000,
    );
    final client = await connect(first);
    final object = await photo(client, FakePtpDevice.largeJpegHandle);

    await expectLater(
      const ObjectFetcher().fetch(client, object, file),
      throwsA(isA<CameraDisconnectedException>()),
    );
    await client.disconnected;
    final partial = await file.length();
    expect(partial, greaterThan(0));
    expect(partial, lessThan(object.size));

    final second = FakeUsbPipe(device, maxTransfer: 16384);
    final resumed = await connect(second);
    expect(second.calls.take(4), _resetSequence);
    int? resumedFrom;
    await const ObjectFetcher().fetch(
      resumed,
      object,
      file,
      onResume: (offset) => resumedFrom = offset,
    );
    expect(resumedFrom, partial);
    expect(await file.readAsBytes(), contentOf(object.handle));
  });

  group('transport', () {
    test('decodes interrupt events and drops garbled ones', () async {
      final event = UsbContainer.withParams(UsbContainerType.event, 0x4002, 5, [
        0x21,
      ]).encode();
      final garbled = Uint8List.fromList([4, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0]);
      final pipe = FakeUsbPipe(
        device,
        interruptEvents: [
          garbled,
          Uint8List.sublistView(event, 0, 8),
          Uint8List.sublistView(event, 8),
        ],
      );
      final transport = await UsbBulkTransport.open(pipe);
      addTearDown(transport.close);
      final received = await transport.events.first;
      expect(received.code, 0x4002);
      expect(received.transactionId, 5);
      expect(received.params, [0x21]);
    });

    test('a detach disconnects it', () async {
      final pipe = FakeUsbPipe(device);
      final transport = await UsbBulkTransport.open(pipe);
      pipe.unplug();
      await transport.disconnected;
      expect(transport.isConnected, isFalse);
      expect(pipe.isClosed, isTrue);
      await expectLater(
        transport.transact(PtpOperation.getStorageIds, const [], 1),
        throwsA(isA<CameraDisconnectedException>()),
      );
    });

    test('a framing error aborts the transaction and closes', () async {
      final pipe = _ScriptedPipe(
        FakeUsbPipe(device),
        UsbContainer.withParams(UsbContainerType.command, 0x1001, 1).encode(),
      );
      final transport = await UsbBulkTransport.open(pipe);
      await expectLater(
        transport.transact(PtpOperation.getStorageIds, const [], 1),
        throwsA(isA<CameraDisconnectedException>()),
      );
      expect(transport.isConnected, isFalse);
    });

    test('skips containers of another transaction', () async {
      final pipe = _ScriptedPipe(
        FakeUsbPipe(device),
        UsbContainer.withParams(
          UsbContainerType.response,
          PtpResponseCode.deviceBusy,
          99,
        ).encode(),
      );
      final transport = await UsbBulkTransport.open(pipe);
      addTearDown(transport.close);
      final result = await transport.transact(
        PtpOperation.getStorageIds,
        const [],
        1,
      );
      expect(result.code, PtpResponseCode.ok);
      expect(transport.minimumResponseTimeout, isNull);
    });
  });
}

/// Answers the first read with [script], then defers to [inner].
class _ScriptedPipe implements UsbBulkPipe {
  _ScriptedPipe(this.inner, this.script);

  final FakeUsbPipe inner;
  Uint8List? script;

  @override
  Future<UsbRead> bulkIn(int maxLength) async {
    final bytes = script;
    script = null;
    return bytes == null ? inner.bulkIn(maxLength) : UsbData(bytes);
  }

  @override
  int get maxPacketSize => inner.maxPacketSize;

  @override
  int get maxTransfer => inner.maxTransfer;

  @override
  Future<void> bulkOut(Uint8List bytes) => inner.bulkOut(bytes);

  @override
  Stream<Uint8List> get interrupt => inner.interrupt;

  @override
  Future<void> get detached => inner.detached;

  @override
  Future<void> clearHalt() => inner.clearHalt();

  @override
  Future<Uint8List> classRequest(
    int request, {
    required bool deviceToHost,
    int value = 0,
    int length = 0,
    Uint8List? data,
  }) => inner.classRequest(
    request,
    deviceToHost: deviceToHost,
    value: value,
    length: length,
    data: data,
  );

  @override
  Future<void> drainIn() => inner.drainIn();

  @override
  Future<void> close() => inner.close();
}
