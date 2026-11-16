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
const _orientationTag = 0x0112;
const _firstOrientation = 1;
const _lastOrientation = 8;
const _quarterTurns = 4;
const _dateLength = 19;
final _datePattern = RegExp(
  r'^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})$',
);

/// When the JPEG starting in [bytes] was shot, from its EXIF: the original
/// date, else the date it was last changed. Null without either.
DateTime? exifCaptureDate(Uint8List bytes) {
  final tiff = _exifTiff(bytes);
  return tiff == null ? null : _tiffDate(tiff);
}

/// The EXIF Orientation of the JPEG starting in [bytes], 1 to 8. Null without
/// EXIF or without the tag.
int? exifOrientation(Uint8List bytes) {
  final tiff = _exifTiff(bytes);
  return tiff == null ? null : tiffOrientation(tiff);
}

/// The Orientation in IFD0 of the TIFF structure [tiff], as EXIF and a CR3's
/// CMT1 box hold it.
int? tiffOrientation(Uint8List tiff) {
  final ifd0 = _Ifd.of(tiff);
  final entry = ifd0?.entries[_orientationTag];
  if (ifd0 == null || entry == null) return null;
  final value = ifd0.data.getUint16(entry + _entryValueOffset, ifd0.endian);
  return value >= _firstOrientation && value <= _lastOrientation ? value : null;
}

/// How many clockwise quarter turns show a photo with EXIF [orientation]
/// upright. Mirrored orientations, which cameras don't write, turn as their
/// unmirrored neighbours.
int quarterTurnsOf(int? orientation) => switch (orientation) {
  3 || 4 => 2,
  5 || 6 => 1,
  7 || 8 => 3,
  _ => 0,
};

/// Clockwise quarter turns that show [bytes] upright, for a photo that
/// needs [photoTurns]: the decoder already applies the image's own EXIF
/// orientation.
int extraQuarterTurns(int photoTurns, Uint8List bytes) =>
    (photoTurns - quarterTurnsOf(exifOrientation(bytes))) % _quarterTurns;

/// The TIFF structure in the EXIF APP1 segment of the JPEG in [bytes].
Uint8List? _exifTiff(Uint8List bytes) {
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
      if (end < start + _exifSignature.length) return null;
      return Uint8List.sublistView(
        bytes,
        min(start + _exifSignature.length, bytes.length),
        min(end, bytes.length),
      );
    }
    position = end;
  }
  return null;
}

class _Ifd {
  _Ifd(this.data, this.endian, this.entries);

  static _Ifd? of(Uint8List tiff) {
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
    final offset = data.getUint32(_firstIfdOffset, endian);
    return _Ifd(data, endian, _entries(data, offset, endian));
  }

  final ByteData data;
  final Endian endian;

  /// The offset of each entry, by tag.
  final Map<int, int> entries;

  /// The value field of the entry for [tag] as a LONG, such as an offset.
  int? long(int tag) {
    final entry = entries[tag];
    return entry == null
        ? null
        : data.getUint32(entry + _entryValueOffset, endian);
  }
}

DateTime? _tiffDate(Uint8List tiff) {
  final ifd0 = _Ifd.of(tiff);
  if (ifd0 == null) return null;
  final exifIfd = ifd0.long(_exifIfdTag);
  final exif = exifIfd == null
      ? null
      : _Ifd(ifd0.data, ifd0.endian, _entries(ifd0.data, exifIfd, ifd0.endian));
  return _date(tiff, exif?.long(_dateTimeOriginalTag)) ??
      _date(tiff, ifd0.long(_dateTimeTag));
}

/// The offset of every entry in the IFD at [offset], by tag.
Map<int, int> _entries(ByteData data, int offset, Endian endian) {
  if (offset + _ifdCountLength > data.lengthInBytes) return const {};
  final entries = <int, int>{};
  final count = data.getUint16(offset, endian);
  for (var index = 0; index < count; index++) {
    final entry = offset + _ifdCountLength + index * _ifdEntryLength;
    if (entry + _ifdEntryLength > data.lengthInBytes) break;
    entries[data.getUint16(entry, endian)] = entry;
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
