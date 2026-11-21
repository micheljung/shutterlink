import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptp/camera_client.dart';
import 'package:shutterlink/ptp/profile_registry.dart';
import 'package:shutterlink/ptp/ptp_constants.dart';
import 'package:shutterlink/ptp/ptp_protocol_exception.dart';
import 'package:shutterlink/ptp/ptp_session.dart';
import 'package:shutterlink/usb/usb_camera_client.dart';
import 'package:shutterlink/usb/usb_container.dart';
import 'package:shutterlink/usb/usb_passthrough_transport.dart';
import 'package:shutterlink/usb/usb_pipe.dart';

import '../fakes/fake_ptp_device.dart';

const _smallValue = 4;
const _largeValue = 200 * 1000;

/// ImageCaptureCore as the transport sees it: whole transactions, a session
/// it owns, and buffers whose header and order are not certain.
class _FakePassthrough implements UsbPassthrough {
  _FakePassthrough(
    this.device, {
    this.dataHeader = false,
    this.swapped = false,
    this.rewriteTransactionIds = false,
    this.noResponse = false,
  });

  final FakePtpDevice device;
  final bool dataHeader;
  final bool swapped;
  final bool rewriteTransactionIds;
  final bool noResponse;
  final eventsController = StreamController<Uint8List>.broadcast();
  final _detached = Completer<void>();
  final commands = <UsbContainer>[];
  Completer<void>? hold;
  bool closed = false;

  @override
  Future<({Uint8List data, Uint8List response})> send(
    Uint8List commandContainer, {
    Uint8List? dataOut,
  }) async {
    final command = UsbContainerReader().add(commandContainer).single;
    commands.add(command);
    device.receivedOpcodes.add(command.code);
    await hold?.future;
    if (closed) {
      throw StateError('session closed');
    }
    final reply = device.handle(command.code, command.params, dataOut: dataOut);
    final transactionId = rewriteTransactionIds
        ? command.transactionId + 1000
        : command.transactionId;
    final payload = reply.data ?? Uint8List(0);
    final data = dataHeader
        ? UsbContainer(
            type: UsbContainerType.data,
            code: command.code,
            transactionId: transactionId,
            payload: payload,
          ).encode()
        : payload;
    final response = noResponse
        ? Uint8List(0)
        : UsbContainer.withParams(
            UsbContainerType.response,
            reply.code,
            transactionId,
            reply.params,
          ).encode();
    return swapped
        ? (data: response, response: data)
        : (data: data, response: response);
  }

  @override
  Stream<Uint8List> get events => eventsController.stream;

  @override
  Future<void> get detached => _detached.future;

  void unplug() => _detached.complete();

  @override
  Future<void> close() async => closed = true;
}

