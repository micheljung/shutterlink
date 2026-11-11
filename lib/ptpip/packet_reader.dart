import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'packet.dart';

const ptpIpMaxPacketLength = 64 * 1024 * 1024;

class PtpIpFrameReader extends StreamTransformerBase<Uint8List, Uint8List> {
  const PtpIpFrameReader();

  @override
  Stream<Uint8List> bind(Stream<Uint8List> stream) {
    return Stream.eventTransformed(stream, _FrameSink.new);
  }
}

class _FrameSink implements EventSink<Uint8List> {
  _FrameSink(this._out);

  final EventSink<Uint8List> _out;
  final _pending = <Uint8List>[];
  int _pendingLength = 0;
  Uint8List? _frame;
  int _frameFilled = 0;

  @override
  void add(Uint8List event) {
    var chunk = event;
    while (chunk.isNotEmpty) {
      final frame = _frame;
      if (frame != null) {
        final take = min(frame.length - _frameFilled, chunk.length);
        frame.setRange(_frameFilled, _frameFilled + take, chunk);
        _frameFilled += take;
        chunk = Uint8List.sublistView(chunk, take);
        if (_frameFilled == frame.length) {
          _frame = null;
          _out.add(frame);
        }
        continue;
      }
      if (_pendingLength + chunk.length < ptpIpHeaderSize) {
        _pending.add(chunk);
        _pendingLength += chunk.length;
        return;
      }
      final Uint8List head;
      if (_pending.isEmpty) {
        head = chunk;
      } else {
        final builder = BytesBuilder(copy: false);
        _pending.forEach(builder.add);
        builder.add(chunk);
        head = builder.takeBytes();
        _pending.clear();
        _pendingLength = 0;
      }
      final length = ByteData.sublistView(head).getUint32(0, Endian.little);
      if (length < ptpIpHeaderSize || length > ptpIpMaxPacketLength) {
        _out.addError(FormatException('Invalid PTP/IP packet length $length'));
        _out.close();
        return;
      }
      if (head.length >= length) {
        _out.add(Uint8List.sublistView(head, 0, length));
        chunk = Uint8List.sublistView(head, length);
      } else {
        final newFrame = Uint8List(length)..setRange(0, head.length, head);
        _frame = newFrame;
        _frameFilled = head.length;
        chunk = Uint8List(0);
      }
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _out.addError(error, stackTrace);

  @override
  void close() => _out.close();
}

class PtpIpPacketReader extends StreamTransformerBase<Uint8List, PtpIpPacket> {
  const PtpIpPacketReader();

  @override
  Stream<PtpIpPacket> bind(Stream<Uint8List> stream) =>
      stream.transform(const PtpIpFrameReader()).map(PtpIpPacket.decode);
}
