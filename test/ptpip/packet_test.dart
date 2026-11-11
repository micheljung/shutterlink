import 'dart:typed_data';

import 'package:eos_transfer/ptpip/ptpip.dart';
import 'package:flutter_test/flutter_test.dart';

T roundTrip<T extends PtpIpPacket>(T packet) {
  final decoded = PtpIpPacket.decode(packet.encode());
  expect(decoded, isA<T>());
  expect(decoded.type, packet.type);
  return decoded as T;
}

void main() {
  final guid = Uint8List.fromList(List.generate(ptpIpGuidSize, (i) => i * 3));

  test('InitCommandRequest matches the libgphoto2 layout', () {
    final bytes = InitCommandRequest(guid: guid, name: 'Ab').encode();
    final data = ByteData.sublistView(bytes);
    const nameOffset = 24;
    expect(data.getUint32(0, Endian.little), bytes.length);
    expect(bytes.length, nameOffset + 3 * 2 + 4);
    expect(
      data.getUint32(4, Endian.little),
      PtpIpPacketType.initCommandRequest,
    );
    expect(bytes.sublist(8, nameOffset), guid);
    expect(bytes.sublist(nameOffset, nameOffset + 6), [0x41, 0, 0x62, 0, 0, 0]);
    expect(data.getUint16(nameOffset + 6, Endian.little), 0);
    expect(data.getUint16(nameOffset + 8, Endian.little), 1);

    final decoded = roundTrip(InitCommandRequest(guid: guid, name: 'Ab'));
    expect(decoded.guid, guid);
    expect(decoded.name, 'Ab');
    expect(decoded.majorVersion, PtpIpVersion.major);
    expect(decoded.minorVersion, PtpIpVersion.minor);
  });

  test('InitCommandRequest rejects a GUID of the wrong size', () {
    expect(
      () => InitCommandRequest(guid: Uint8List(3), name: 'x'),
      throwsArgumentError,
    );
  });

  test('InitCommandAck round-trips', () {
    final ack = roundTrip(
      InitCommandAck(connectionNumber: 5, guid: guid, name: 'Canon EOS R'),
    );
    expect(ack.connectionNumber, 5);
    expect(ack.guid, guid);
    expect(ack.name, 'Canon EOS R');
  });

  test('InitCommandAck without version tolerates the short form', () {
    final full = InitCommandAck(
      connectionNumber: 1,
      guid: guid,
      name: '',
    ).encode();
    final short = Uint8List.fromList(full.sublist(0, full.length - 4));
    ByteData.sublistView(short).setUint32(0, short.length, Endian.little);
    final ack = PtpIpPacket.decode(short) as InitCommandAck;
    expect(ack.majorVersion, PtpIpVersion.major);
  });

  test('event init, ack and fail round-trip', () {
    expect(roundTrip(const InitEventRequest(9)).connectionNumber, 9);
    roundTrip(const InitEventAck());
    expect(roundTrip(const InitFail(0x2019)).reason, 0x2019);
    final bare = Uint8List.fromList([8, 0, 0, 0, 5, 0, 0, 0]);
    expect((PtpIpPacket.decode(bare) as InitFail).reason, 0);
  });

  test('CommandRequest encodes dataphase, opcode, txid and params', () {
    final request = CommandRequest(
      opcode: 0x101B,
      transactionId: 42,
      params: const [1, 2, 3],
    );
    final bytes = request.encode();
    final data = ByteData.sublistView(bytes);
    expect(bytes.length, 18 + 3 * 4);
    expect(data.getUint32(8, Endian.little), 1);
    expect(data.getUint16(12, Endian.little), 0x101B);
    expect(data.getUint32(14, Endian.little), 42);
    expect(data.getUint32(18, Endian.little), 1);

    final decoded = roundTrip(request);
    expect(decoded.opcode, 0x101B);
    expect(decoded.transactionId, 42);
    expect(decoded.params, [1, 2, 3]);
    expect(decoded.dataPhase, PtpDataPhase.noneOrDataIn);
    expect(
      roundTrip(
        CommandRequest(
          dataPhase: PtpDataPhase.dataOut,
          opcode: 1,
          transactionId: 1,
        ),
      ).dataPhase,
      PtpDataPhase.dataOut,
    );
  });

  test('CommandRequest rejects more than five params', () {
    expect(
      () => CommandRequest(
        opcode: 1,
        transactionId: 1,
        params: const [1, 2, 3, 4, 5, 6],
      ),
      throwsArgumentError,
    );
  });

  test('response and event round-trip', () {
    final response = roundTrip(
      const CommandResponse(code: 0x2001, transactionId: 3, params: [7]),
    );
    expect(response.code, 0x2001);
    expect(response.transactionId, 3);
    expect(response.params, [7]);
    final event = roundTrip(
      const EventPacket(code: 0x4002, transactionId: 1, params: [8, 9]),
    );
    expect(event.code, 0x4002);
    expect(event.params, [8, 9]);
  });

  test('data phase packets round-trip', () {
    final start = roundTrip(
      const StartData(transactionId: 4, totalLength: 0xFFFFFFFF),
    );
    expect(start.totalLength, 0xFFFFFFFF);
    final payload = Uint8List.fromList([1, 2, 3]);
    final data = roundTrip(DataPacket(transactionId: 4, payload: payload));
    expect(data.payload, payload);
    final end = roundTrip(EndDataPacket(transactionId: 4, payload: payload));
    expect(end.transactionId, 4);
    expect(end.payload, payload);
    expect(roundTrip(const CancelPacket(4)).transactionId, 4);
    roundTrip(const PingPacket());
    roundTrip(const PongPacket());
  });

  test('StartData uses only the low 32 bits of the length field', () {
    final bytes = const StartData(transactionId: 1, totalLength: 5).encode();
    expect(bytes, hasLength(20));
    ByteData.sublistView(bytes).setUint32(16, 0xABCD, Endian.little);
    expect((PtpIpPacket.decode(bytes) as StartData).totalLength, 5);
  });

  test('decode rejects malformed frames', () {
    expect(() => PtpIpPacket.decode(Uint8List(4)), throwsFormatException);
    expect(
      () => PtpIpPacket.decode(Uint8List.fromList([9, 0, 0, 0, 1, 0, 0, 0])),
      throwsFormatException,
    );
    expect(
      () => PtpIpPacket.decode(Uint8List.fromList([8, 0, 0, 0, 99, 0, 0, 0])),
      throwsFormatException,
    );
    expect(
      () => PtpIpPacket.decode(Uint8List.fromList([8, 0, 0, 0, 3, 0, 0, 0])),
      throwsFormatException,
    );
  });

  test('describePacketType names every type', () {
    for (var type = 1; type <= PtpIpPacketType.pong; type++) {
      expect(describePacketType(type), isNot(startsWith('Unknown')));
    }
    expect(describePacketType(99), 'Unknown(99)');
  });

  test('hexDump prints offsets and bytes', () {
    final dump = hexDump(Uint8List.fromList(List.generate(17, (i) => i)));
    expect(dump.split('\n').first, startsWith('00000000  00 01 02'));
    expect(dump, contains('00000010  10'));
  });
}
