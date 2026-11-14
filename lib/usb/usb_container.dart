import 'dart:math' show min;
import 'dart:typed_data';

import '../ptp/ptp_protocol_exception.dart';
import '../ptp/ptp_transport.dart';

const usbContainerHeaderSize = 12;

/// A container length the sender did not know; the transfer's short packet
/// ends it.
const usbUnknownContainerLength = 0xFFFFFFFF;

enum UsbContainerType {
  command(1),
  data(2),
  response(3),
  event(4);

  const UsbContainerType(this.code);

  final int code;

  static UsbContainerType? fromCode(int code) {
    for (final type in values) {
      if (type.code == code) {
        return type;
      }
    }
    return null;
  }
}

/// One PTP-over-USB container: a 12-byte header and its payload, which is
/// the data for [UsbContainerType.data] and u32 parameters otherwise.
class UsbContainer {
  UsbContainer({
    required this.type,
    required this.code,
    required this.transactionId,
    Uint8List? payload,
  }) : payload = payload ?? Uint8List(0);

  factory UsbContainer.withParams(
    UsbContainerType type,
    int code,
    int transactionId, [
    List<int> params = const [],
  ]) {
    final payload = ByteData(params.length * 4);
    for (var i = 0; i < params.length; i++) {
      payload.setUint32(i * 4, params[i], Endian.little);
    }
    return UsbContainer(
      type: type,
      code: code,
      transactionId: transactionId,
      payload: payload.buffer.asUint8List(),
    );
  }

  final UsbContainerType type;
  final int code;
  final int transactionId;
  final Uint8List payload;

  /// The payload read as u32 parameters; trailing bytes are ignored.
  List<int> get params {
    final view = ByteData.sublistView(payload);
    return [
      for (var at = 0; at + 4 <= payload.length; at += 4)
        view.getUint32(at, Endian.little),
    ];
  }

  Uint8List encode() {
    final length = usbContainerHeaderSize + payload.length;
    final bytes = Uint8List(length);
    ByteData.sublistView(bytes)
      ..setUint32(0, length, Endian.little)
      ..setUint16(4, type.code, Endian.little)
      ..setUint16(6, code, Endian.little)
      ..setUint32(8, transactionId, Endian.little);
    bytes.setRange(usbContainerHeaderSize, length, payload);
    return bytes;
  }
}

/// Reassembles containers from bulk-in transfers. A transfer may end inside
/// a container or carry the start of the next one. A container of unknown
/// length ends with the first short transfer.
class UsbContainerReader {
  UsbContainerReader({
    this.maxPacketSize = 512,
    this.maxDataLength = ptpMaxDataInLength,
  });

  final int maxPacketSize;
  final int maxDataLength;

  final _header = Uint8List(usbContainerHeaderSize);
  int _headerFilled = 0;
  Uint8List? _payload;
  int _payloadFilled = 0;
  BytesBuilder? _unknownLength;

  /// Feeds one whole transfer (empty for a zero-length packet) and returns
  /// the containers it completed. Throws [PtpProtocolException] for a
  /// malformed or oversized container.
  List<UsbContainer> add(Uint8List transfer) {
    final done = <UsbContainer>[];
    var at = 0;
    while (at < transfer.length) {
      final unknown = _unknownLength;
      if (unknown != null) {
        unknown.add(Uint8List.sublistView(transfer, at));
        at = transfer.length;
        if (unknown.length > maxDataLength) {
          throw PtpProtocolException('Container too large: ${unknown.length}');
        }
      } else if (_headerFilled < usbContainerHeaderSize) {
        final take = min(
          usbContainerHeaderSize - _headerFilled,
          transfer.length - at,
        );
        _header.setRange(_headerFilled, _headerFilled + take, transfer, at);
        _headerFilled += take;
        at += take;
        if (_headerFilled == usbContainerHeaderSize) {
          _startPayload(done);
        }
      } else {
        final payload = _payload!;
        final take = min(payload.length - _payloadFilled, transfer.length - at);
        payload.setRange(_payloadFilled, _payloadFilled + take, transfer, at);
        _payloadFilled += take;
        at += take;
        if (_payloadFilled == payload.length) {
          done.add(_finish(payload));
        }
      }
    }
    final unknown = _unknownLength;
    if (unknown != null &&
        (transfer.isEmpty || transfer.length % maxPacketSize != 0)) {
      done.add(_finish(unknown.takeBytes()));
    }
    return done;
  }

  void _startPayload(List<UsbContainer> done) {
    final length = ByteData.sublistView(_header).getUint32(0, Endian.little);
    if (UsbContainerType.fromCode(_headerU16(4)) == null) {
      throw PtpProtocolException('Unknown container type ${_headerU16(4)}');
    }
    if (length == usbUnknownContainerLength) {
      _unknownLength = BytesBuilder(copy: true);
      return;
    }
    if (length < usbContainerHeaderSize) {
      throw PtpProtocolException('Container length $length');
    }
    final payloadLength = length - usbContainerHeaderSize;
    if (payloadLength > maxDataLength) {
      throw PtpProtocolException('Container too large: $payloadLength');
    }
    _payload = Uint8List(payloadLength);
    _payloadFilled = 0;
    if (payloadLength == 0) {
      done.add(_finish(_payload!));
    }
  }

  UsbContainer _finish(Uint8List payload) {
    final container = UsbContainer(
      type: UsbContainerType.fromCode(_headerU16(4))!,
      code: _headerU16(6),
      transactionId: ByteData.sublistView(_header).getUint32(8, Endian.little),
      payload: payload,
    );
    _headerFilled = 0;
    _payload = null;
    _payloadFilled = 0;
    _unknownLength = null;
    return container;
  }

  int _headerU16(int at) =>
      ByteData.sublistView(_header).getUint16(at, Endian.little);
}
