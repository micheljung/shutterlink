import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptpip/ptpip.dart';

import 'fake_camera.dart';

void main() {
  late FakeCamera camera;

  Future<FakeCamera> startCamera(FakeCamera fake) async {
    camera = fake;
    await camera.start();
    return camera;
  }

  tearDown(() => camera.stop());

  Future<PtpIpConnection> open({
    CameraIdentity? identity,
    Duration timeout = const Duration(seconds: 2),
    Duration pairingTimeout = const Duration(seconds: 2),
    PacketTap? tap,
    int? port,
  }) => PtpIpConnection.open(
    host: InternetAddress.loopbackIPv4.address,
    port: port ?? camera.port,
    identity: identity ?? pairedIdentity,
    timeout: timeout,
    pairingTimeout: pairingTimeout,
    tap: tap,
  );

  test('handshake succeeds with a paired GUID', () async {
    await startCamera(FakeCamera(pairedGuids: [pairedGuid]));
    final frames = <(PtpIpChannel, PacketDirection, int)>[];
    final connection = await open(
      tap: (channel, direction, frame) =>
          frames.add((channel, direction, PtpIpPacket.decode(frame).type)),
    );
    expect(connection.isConnected, isTrue);
    expect(connection.commandAck.connectionNumber, fakeConnectionNumber);
    expect(connection.commandAck.name, 'Canon EOS R');
    expect(connection.commandAck.guid, fakeCameraGuid);
    expect(camera.receivedNames, ['Shutterlink']);
    expect(frames, [
      (
        PtpIpChannel.command,
        PacketDirection.sent,
        PtpIpPacketType.initCommandRequest,
      ),
      (
        PtpIpChannel.command,
        PacketDirection.received,
        PtpIpPacketType.initCommandAck,
      ),
      (
        PtpIpChannel.event,
        PacketDirection.sent,
        PtpIpPacketType.initEventRequest,
      ),
      (
        PtpIpChannel.event,
        PacketDirection.received,
        PtpIpPacketType.initEventAck,
      ),
    ]);
    connection.close();
    await connection.disconnected;
    expect(connection.disconnectCause, isNull);
  });

  test('unknown GUID yields PairingRequiredException with reason', () async {
    await startCamera(FakeCamera(pairedGuids: [pairedGuid]));
    final stranger = CameraIdentity(
      guid: Uint8List(ptpIpGuidSize),
      name: 'Stranger',
    );
    await expectLater(
      open(identity: stranger),
      throwsA(
        isA<PairingRequiredException>().having(
          (e) => e.reason,
          'reason',
          fakeInitFailReason,
        ),
      ),
    );
  });

  test('waiting for pairing times out on a silent camera', () async {
    await startCamera(FakeCamera(ignoreInitCommand: true));
    await expectLater(
      open(pairingTimeout: const Duration(milliseconds: 200)),
      throwsA(
        isA<CameraDisconnectedException>().having(
          (e) => e.cause,
          'cause',
          isA<TimeoutException>(),
        ),
      ),
    );
  });

  test('pairing confirmation may outlast the connect timeout', () async {
    await startCamera(
      FakeCamera(initAckDelay: const Duration(milliseconds: 400)),
    );
    final connection = await open(
      timeout: const Duration(milliseconds: 100),
      pairingTimeout: const Duration(seconds: 2),
    );
    expect(connection.isConnected, isTrue);
    connection.close();
  });

  test('default pairing timeout is long enough to confirm on camera', () {
    expect(ptpIpDefaultPairingTimeout, const Duration(seconds: 60));
    expect(ptpIpDefaultConnectTimeout, const Duration(seconds: 5));
  });

  for (final reason in [PtpIpInitFailReason.busy, PtpResponseCode.deviceBusy]) {
    test('busy InitFail reason 0x${reason.toRadixString(16)} '
        'yields CameraBusyException', () async {
      await startCamera(
        FakeCamera(pairedGuids: const [], initFailReason: reason),
      );
      await expectLater(
        open(),
        throwsA(
          isA<CameraBusyException>().having((e) => e.reason, 'reason', reason),
        ),
      );
    });
  }

  test('unspecified InitFail reason means pairing is required', () async {
    await startCamera(
      FakeCamera(
        pairedGuids: const [],
        initFailReason: PtpIpInitFailReason.unspecified,
      ),
    );
    await expectLater(
      open(),
      throwsA(
        isA<PairingRequiredException>().having(
          (e) => e.reason,
          'reason',
          PtpIpInitFailReason.unspecified,
        ),
      ),
    );
  });

  test('unreachable camera yields CameraDisconnectedException', () async {
    await startCamera(FakeCamera());
    final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = unused.port;
    await unused.close();
    await expectLater(
      open(port: port),
      throwsA(isA<CameraDisconnectedException>()),
    );
  });

  test('answers Ping with Pong on both sockets', () async {
    await startCamera(FakeCamera(sendPingAfterHandshake: true));
    final connection = await open();
    for (var i = 0; i < 50 && camera.pongsReceived < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(camera.pongsReceived, 2);
    connection.close();
  });

  test('camera closing the socket completes disconnected', () async {
    await startCamera(FakeCamera());
    final connection = await open();
    camera.dropConnection();
    await connection.disconnected.timeout(const Duration(seconds: 2));
    expect(connection.isConnected, isFalse);
    expect(connection.disconnectCause, isNotNull);
    expect(
      () => connection.send(const PingPacket()),
      throwsA(isA<CameraDisconnectedException>()),
    );
  });

  test('forwards event packets and command packets', () async {
    await startCamera(FakeCamera());
    final connection = await open();
    final command = connection.commandPackets.first;
    connection.send(
      CommandRequest(opcode: PtpOperation.closeSession, transactionId: 9),
    );
    final response = await command as CommandResponse;
    expect(response.transactionId, 9);
    final event = connection.events.first;
    camera.sendEvent(0xC101);
    expect((await event).code, 0xC101);
    connection.abort(StateError('test'));
    expect(connection.disconnectCause, isStateError);
  });

  test('ProtocolException describes itself', () {
    expect(
      const PtpIpProtocolException('bad').toString(),
      'PtpIpProtocolException: bad',
    );
  });
}
