import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptp/ptp_protocol_exception.dart';
import 'package:shutterlink/usb/usb_container.dart';

import '../fakes/fake_ptp_device.dart';

/// [bytes] cut into transfers of at most [size] bytes.
List<Uint8List> _transfers(Uint8List bytes, int size) => [
  for (var at = 0; at < bytes.length; at += size)
    Uint8List.sublistView(
      bytes,
      at,
      at + size < bytes.length ? at + size : bytes.length,
    ),
];

List<UsbContainer> _readAll(UsbContainerReader reader, List<Uint8List> parts) =>
    [for (final part in parts) ...reader.add(part)];

Uint8List _concat(List<Uint8List> parts) {
  final builder = BytesBuilder();
  parts.forEach(builder.add);
  return builder.takeBytes();
}

Uint8List _dataContainer(Uint8List payload, {int transactionId = 7}) =>
    UsbContainer(
      type: UsbContainerType.data,
      code: 0x101B,
      transactionId: transactionId,
      payload: payload,
    ).encode();

Uint8List _unknownLengthHeader() =>
    (ByteData(usbContainerHeaderSize)
          ..setUint32(0, usbUnknownContainerLength, Endian.little)
          ..setUint16(4, UsbContainerType.data.code, Endian.little)
          ..setUint16(6, 0x1009, Endian.little)
          ..setUint32(8, 3, Endian.little))
        .buffer
        .asUint8List();

