import 'dart:typed_data';

const _u8 = 1;
const _u16 = 2;
const _u32 = 4;
const _u64 = 8;
const _maxPtpStringChars = 255;

class PtpDataReader {
  PtpDataReader(this._bytes) : _data = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _data;
  int _offset = 0;

  int get remaining => _bytes.length - _offset;

  void _require(int count) {
    if (remaining < count) {
      throw const FormatException('PTP data truncated');
    }
  }

  int u8() {
    _require(_u8);
    return _bytes[_offset++];
  }

  int u16() {
    _require(_u16);
    final value = _data.getUint16(_offset, Endian.little);
    _offset += _u16;
    return value;
  }

  int u32() {
    _require(_u32);
    final value = _data.getUint32(_offset, Endian.little);
    _offset += _u32;
    return value;
  }

  int u64() {
    _require(_u64);
    final value = _data.getUint64(_offset, Endian.little);
    _offset += _u64;
    return value;
  }

  Uint8List bytes(int count) {
    _require(count);
    final value = Uint8List.fromList(
      Uint8List.sublistView(_bytes, _offset, _offset + count),
    );
    _offset += count;
    return value;
  }

  Uint8List rest() {
    final value = Uint8List.sublistView(_bytes, _offset);
    _offset = _bytes.length;
    return value;
  }

  List<int> u16Array() => List.generate(u32(), (_) => u16());

  List<int> u32Array() => List.generate(u32(), (_) => u32());

  String string() {
    final count = u8();
    if (count == 0) {
      return '';
    }
    final units = List.generate(count, (_) => u16());
    if (units.last == 0) {
      units.removeLast();
    }
    return String.fromCharCodes(units);
  }
}

class PtpDataWriter {
  final _builder = BytesBuilder();
  final _scratch = ByteData(_u64);

  void _add(int width) => _builder.add(_scratch.buffer.asUint8List(0, width));

  void u8(int value) => _builder.addByte(value);

  void u16(int value) {
    _scratch.setUint16(0, value, Endian.little);
    _add(_u16);
  }

  void u32(int value) {
    _scratch.setUint32(0, value, Endian.little);
    _add(_u32);
  }

  void u64(int value) {
    _scratch.setUint64(0, value, Endian.little);
    _add(_u64);
  }

  void bytes(Uint8List value) => _builder.add(value);

  void u16Array(List<int> values) {
    u32(values.length);
    values.forEach(u16);
  }

  void u32Array(List<int> values) {
    u32(values.length);
    values.forEach(u32);
  }

  void string(String value) {
    if (value.isEmpty) {
      u8(0);
      return;
    }
    final units = value.codeUnits;
    if (units.length >= _maxPtpStringChars) {
      throw ArgumentError.value(value, 'value', 'too long for a PTP string');
    }
    u8(units.length + 1);
    units.forEach(u16);
    u16(0);
  }

  Uint8List toBytes() => _builder.takeBytes();
}

List<int> parseU32Array(Uint8List bytes) => PtpDataReader(bytes).u32Array();

class PtpDeviceInfo {
  const PtpDeviceInfo({
    required this.standardVersion,
    required this.vendorExtensionId,
    required this.vendorExtensionVersion,
    required this.vendorExtensionDesc,
    required this.functionalMode,
    required this.operationsSupported,
    required this.eventsSupported,
    required this.devicePropertiesSupported,
    required this.captureFormats,
    required this.imageFormats,
    required this.manufacturer,
    required this.model,
    required this.deviceVersion,
    required this.serialNumber,
  });

  factory PtpDeviceInfo.parse(Uint8List bytes) {
    final r = PtpDataReader(bytes);
    return PtpDeviceInfo(
      standardVersion: r.u16(),
      vendorExtensionId: r.u32(),
      vendorExtensionVersion: r.u16(),
      vendorExtensionDesc: r.string(),
      functionalMode: r.u16(),
      operationsSupported: r.u16Array(),
      eventsSupported: r.u16Array(),
      devicePropertiesSupported: r.u16Array(),
      captureFormats: r.u16Array(),
      imageFormats: r.u16Array(),
      manufacturer: r.string(),
      model: r.string(),
      deviceVersion: r.string(),
      serialNumber: r.string(),
    );
  }

  final int standardVersion;
  final int vendorExtensionId;
  final int vendorExtensionVersion;
  final String vendorExtensionDesc;
  final int functionalMode;
  final List<int> operationsSupported;
  final List<int> eventsSupported;
  final List<int> devicePropertiesSupported;
  final List<int> captureFormats;
  final List<int> imageFormats;
  final String manufacturer;
  final String model;
  final String deviceVersion;
  final String serialNumber;

