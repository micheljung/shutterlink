import 'dart:math';
import 'dart:typed_data';

import '../ptp/ptp_camera_client.dart';
import '../ptpip/camera_client.dart';
import 'exif.dart';

const cr3PreviewReadCap = 4 * 1024 * 1024;

typedef ByteRange = ({int offset, int length});

const _boxHeaderLength = 8;
const _largeBoxHeaderLength = 16;
const _sizeToEndOfFile = 0;
const _sizeIsLarge = 1;
const _typeOffset = 4;
const _typeLength = 4;
const _uuidType = 'uuid';
const _previewType = 'PRVW';
const _previewUuidReservedLength = 8;
const _previewJpegLengthOffset = 20;
const _previewJpegOffset = 24;
const _jpegStartOfImage = [0xFF, 0xD8];
const _previewUuid = 'eaf42b5e-1c98-4b88-b9fb-b7dc406e4d16';
const _canonUuid = '85c0b687-820f-11e0-8111-f4ce462b6a48';
const _movieType = 'moov';
const _metadataType = 'CMT1';
const _hexRadix = 16;
final _previewUuidBytes = _uuidBytes(_previewUuid);
final _canonUuidBytes = _uuidBytes(_canonUuid);

List<int> _uuidBytes(String uuid) => [
  for (final pair in RegExp('..').allMatches(uuid.replaceAll('-', '')))
    int.parse(pair[0]!, radix: _hexRadix),
];

typedef _Box = ({String type, int headerLength, int? size});

ByteRange? cr3PreviewRange(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var position = 0;
  while (true) {
    final box = _boxAt(bytes, data, position);
    if (box == null) return null;
    final contentStart = position + box.headerLength;
    if (box.type == _uuidType &&
        _matches(bytes, contentStart, _previewUuidBytes)) {
      final remaining = bytes.length - position;
      return _previewIn(
        bytes,
        data,
        contentStart + _previewUuidBytes.length + _previewUuidReservedLength,
        position + min(box.size ?? remaining, remaining),
      );
    }
    final size = box.size;
    if (size == null || size > bytes.length - position) return null;
    position += size;
  }
}

/// The EXIF Orientation of the CR3 starting in [bytes], from IFD0 in the CMT1
/// box of Canon's `uuid` box in `moov`. Null if [bytes] end before it.
int? cr3Orientation(Uint8List bytes) {
  final movie = _childOf(bytes, 0, bytes.length, _movieType);
  if (movie == null) return null;
  final canon = _childOf(bytes, movie.start, movie.end, _uuidType);
  if (canon == null || !_matches(bytes, canon.start, _canonUuidBytes)) {
    return null;
  }
  final metadata = _childOf(
    bytes,
    canon.start + _canonUuidBytes.length,
    canon.end,
    _metadataType,
  );
  if (metadata == null) return null;
  return tiffOrientation(
    Uint8List.sublistView(bytes, metadata.start, metadata.end),
  );
}

/// The content of the first box of [type] among the boxes from [start] to
/// [end]. Null unless all of it is in [bytes].
({int start, int end})? _childOf(
  Uint8List bytes,
  int start,
  int end,
  String type,
) {
  final data = ByteData.sublistView(bytes);
  var position = start;
  while (position < end) {
    final box = _boxAt(bytes, data, position);
    if (box == null) return null;
    final boxEnd = position + (box.size ?? end - position);
    if (boxEnd > end || boxEnd > bytes.length) return null;
    if (box.type == type) {
      return (start: position + box.headerLength, end: boxEnd);
    }
    position = boxEnd;
  }
  return null;
}

ByteRange? _previewIn(Uint8List bytes, ByteData data, int start, int end) {
  var position = start;
  while (position < end) {
    final box = _boxAt(bytes, data, position);
    if (box == null) return null;
    if (box.type == _previewType) {
      if (position + _previewJpegOffset > bytes.length) return null;
      final offset = position + _previewJpegOffset;
      final length = data.getUint32(position + _previewJpegLengthOffset);
      if (offset + length > bytes.length) return null;
      if (!_matches(bytes, offset, _jpegStartOfImage)) return null;
      return (offset: offset, length: length);
    }
    final size = box.size;
    if (size == null || size > end - position) return null;
    position += size;
  }
  return null;
}

_Box? _boxAt(Uint8List bytes, ByteData data, int position) {
  if (position + _boxHeaderLength > bytes.length) return null;
  final type = String.fromCharCodes(
    bytes,
    position + _typeOffset,
    position + _typeOffset + _typeLength,
  );
  final size = data.getUint32(position);
  if (size == _sizeToEndOfFile) {
    return (type: type, headerLength: _boxHeaderLength, size: null);
  }
  if (size == _sizeIsLarge) {
    if (position + _largeBoxHeaderLength > bytes.length) return null;
    final largeSize = data.getUint64(position + _boxHeaderLength);
    if (largeSize < _largeBoxHeaderLength) return null;
    return (type: type, headerLength: _largeBoxHeaderLength, size: largeSize);
  }
  if (size < _boxHeaderLength) return null;
  return (type: type, headerLength: _boxHeaderLength, size: size);
}

bool _matches(Uint8List bytes, int offset, List<int> expected) {
  if (offset + expected.length > bytes.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (bytes[offset + i] != expected[i]) return false;
  }
  return true;
}

/// The JPEG preview embedded in the CR3 [object], read from its start until
/// the preview is complete. [into] collects what was read, and any bytes it
/// already holds are not read again.
Future<Uint8List?> readCr3Preview(
  CameraClient client,
  CameraObject object, {
  CancelToken? cancelToken,
  int step = ptpDownloadChunkSize,
  int cap = cr3PreviewReadCap,
  BytesBuilder? into,
}) async {
  final limit = min(cap, object.size);
  final buffer = into ?? BytesBuilder(copy: false);
  final earlier = buffer.isEmpty ? null : _previewOf(buffer.toBytes());
  if (earlier != null) return earlier;
  bool cancelled() => cancelToken?.isCancelled ?? false;
  while (buffer.length < limit) {
    if (cancelled()) throw const TransferCancelledException();
    final start = buffer.length;
    await client.download(
      object,
      (chunk) async => buffer.add(chunk),
      offset: start,
      length: min(step, limit - start),
      cancelToken: cancelToken,
    );
    if (cancelled()) throw const TransferCancelledException();
    final preview = _previewOf(buffer.toBytes());
    if (preview != null) return preview;
    if (buffer.length == start) return null;
  }
  return null;
}

Uint8List? _previewOf(Uint8List bytes) {
  final range = cr3PreviewRange(bytes);
  if (range == null) return null;
  return Uint8List.sublistView(
    bytes,
    range.offset,
    range.offset + range.length,
  );
}
