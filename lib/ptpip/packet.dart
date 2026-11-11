import 'dart:math';
import 'dart:typed_data';

import 'dataset.dart';

abstract final class PtpIpPacketType {
  static const initCommandRequest = 1;
  static const initCommandAck = 2;
  static const initEventRequest = 3;
  static const initEventAck = 4;
  static const initFail = 5;
  static const commandRequest = 6;
  static const commandResponse = 7;
  static const event = 8;
  static const startData = 9;
  static const data = 10;
  static const cancel = 11;
  static const endData = 12;
  static const ping = 13;
  static const pong = 14;
}

abstract final class PtpIpInitFailReason {
  static const rejectedInitiator = 1;
  static const busy = 2;
  static const unspecified = 3;
}

abstract final class PtpIpVersion {
  static const major = 1;
  static const minor = 0;
}

enum PtpDataPhase {
  noneOrDataIn(1),
  dataOut(2);

  const PtpDataPhase(this.code);

  final int code;

  static PtpDataPhase fromCode(int code) =>
      code == dataOut.code ? dataOut : noneOrDataIn;
}

const ptpIpHeaderSize = 8;
const ptpIpGuidSize = 16;
const ptpMaxParameters = 5;
const _u16 = 2;
const _u32 = 4;
const _startDataReserved = 0;

sealed class PtpIpPacket {
  const PtpIpPacket();

  int get type;

  void _writeBody(PtpDataWriter writer);

  Uint8List encode() {
    final writer = PtpDataWriter()
      ..u32(0)
      ..u32(type);
    _writeBody(writer);
    final bytes = writer.toBytes();
    ByteData.sublistView(bytes).setUint32(0, bytes.length, Endian.little);
    return bytes;
  }

  static PtpIpPacket decode(Uint8List frame) {
    if (frame.length < ptpIpHeaderSize) {
      throw FormatException('PTP/IP frame too short: ${frame.length}');
    }
    final header = ByteData.sublistView(frame);
    final length = header.getUint32(0, Endian.little);
    if (length != frame.length) {
      throw FormatException(
        'PTP/IP length $length does not match frame ${frame.length}',
      );
    }
    final type = header.getUint32(_u32, Endian.little);
    final r = PtpDataReader(Uint8List.sublistView(frame, ptpIpHeaderSize));
    return switch (type) {
      PtpIpPacketType.initCommandRequest => InitCommandRequest(
        guid: r.bytes(ptpIpGuidSize),
        name: r.utf16z(),
        minorVersion: r.u16(),
        majorVersion: r.u16(),
      ),
      PtpIpPacketType.initCommandAck => InitCommandAck(
        connectionNumber: r.u32(),
        guid: r.bytes(ptpIpGuidSize),
        name: r.utf16z(),
        minorVersion: r.remaining >= _u16 ? r.u16() : PtpIpVersion.minor,
        majorVersion: r.remaining >= _u16 ? r.u16() : PtpIpVersion.major,
      ),
      PtpIpPacketType.initEventRequest => InitEventRequest(r.u32()),
      PtpIpPacketType.initEventAck => const InitEventAck(),
      PtpIpPacketType.initFail => InitFail(r.remaining >= _u32 ? r.u32() : 0),
      PtpIpPacketType.commandRequest => CommandRequest(
        dataPhase: PtpDataPhase.fromCode(r.u32()),
        opcode: r.u16(),
        transactionId: r.u32(),
        params: r.u32List(),
      ),
      PtpIpPacketType.commandResponse => CommandResponse(
        code: r.u16(),
        transactionId: r.u32(),
        params: r.u32List(),
      ),
      PtpIpPacketType.event => EventPacket(
        code: r.u16(),
        transactionId: r.u32(),
        params: r.u32List(),
      ),
      PtpIpPacketType.startData => StartData(
        transactionId: r.u32(),
        totalLength: r.u32(),
      ),
      PtpIpPacketType.data => DataPacket(
        transactionId: r.u32(),
        payload: r.rest(),
      ),
      PtpIpPacketType.endData => EndDataPacket(
        transactionId: r.u32(),
        payload: r.rest(),
      ),
      PtpIpPacketType.cancel => CancelPacket(r.u32()),
      PtpIpPacketType.ping => const PingPacket(),
      PtpIpPacketType.pong => const PongPacket(),
      _ => throw FormatException('Unknown PTP/IP packet type $type'),
    };
  }
}

