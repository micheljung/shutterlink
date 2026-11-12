import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptpip/ptpip.dart';

void main() {
  final packets = <PtpIpPacket>[
    const InitEventAck(),
    const CommandResponse(code: PtpResponseCode.ok, transactionId: 1),
    const StartData(transactionId: 2, totalLength: 3),
    EndDataPacket(transactionId: 2, payload: Uint8List.fromList([7, 8, 9])),
    const PingPacket(),
  ];
  final stream = Uint8List.fromList([for (final p in packets) ...p.encode()]);

  Future<List<PtpIpPacket>> decode(Iterable<Uint8List> chunks) =>
      Stream.fromIterable(chunks).transform(const PtpIpPacketReader()).toList();

  test('reassembles a byte-by-byte stream', () async {
    final decoded = await decode([
      for (final byte in stream) Uint8List.fromList([byte]),
    ]);
    expect(decoded.map((p) => p.type), packets.map((p) => p.type));
    expect((decoded[3] as EndDataPacket).payload, [7, 8, 9]);
  });

  test('splits a single chunk holding many packets', () async {
    final decoded = await decode([stream]);
    expect(decoded, hasLength(packets.length));
  });

  test('reassembles random fragmentation', () async {
    final random = Random(3);
    final chunks = <Uint8List>[];
    var offset = 0;
    while (offset < stream.length) {
      final size = min(1 + random.nextInt(13), stream.length - offset);
      chunks.add(stream.sublist(offset, offset + size));
      offset += size;
    }
    final decoded = await decode(chunks);
    expect(decoded.map((p) => p.type), packets.map((p) => p.type));
  });

  test('frame reader yields the raw frames', () async {
    final frames = await Stream.fromIterable([stream])
        .transform(const PtpIpFrameReader())
        .toList();
    expect(frames.first, packets.first.encode());
  });

  test('invalid length is reported as an error', () async {
    final result = decode([
      Uint8List.fromList([4, 0, 0, 0, 1, 0, 0, 0]),
    ]);
    await expectLater(result, throwsFormatException);
  });

  test('upstream errors are forwarded', () async {
    final controller = StreamController<Uint8List>();
    final result = controller.stream
        .transform(const PtpIpPacketReader())
        .toList();
    final expectation = expectLater(result, throwsStateError);
    controller.addError(StateError('boom'));
    await controller.close();
    await expectation;
  });
}