  Uint8List encode() {
    final w = PtpDataWriter()
      ..u16(standardVersion)
      ..u32(vendorExtensionId)
      ..u16(vendorExtensionVersion)
      ..string(vendorExtensionDesc)
      ..u16(functionalMode)
      ..u16Array(operationsSupported)
      ..u16Array(eventsSupported)
      ..u16Array(devicePropertiesSupported)
      ..u16Array(captureFormats)
      ..u16Array(imageFormats)
      ..string(manufacturer)
      ..string(model)
      ..string(deviceVersion)
      ..string(serialNumber);
    return w.toBytes();
  }
}

class PtpObjectInfo {
  const PtpObjectInfo({
    required this.storageId,
    required this.objectFormat,
    this.protectionStatus = 0,
    required this.compressedSize,
    this.thumbFormat = 0,
    this.thumbCompressedSize = 0,
    this.thumbPixWidth = 0,
    this.thumbPixHeight = 0,
    this.imagePixWidth = 0,
    this.imagePixHeight = 0,
    this.imageBitDepth = 0,
    this.parentObject = 0,
    this.associationType = 0,
    this.associationDesc = 0,
    this.sequenceNumber = 0,
    required this.filename,
    this.captureDate = '',
    this.modificationDate = '',
    this.keywords = '',
  });

  factory PtpObjectInfo.parse(Uint8List bytes) {
    final r = PtpDataReader(bytes);
    return PtpObjectInfo(
      storageId: r.u32(),
      objectFormat: r.u16(),
      protectionStatus: r.u16(),
      compressedSize: r.u32(),
      thumbFormat: r.u16(),
      thumbCompressedSize: r.u32(),
      thumbPixWidth: r.u32(),
      thumbPixHeight: r.u32(),
      imagePixWidth: r.u32(),
      imagePixHeight: r.u32(),
      imageBitDepth: r.u32(),
      parentObject: r.u32(),
      associationType: r.u16(),
      associationDesc: r.u32(),
      sequenceNumber: r.u32(),
      filename: r.string(),
      captureDate: r.string(),
      modificationDate: r.string(),
      keywords: r.remaining > 0 ? r.string() : '',
    );
  }

  final int storageId;
  final int objectFormat;
  final int protectionStatus;
  final int compressedSize;
  final int thumbFormat;
  final int thumbCompressedSize;
  final int thumbPixWidth;
  final int thumbPixHeight;
  final int imagePixWidth;
  final int imagePixHeight;
  final int imageBitDepth;
  final int parentObject;
  final int associationType;
  final int associationDesc;
  final int sequenceNumber;
  final String filename;
  final String captureDate;
  final String modificationDate;
  final String keywords;

  Uint8List encode() {
    final w = PtpDataWriter()
      ..u32(storageId)
      ..u16(objectFormat)
      ..u16(protectionStatus)
      ..u32(compressedSize)
      ..u16(thumbFormat)
      ..u32(thumbCompressedSize)
      ..u32(thumbPixWidth)
      ..u32(thumbPixHeight)
      ..u32(imagePixWidth)
      ..u32(imagePixHeight)
      ..u32(imageBitDepth)
      ..u32(parentObject)
      ..u16(associationType)
      ..u32(associationDesc)
      ..u32(sequenceNumber)
      ..string(filename)
      ..string(captureDate)
      ..string(modificationDate)
      ..string(keywords);
    return w.toBytes();
  }
}

final _ptpDateTime = RegExp(
  r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(?:\.(\d))?(Z|[+-]\d{4})?$',
);

const _tenthsToMilliseconds = 100;
const _minutesPerHour = 60;
const _offsetHoursDigits = 2;

DateTime? parsePtpDateTime(String value) {
  final match = _ptpDateTime.firstMatch(value.trim());
  if (match == null) {
    return null;
  }
  int group(int index) => int.parse(match.group(index)!);
  final tenths = match.group(7);
  final local = DateTime(
    group(1),
    group(2),
    group(3),
    group(4),
    group(5),
    group(6),
    tenths == null ? 0 : int.parse(tenths) * _tenthsToMilliseconds,
  );
  final zone = match.group(8);
  if (zone == null) {
    return local;
  }
  final utc = DateTime.utc(
    local.year,
    local.month,
    local.day,
    local.hour,
    local.minute,
    local.second,
    local.millisecond,
  );
  if (zone == 'Z') {
    return utc;
  }
  final sign = zone.startsWith('-') ? -1 : 1;
  final hours = int.parse(zone.substring(1, 1 + _offsetHoursDigits));
  final minutes = int.parse(zone.substring(1 + _offsetHoursDigits));
  return utc.subtract(
    Duration(minutes: sign * (hours * _minutesPerHour + minutes)),
  );
}

String formatPtpDateTime(DateTime value) {
  String two(int v) => v.toString().padLeft(2, '0');
  const yearDigits = 4;
  return '${value.year.toString().padLeft(yearDigits, '0')}'
      '${two(value.month)}${two(value.day)}T'
      '${two(value.hour)}${two(value.minute)}${two(value.second)}';
}