void main() {
  late FakePtpDevice device;

  setUp(() => device = FakePtpDevice());

  UsbPassthroughTransport open(_FakePassthrough passthrough) {
    final transport = UsbPassthroughTransport(passthrough);
    addTearDown(transport.close);
    return transport;
  }

  test('answers OpenSession and CloseSession itself', () async {
    final passthrough = _FakePassthrough(device);
    final session = PtpSession(open(passthrough));
    await session.openSession();
    await session.execute(PtpOperation.closeSession);
    expect(passthrough.commands, isEmpty);
  });

  for (final (name, passthrough) in [
    ('without headers', () => _FakePassthrough(FakePtpDevice())),
    (
      'with a data header',
      () => _FakePassthrough(FakePtpDevice(), dataHeader: true),
    ),
    (
      'with the buffers swapped',
      () => _FakePassthrough(FakePtpDevice(), swapped: true, dataHeader: true),
    ),
    (
      'with rewritten transaction IDs',
      () => _FakePassthrough(FakePtpDevice(), rewriteTransactionIds: true),
    ),
  ]) {
    test('decodes data and response $name', () async {
      final fake = passthrough();
      final transport = open(fake);
      final result = await transport.transact(
        PtpOperation.getPartialObject,
        const [FakePtpDevice.jpegHandle, 10, 100],
        3,
      );
      expect(result.code, PtpResponseCode.ok);
      final content = fake.device.objects
          .firstWhere((o) => o.handle == FakePtpDevice.jpegHandle)
          .content;
      expect(result.data, Uint8List.sublistView(content, 10, 110));
      final command = fake.commands.single;
      expect(command.type, UsbContainerType.command);
      expect(command.transactionId, 3);
      expect(command.params, [FakePtpDevice.jpegHandle, 10, 100]);
    });
  }

  test('passes a response code and parameters through', () async {
    final result = await open(_FakePassthrough(device))
        .transact(PtpOperation.getObjectInfo, const [0xDEAD], 1);
    expect(result.code, PtpResponseCode.invalidObjectHandle);
    expect(result.data, isEmpty);
  });

  test('raises the session timeout to 30 s', () {
    final transport = open(_FakePassthrough(device));
    expect(transport.minimumResponseTimeout, const Duration(seconds: 30));
    transport
      ..onActivity = () {}
      ..onTransferTiming = (_, _) => fail('no channel to measure');
  });

  for (final size in [_smallValue, _largeValue]) {
    test('round-trips a $size-byte property value', () async {
      final session = PtpSession(open(_FakePassthrough(device)));
      final value = patternBytes(size, seed: size);
      await session.execute(
        PtpOperation.setDevicePropValue,
        params: const [PtpDeviceProperty.dateTime],
        dataOut: value,
      );
      final read = await session.execute(
        PtpOperation.getDevicePropValue,
        params: const [PtpDeviceProperty.dateTime],
      );
      expect(read.data, value);
    });
  }

  test('abort closes the session and fails the transaction', () async {
    final passthrough = _FakePassthrough(device)..hold = Completer<void>();
    final transport = open(passthrough);
    final pending = transport.transact(PtpOperation.getStorageIds, const [], 1);
    await Future<void>.delayed(Duration.zero);
    transport.abort(TimeoutException('No PTP response'));

    await expectLater(pending, throwsA(isA<CameraDisconnectedException>()));
    expect(passthrough.closed, isTrue);
    expect(transport.isConnected, isFalse);
    expect(transport.disconnectCause, isA<TimeoutException>());
    await transport.disconnected;
    passthrough.hold!.complete();
    await expectLater(
      transport.transact(PtpOperation.getStorageIds, const [], 2),
      throwsA(isA<CameraDisconnectedException>()),
    );
  });

  test('a detach disconnects it', () async {
    final passthrough = _FakePassthrough(device);
    final transport = open(passthrough);
    passthrough.unplug();
    await transport.disconnected;
    expect(passthrough.closed, isTrue);
  });

  test('a failed send or a missing response disconnects it', () async {
    final failing = _FakePassthrough(device)..closed = true;
    final transport = open(failing);
    await expectLater(
      transport.transact(PtpOperation.getStorageIds, const [], 1),
      throwsA(isA<CameraDisconnectedException>()),
    );
    expect(transport.disconnectCause, isA<StateError>());

    final silent = open(_FakePassthrough(device, noResponse: true));
    await expectLater(
      silent.transact(PtpOperation.getStorageIds, const [], 1),
      throwsA(isA<CameraDisconnectedException>()),
    );
    expect(silent.disconnectCause, isA<PtpProtocolException>());
  });

  test('reports events and ignores garbage', () async {
    final passthrough = _FakePassthrough(device);
    final transport = open(passthrough);
    final event = transport.events.first;
    passthrough.eventsController
      ..add(Uint8List(3))
      ..add(
        UsbContainer.withParams(UsbContainerType.event, 0x4002, 0, [
          0x21,
        ]).encode(),
      );
    expect((await event).params, [0x21]);
  });

  test('connectUsb drives a passthrough link', () async {
    final client = await connectUsb(
      PassthroughLink(_FakePassthrough(device)),
      registry: const ProfileRegistry([]),
    );
    addTearDown(client.close);
    expect(client.profileId, 'generic-ptp');
    expect(
      (await client.listPhotos()).map((p) => p.handle),
      contains(FakePtpDevice.jpegHandle),
    );
    expect(device.receivedOpcodes.first, PtpOperation.getDeviceInfo);
  });
}