void main() {
  test('encodes and decodes all four container types', () {
    for (final type in UsbContainerType.values) {
      final encoded = UsbContainer.withParams(type, 0x1234, 0x01020304, [
        1,
        0xFFFFFFFF,
      ]).encode();
      expect(encoded.sublist(0, 12), [
        20, 0, 0, 0, //
        type.code, 0,
        0x34, 0x12,
        4, 3, 2, 1,
      ]);
      final decoded = UsbContainerReader().add(encoded).single;
      expect(decoded.type, type);
      expect(decoded.code, 0x1234);
      expect(decoded.transactionId, 0x01020304);
      expect(decoded.params, [1, 0xFFFFFFFF]);
    }
  });

  test('a header split across transfers', () {
    final encoded = UsbContainer.withParams(
      UsbContainerType.response,
      0x2001,
      9,
      [42],
    ).encode();
    final reader = UsbContainerReader();
    expect(reader.add(Uint8List.sublistView(encoded, 0, 5)), isEmpty);
    expect(reader.add(Uint8List.sublistView(encoded, 5, 11)), isEmpty);
    final response = reader.add(Uint8List.sublistView(encoded, 11)).single;
    expect(response.code, 0x2001);
    expect(response.params, [42]);
  });

  test('data across many transfers at maxTransfer 16384', () {
    final payload = patternBytes(100000);
    final containers = _readAll(
      UsbContainerReader(),
      _transfers(_dataContainer(payload), 16384),
    );
    expect(containers.single.payload, payload);
  });

  test('1 MiB + 17 bytes, followed by the response in the same read', () {
    final payload = patternBytes(1024 * 1024 + 17);
    final stream = _concat([
      _dataContainer(payload),
      UsbContainer.withParams(UsbContainerType.response, 0x2001, 7).encode(),
    ]);
    final containers = _readAll(
      UsbContainerReader(),
      _transfers(stream, 16384),
    );
    expect(containers.map((c) => c.type), [
      UsbContainerType.data,
      UsbContainerType.response,
    ]);
    expect(containers.first.payload, payload);
  });

  test('an exact multiple of 512 followed by a zero-length packet', () {
    final container = _dataContainer(patternBytes(1024 - 12));
    expect(container.length % 512, 0);
    final reader = UsbContainerReader();
    expect(reader.add(container).single.payload.length, 1012);
    expect(reader.add(Uint8List(0)), isEmpty);
    final response = UsbContainer.withParams(
      UsbContainerType.response,
      0x2001,
      7,
    ).encode();
    expect(reader.add(response).single.type, UsbContainerType.response);
  });

  test('an unknown length ends with the first short transfer', () {
    final payload = patternBytes(512 * 3 - 12 + 100);
    final stream = _concat([_unknownLengthHeader(), payload]);
    final reader = UsbContainerReader();
    final parts = _transfers(stream, 512);
    for (final part in parts.take(parts.length - 1)) {
      expect(reader.add(part), isEmpty);
    }
    final data = reader.add(parts.last).single;
    expect(data.type, UsbContainerType.data);
    expect(data.code, 0x1009);
    expect(data.payload, payload);
  });

  test('an unknown length on a packet boundary ends with the ZLP', () {
    final payload = patternBytes(1024 - 12);
    final reader = UsbContainerReader();
    expect(reader.add(_concat([_unknownLengthHeader(), payload])), isEmpty);
    expect(reader.add(Uint8List(0)).single.payload, payload);
  });

  test('a container may end inside a short transfer with the response', () {
    final reader = UsbContainerReader();
    final data = _dataContainer(patternBytes(1000));
    final tail = _concat([
      Uint8List.sublistView(data, 512),
      UsbContainer.withParams(UsbContainerType.response, 0x2001, 7).encode(),
    ]);
    expect(reader.add(Uint8List.sublistView(data, 0, 512)), isEmpty);
    expect(reader.add(tail).map((c) => c.type), [
      UsbContainerType.data,
      UsbContainerType.response,
    ]);
  });

  test('a header in a short transfer of its own, then the payload', () {
    final payload = patternBytes(1500);
    final data = _dataContainer(payload);
    final response = UsbContainer.withParams(
      UsbContainerType.response,
      0x2001,
      7,
    ).encode();
    final reader = UsbContainerReader();
    expect(reader.add(Uint8List.sublistView(data, 0, 12)), isEmpty);
    expect(reader.add(Uint8List.sublistView(data, 12, 12 + 1024)), isEmpty);
    final containers = reader.add(
      _concat([Uint8List.sublistView(data, 12 + 1024), response]),
    );
    expect(containers.map((c) => c.type), [
      UsbContainerType.data,
      UsbContainerType.response,
    ]);
    expect(containers.first.payload, payload);
  });

  test('a reader for another endpoint accepts short transfers', () {
    final event = UsbContainer.withParams(UsbContainerType.event, 0x4002, 1, [
      1,
      2,
      3,
    ]).encode();
    final reader = UsbContainerReader(rejectShortTransfers: false);
    expect(reader.add(Uint8List.sublistView(event, 0, 16)), isEmpty);
    expect(reader.add(Uint8List.sublistView(event, 16)).single.params, [
      1,
      2,
      3,
    ]);
  });

  group('rejects', () {
    test('a short transfer inside a container', () {
      final data = _dataContainer(patternBytes(2000));
      final reader = UsbContainerReader();
      expect(reader.add(Uint8List.sublistView(data, 0, 512)), isEmpty);
      expect(
        () => reader.add(Uint8List.sublistView(data, 512, 612)),
        throwsA(isA<PtpProtocolException>()),
      );
    });

    test('a zero-length packet inside a container', () {
      final data = _dataContainer(patternBytes(2000));
      final reader = UsbContainerReader();
      expect(reader.add(Uint8List.sublistView(data, 0, 1024)), isEmpty);
      expect(
        () => reader.add(Uint8List(0)),
        throwsA(isA<PtpProtocolException>()),
      );
    });

    test('data larger than the limit', () {
      final header = ByteData(usbContainerHeaderSize)
        ..setUint32(0, 1000 + usbContainerHeaderSize + 1, Endian.little)
        ..setUint16(4, UsbContainerType.data.code, Endian.little);
      expect(
        () =>
            UsbContainerReader(maxDataLength: 1000)
                .add(header.buffer.asUint8List()),
        throwsA(isA<PtpProtocolException>()),
      );
    });

    test('an unknown length that grows past the limit', () {
      final reader = UsbContainerReader(maxDataLength: 1000);
      reader.add(_concat([_unknownLengthHeader(), Uint8List(500)]));
      expect(
        () => reader.add(Uint8List(512)),
        throwsA(isA<PtpProtocolException>()),
      );
    });

    test('a length shorter than the header', () {
      final header = ByteData(usbContainerHeaderSize)
        ..setUint32(0, 4, Endian.little)
        ..setUint16(4, UsbContainerType.response.code, Endian.little);
      expect(
        () => UsbContainerReader().add(header.buffer.asUint8List()),
        throwsA(isA<PtpProtocolException>()),
      );
    });

    test('an unknown container type', () {
      final header = ByteData(usbContainerHeaderSize)
        ..setUint32(0, usbContainerHeaderSize, Endian.little)
        ..setUint16(4, 9, Endian.little);
      expect(
        () => UsbContainerReader().add(header.buffer.asUint8List()),
        throwsA(isA<PtpProtocolException>()),
      );
    });
  });
}