class InitCommandRequest extends PtpIpPacket {
  InitCommandRequest({
    required this.guid,
    required this.name,
    this.minorVersion = PtpIpVersion.minor,
    this.majorVersion = PtpIpVersion.major,
  }) {
    if (guid.length != ptpIpGuidSize) {
      throw ArgumentError.value(guid, 'guid', 'must be $ptpIpGuidSize bytes');
    }
  }

  final Uint8List guid;
  final String name;
  final int minorVersion;
  final int majorVersion;

  @override
  int get type => PtpIpPacketType.initCommandRequest;

  @override
  void _writeBody(PtpDataWriter writer) => writer
    ..bytes(guid)
    ..utf16z(name)
    ..u16(minorVersion)
    ..u16(majorVersion);
}

class InitCommandAck extends PtpIpPacket {
  const InitCommandAck({
    required this.connectionNumber,
    required this.guid,
    required this.name,
    this.minorVersion = PtpIpVersion.minor,
    this.majorVersion = PtpIpVersion.major,
  });

  final int connectionNumber;
  final Uint8List guid;
  final String name;
  final int minorVersion;
  final int majorVersion;

  @override
  int get type => PtpIpPacketType.initCommandAck;

  @override
  void _writeBody(PtpDataWriter writer) => writer
    ..u32(connectionNumber)
    ..bytes(guid)
    ..utf16z(name)
    ..u16(minorVersion)
    ..u16(majorVersion);
}

class InitEventRequest extends PtpIpPacket {
  const InitEventRequest(this.connectionNumber);

  final int connectionNumber;

  @override
  int get type => PtpIpPacketType.initEventRequest;

  @override
  void _writeBody(PtpDataWriter writer) => writer.u32(connectionNumber);
}

class InitEventAck extends PtpIpPacket {
  const InitEventAck();

  @override
  int get type => PtpIpPacketType.initEventAck;

  @override
  void _writeBody(PtpDataWriter writer) {}
}

class InitFail extends PtpIpPacket {
  const InitFail(this.reason);

  final int reason;

  @override
  int get type => PtpIpPacketType.initFail;

  @override
  void _writeBody(PtpDataWriter writer) => writer.u32(reason);
}

class CommandRequest extends PtpIpPacket {
  CommandRequest({
    this.dataPhase = PtpDataPhase.noneOrDataIn,
    required this.opcode,
    required this.transactionId,
    this.params = const [],
  }) {
    if (params.length > ptpMaxParameters) {
      throw ArgumentError.value(params, 'params', 'at most $ptpMaxParameters');
    }
  }

  final PtpDataPhase dataPhase;
  final int opcode;
  final int transactionId;
  final List<int> params;

  @override
  int get type => PtpIpPacketType.commandRequest;

  @override
  void _writeBody(PtpDataWriter writer) {
    writer
      ..u32(dataPhase.code)
      ..u16(opcode)
      ..u32(transactionId);
    params.forEach(writer.u32);
  }
}

class CommandResponse extends PtpIpPacket {
  const CommandResponse({
    required this.code,
    required this.transactionId,
    this.params = const [],
  });

  final int code;
  final int transactionId;
  final List<int> params;

  @override
  int get type => PtpIpPacketType.commandResponse;

  @override
  void _writeBody(PtpDataWriter writer) {
    writer
      ..u16(code)
      ..u32(transactionId);
    params.forEach(writer.u32);
  }
}

class EventPacket extends PtpIpPacket {
  const EventPacket({
    required this.code,
    required this.transactionId,
    this.params = const [],
  });

  final int code;
  final int transactionId;
  final List<int> params;

