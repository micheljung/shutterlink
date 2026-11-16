import 'dart:typed_data';

import 'exif_jpeg.dart';

const _previewUuidHex = 'eaf42b5e1c984b88b9fbb7dc406e4d16';
const _canonUuidHex = '85c0b687820f11e08111f4ce462b6a48';
final _previewUuid = _uuid(_previewUuidHex);
final _canonUuid = _uuid(_canonUuidHex);

List<int> _uuid(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

final fakePreviewJpeg = [0xFF, 0xD8, 1, 2, 3, 4, 0xFF, 0xD9];

Uint8List _uint16(int value) =>
    (ByteData(2)..setUint16(0, value)).buffer.asUint8List();

Uint8List _uint32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

List<int> _box(String type, List<int> payload) => [
  ..._uint32(8 + payload.length),
  ...type.codeUnits,
  ...payload,
];

List<int> _largeBox(String type, List<int> payload) => [
  ..._uint32(1),
  ...type.codeUnits,
  ...(ByteData(8)..setUint64(0, 16 + payload.length)).buffer.asUint8List(),
  ...payload,
];

/// A CR3 with a PRVW preview, and, given an [orientation], Canon's metadata
/// box in `moov` with that Orientation in CMT1.
Uint8List fakeCr3({
  int moovPadding = 0,
  bool largeMoov = false,
  int mdatLength = 0,
  int? orientation,
}) {
  final preview = _box('PRVW', [
    ..._uint32(0),
    ..._uint16(1),
    ..._uint16(160),
    ..._uint16(120),
    ..._uint16(1),
    ..._uint32(fakePreviewJpeg.length),
    ...fakePreviewJpeg,
  ]);
  final moov = [
    if (orientation != null)
      ..._box('uuid', [
        ..._canonUuid,
        ..._box('CNCV', 'CanonCR3_001/00.09.00/00.00.00'.codeUnits),
        ..._box(
          'CMT1',
          exifTiff(endian: Endian.little, orientation: orientation),
        ),
      ]),
    ...List.filled(moovPadding, 0),
  ];
  return Uint8List.fromList([
    ..._box('ftyp', 'crx '.codeUnits),
    ...(largeMoov ? _largeBox('moov', moov) : _box('moov', moov)),
    ..._box('uuid', [..._previewUuid, ...List.filled(8, 0), ...preview]),
    ..._box('mdat', List.filled(mdatLength, 0)),
  ]);
}
