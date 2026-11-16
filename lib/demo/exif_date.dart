import 'dart:math';
import 'dart:typed_data';

/// Enough of a JPEG for its EXIF: APP1 is at most 64 KiB and comes early.
const exifReadCap = 128 * 1024;

const _markerPrefix = 0xFF;
const _startOfImage = 0xD8;
const _startOfScan = 0xDA;
const _app1 = 0xE1;
const _markerLength = 2;
const _segmentHeaderLength = 4;
const _exifSignature = [0x45, 0x78, 0x69, 0x66, 0, 0];
const _littleEndianMark = 0x4949;
const _bigEndianMark = 0x4D4D;
const _tiffMagic = 42;
const _tiffHeaderLength = 8;
const _magicOffset = 2;
const _firstIfdOffset = 4;
const _ifdCountLength = 2;
const _ifdEntryLength = 12;
const _entryValueOffset = 8;
const _dateTimeTag = 0x0132;
const _exifIfdTag = 0x8769;
const _dateTimeOriginalTag = 0x9003;
const _dateLength = 19;
final _datePattern = RegExp(
  r'^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})$',
);

/// When the JPEG starting in [bytes] was shot, from its EXIF: the original
/// date, else the date it was last changed. Null without either.
DateTime? exifCaptureDate(Uint8List bytes) {
  if (bytes.length < _markerLength ||
      bytes[0] != _markerPrefix ||
      bytes[1] != _startOfImage) {
    return null;
  }
  final data = ByteData.sublistView(bytes);
  var position = _markerLength;
  while (position + _segmentHeaderLength <= bytes.length) {
    final marker = bytes[position + 1];
    if (bytes[position] != _markerPrefix || marker == _startOfScan) {
      return null;
    }
    final start = position + _segmentHeaderLength;
    final end = position + _markerLength + data.getUint16(position + 2);
    if (marker == _app1 && _matches(bytes, start, _exifSignature)) {
      return _tiffDate(
        Uint8List.sublistView(
          bytes,
          min(start + _exifSignature.length, bytes.length),
          min(end, bytes.length),
        ),
      );
    }
    position = end;
  }
  return null;
}

DateTime? _tiffDate(Uint8List tiff) {
  if (tiff.length < _tiffHeaderLength) return null;
  final data = ByteData.sublistView(tiff);
  final endian = switch (data.getUint16(0)) {
    _littleEndianMark => Endian.little,
    _bigEndianMark => Endian.big,
    _ => null,
  };
  if (endian == null || data.getUint16(_magicOffset, endian) != _tiffMagic) {
    return null;
  }
  final ifd0 = _entries(data, data.getUint32(_firstIfdOffset, endian), endian);
  final exifIfd = ifd0[_exifIfdTag];
  final exif = exifIfd == null
      ? const <int, int>{}
      : _entries(data, exifIfd, endian);
  return _date(tiff, exif[_dateTimeOriginalTag]) ??
      _date(tiff, ifd0[_dateTimeTag]);
}

/// The value field of every entry in the IFD at [offset], by tag.
Map<int, int> _entries(ByteData data, int offset, Endian endian) {
  if (offset + _ifdCountLength > data.lengthInBytes) return const {};
  final entries = <int, int>{};
  final count = data.getUint16(offset, endian);
  for (var index = 0; index < count; index++) {
    final entry = offset + _ifdCountLength + index * _ifdEntryLength;
    if (entry + _ifdEntryLength > data.lengthInBytes) break;
    entries[data.getUint16(entry, endian)] = data.getUint32(
      entry + _entryValueOffset,
      endian,
    );
  }
  return entries;
}

DateTime? _date(Uint8List tiff, int? offset) {
  if (offset == null || offset + _dateLength > tiff.length) return null;
  final match = _datePattern.firstMatch(
    String.fromCharCodes(tiff, offset, offset + _dateLength),
  );
  if (match == null) return null;
  final [year, month, day, hour, minute, second] = [
    for (var group = 1; group <= match.groupCount; group++)
      int.parse(match[group]!),
  ];
  if (month == 0 || day == 0) return null;
  return DateTime(year, month, day, hour, minute, second);
}

bool _matches(Uint8List bytes, int offset, List<int> expected) {
  if (offset + expected.length > bytes.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (bytes[offset + i] != expected[i]) return false;
  }
  return true;
}
