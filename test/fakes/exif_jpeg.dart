import 'dart:typed_data';

const _dateTime = 0x0132;
const _exifIfd = 0x8769;
const _dateTimeOriginal = 0x9003;
const _ascii = 2;
const _long = 4;
const _dateCount = 20;
const jfifSegment = [
  0xFF,
  0xE0,
  0,
  16,
  0x4A,
  0x46,
  0x49,
  0x46,
  0,
  1,
  1,
  0,
  0,
  1,
  0,
  1,
  0,
  0,
];
const scanToEnd = [0xFF, 0xDA, 0, 2, 0xFF, 0xD9];

/// A JPEG whose APP1 holds IFD0, with [dateTime], and an Exif IFD, with
/// [original], in [endian] byte order.
Uint8List exifJpeg({
  Endian endian = Endian.big,
  String? dateTime,
  String? original,
}) {
  const headerLength = 8;
  const entryLength = 12;
  int ifdLength(int entries) => 2 + entries * entryLength + 4;
  final ifd0Count = [dateTime, original].nonNulls.length;
  const ifd0Offset = headerLength;
  final exifOffset = ifd0Offset + ifdLength(ifd0Count);
  var strings = exifOffset + ifdLength(original == null ? 0 : 1);
  final tiff = ByteData(strings + 2 * _dateCount);
  tiff
    ..setUint16(0, endian == Endian.little ? 0x4949 : 0x4D4D)
    ..setUint16(2, 42, endian)
    ..setUint32(4, ifd0Offset, endian);
  int string(String text) {
    final at = strings;
    for (final (index, unit) in text.codeUnits.indexed) {
      tiff.setUint8(at + index, unit);
    }
    strings += _dateCount;
    return at;
  }

  void ifd(int offset, Map<int, (int, int, int)> entries) {
    tiff.setUint16(offset, entries.length, endian);
    var entry = offset + 2;
    for (final MapEntry(key: tag, value: (type, count, value))
        in entries.entries) {
      tiff
        ..setUint16(entry, tag, endian)
        ..setUint16(entry + 2, type, endian)
        ..setUint32(entry + 4, count, endian)
        ..setUint32(entry + 8, value, endian);
      entry += entryLength;
    }
  }

  ifd(ifd0Offset, {
    if (dateTime != null) _dateTime: (_ascii, _dateCount, string(dateTime)),
    if (original != null) _exifIfd: (_long, 1, exifOffset),
  });
  if (original != null) {
    ifd(exifOffset, {
      _dateTimeOriginal: (_ascii, _dateCount, string(original)),
    });
  }
  final app1Length = 2 + 6 + tiff.lengthInBytes;
  return Uint8List.fromList([
    0xFF,
    0xD8,
    ...jfifSegment,
    0xFF,
    0xE1,
    app1Length >> 8,
    app1Length & 0xFF,
    ...'Exif'.codeUnits,
    0,
    0,
    ...tiff.buffer.asUint8List(),
    ...scanToEnd,
  ]);
}