  @override
  int get type => PtpIpPacketType.event;

  @override
  void _writeBody(PtpDataWriter writer) {
    writer
      ..u16(code)
      ..u32(transactionId);
    params.forEach(writer.u32);
  }
}

class StartData extends PtpIpPacket {
  const StartData({required this.transactionId, required this.totalLength});

  final int transactionId;
  final int totalLength;

  @override
  int get type => PtpIpPacketType.startData;

  @override
  void _writeBody(PtpDataWriter writer) => writer
    ..u32(transactionId)
    ..u32(totalLength)
    ..u32(_startDataReserved);
}

class DataPacket extends PtpIpPacket {
  const DataPacket({required this.transactionId, required this.payload});

  final int transactionId;
  final Uint8List payload;

  @override
  int get type => PtpIpPacketType.data;

  @override
  void _writeBody(PtpDataWriter writer) => writer
    ..u32(transactionId)
    ..bytes(payload);
}

class EndDataPacket extends PtpIpPacket {
  const EndDataPacket({required this.transactionId, required this.payload});

  final int transactionId;
  final Uint8List payload;

  @override
  int get type => PtpIpPacketType.endData;

  @override
  void _writeBody(PtpDataWriter writer) => writer
    ..u32(transactionId)
    ..bytes(payload);
}

class CancelPacket extends PtpIpPacket {
  const CancelPacket(this.transactionId);

  final int transactionId;

  @override
  int get type => PtpIpPacketType.cancel;

  @override
  void _writeBody(PtpDataWriter writer) => writer.u32(transactionId);
}

class PingPacket extends PtpIpPacket {
  const PingPacket();

  @override
  int get type => PtpIpPacketType.ping;

  @override
  void _writeBody(PtpDataWriter writer) {}
}

class PongPacket extends PtpIpPacket {
  const PongPacket();

  @override
  int get type => PtpIpPacketType.pong;

  @override
  void _writeBody(PtpDataWriter writer) {}
}

extension on PtpDataWriter {
  void utf16z(String value) {
    value.codeUnits.forEach(u16);
    u16(0);
  }
}

extension on PtpDataReader {
  List<int> u32List() {
    final params = <int>[];
    while (remaining >= _u32 && params.length < ptpMaxParameters) {
      params.add(u32());
    }
    return List.unmodifiable(params);
  }

  String utf16z() {
    final units = <int>[];
    while (remaining >= _u16) {
      final unit = u16();
      if (unit == 0) {
        break;
      }
      units.add(unit);
    }
    return String.fromCharCodes(units);
  }
}

String hexDump(Uint8List bytes) {
  const bytesPerLine = 16;
  const offsetWidth = 8;
  final buffer = StringBuffer();
  for (var line = 0; line < bytes.length; line += bytesPerLine) {
    final end = min(line + bytesPerLine, bytes.length);
    final slice = Uint8List.sublistView(bytes, line, end);
    buffer
      ..write(line.toRadixString(16).padLeft(offsetWidth, '0'))
      ..write('  ')
      ..write(slice.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' '))
      ..writeln();
  }
  return buffer.toString();
}

String describePacketType(int type) => switch (type) {
  PtpIpPacketType.initCommandRequest => 'InitCommandRequest',
  PtpIpPacketType.initCommandAck => 'InitCommandAck',
  PtpIpPacketType.initEventRequest => 'InitEventRequest',
  PtpIpPacketType.initEventAck => 'InitEventAck',
  PtpIpPacketType.initFail => 'InitFail',
  PtpIpPacketType.commandRequest => 'CommandRequest',
  PtpIpPacketType.commandResponse => 'CommandResponse',
  PtpIpPacketType.event => 'Event',
  PtpIpPacketType.startData => 'StartData',
  PtpIpPacketType.data => 'Data',
  PtpIpPacketType.cancel => 'Cancel',
  PtpIpPacketType.endData => 'EndData',
  PtpIpPacketType.ping => 'Ping',
  PtpIpPacketType.pong => 'Pong',
  _ => 'Unknown($type)',
};
