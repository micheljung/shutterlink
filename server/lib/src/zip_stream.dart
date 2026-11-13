import 'dart:convert';
import 'dart:typed_data';

const int _localHeaderSignature = 0x04034b50;
const int _dataDescriptorSignature = 0x08074b50;
const int _centralHeaderSignature = 0x02014b50;
const int _endOfCentralDirectorySignature = 0x06054b50;
const int _versionNeeded = 20;
const int _versionMadeBy = 20;
const int _flagDataDescriptor = 1 << 3;
const int _flagUtf8Names = 1 << 11;
const int _methodStore = 0;
const int _max32 = 0xFFFFFFFF;
const int _maxEntries = 0xFFFF;
const int _localHeaderLength = 30;
const int _dataDescriptorLength = 16;
const int _centralHeaderLength = 46;
const int _endOfCentralDirectoryLength = 22;
const int _dosEpochYear = 1980;
const int _crcPolynomial = 0xEDB88320;
const int _byteValues = 256;
const int _bitsPerByte = 8;

class ZipEntry {
  const ZipEntry(this.name, this.modified, this.open);

  final String name;
  final DateTime modified;
  final Stream<List<int>> Function() open;
}

final Uint32List _crcTable = () {
  final table = Uint32List(_byteValues);
  for (var n = 0; n < _byteValues; n++) {
    var c = n;
    for (var k = 0; k < _bitsPerByte; k++) {
      c = (c & 1) != 0 ? _crcPolynomial ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

int _updateCrc(int crc, List<int> bytes) {
  var c = crc ^ _max32;
  for (final byte in bytes) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> _bitsPerByte);
  }
  return c ^ _max32;
}

int crc32(List<int> bytes) => _updateCrc(0, bytes);

class _Written {
  _Written(this.name, this.time, this.date, this.offset);

  final List<int> name;
  final int time;
  final int date;
  final int offset;
  int crc = 0;
  int size = 0;
}

Stream<List<int>> storeZip(List<ZipEntry> entries) async* {
  if (entries.length > _maxEntries) {
    throw ArgumentError.value(entries.length, 'entries', 'too many');
  }
  final written = <_Written>[];
  var offset = 0;
  for (final entry in entries) {
    final utc = entry.modified.toUtc();
    final record = _Written(
      utf8.encode(entry.name),
      _dosTime(utc),
      _dosDate(utc),
      offset,
    );
    final header = _localHeader(record);
    yield header;
    offset += header.length;
    await for (final chunk in entry.open()) {
      record.crc = _updateCrc(record.crc, chunk);
      record.size += chunk.length;
      yield chunk;
    }
    _check32(record.size);
    offset += record.size;
    final descriptor = _dataDescriptor(record);
    yield descriptor;
    offset += descriptor.length;
    _check32(offset);
    written.add(record);
  }
  final centralStart = offset;
  var centralSize = 0;
  for (final record in written) {
    final header = _centralHeader(record);
    yield header;
    centralSize += header.length;
  }
  _check32(centralStart + centralSize);
  yield _endOfCentralDirectory(written.length, centralSize, centralStart);
}

void _check32(int value) {
  if (value > _max32) throw StateError('ZIP64 is not supported');
}

int _dosTime(DateTime t) => (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2);

int _dosDate(DateTime t) =>
    ((t.year - _dosEpochYear) << 9) | (t.month << 5) | t.day;

Uint8List _localHeader(_Written record) {
  final data = ByteData(_localHeaderLength + record.name.length)
    ..setUint32(0, _localHeaderSignature, Endian.little)
    ..setUint16(4, _versionNeeded, Endian.little)
    ..setUint16(6, _flagDataDescriptor | _flagUtf8Names, Endian.little)
    ..setUint16(8, _methodStore, Endian.little)
    ..setUint16(10, record.time, Endian.little)
    ..setUint16(12, record.date, Endian.little)
    ..setUint16(26, record.name.length, Endian.little);
  final bytes = data.buffer.asUint8List();
  bytes.setAll(_localHeaderLength, record.name);
  return bytes;
}

Uint8List _dataDescriptor(_Written record) {
  final data = ByteData(_dataDescriptorLength)
    ..setUint32(0, _dataDescriptorSignature, Endian.little)
    ..setUint32(4, record.crc, Endian.little)
    ..setUint32(8, record.size, Endian.little)
    ..setUint32(12, record.size, Endian.little);
  return data.buffer.asUint8List();
}

Uint8List _centralHeader(_Written record) {
  final data = ByteData(_centralHeaderLength + record.name.length)
    ..setUint32(0, _centralHeaderSignature, Endian.little)
    ..setUint16(4, _versionMadeBy, Endian.little)
    ..setUint16(6, _versionNeeded, Endian.little)
    ..setUint16(8, _flagDataDescriptor | _flagUtf8Names, Endian.little)
    ..setUint16(10, _methodStore, Endian.little)
    ..setUint16(12, record.time, Endian.little)
    ..setUint16(14, record.date, Endian.little)
    ..setUint32(16, record.crc, Endian.little)
    ..setUint32(20, record.size, Endian.little)
    ..setUint32(24, record.size, Endian.little)
    ..setUint16(28, record.name.length, Endian.little)
    ..setUint32(42, record.offset, Endian.little);
  final bytes = data.buffer.asUint8List();
  bytes.setAll(_centralHeaderLength, record.name);
  return bytes;
}

Uint8List _endOfCentralDirectory(int count, int size, int offset) {
  final data = ByteData(_endOfCentralDirectoryLength)
    ..setUint32(0, _endOfCentralDirectorySignature, Endian.little)
    ..setUint16(8, count, Endian.little)
    ..setUint16(10, count, Endian.little)
    ..setUint32(12, size, Endian.little)
    ..setUint32(16, offset, Endian.little);
  return data.buffer.asUint8List();
}
