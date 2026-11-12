import 'dart:typed_data';

const _previewUuidHex = 'eaf42b5e1c984b88b9fbb7dc406e4d16';
final _previewUuid = [
  for (var i = 0; i < _previewUuidHex.length; i += 2)
    int.parse(_previewUuidHex.substring(i, i + 2), radix: 16),
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

Uint8List fakeCr3({
  int moovPadding = 0,
  bool largeMoov = false,
  int mdatLength = 0,
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
  final moov = List.filled(moovPadding, 0);
  return Uint8List.fromList([
    ..._box('ftyp', 'crx '.codeUnits),
    ...(largeMoov ? _largeBox('moov', moov) : _box('moov', moov)),
    ..._box('uuid', [..._previewUuid, ...List.filled(8, 0), ...preview]),
    ..._box('mdat', List.filled(mdatLength, 0)),
  ]);
}
