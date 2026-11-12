import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/data/cr3_preview.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

import '../fakes/fake_camera_client.dart';
import '../fakes/fake_cr3.dart';

const _step = 128;
const _cap = 512;
const _largeBoxHeaderLength = 16;
const _largeSizeMarker = 1;
const _largeSizeOffset = 8;
const _hugeBoxSize = 0x7FFFFFFFFFFFFFFC;

Uint8List _cr3({int moovPadding = 0, bool largeMoov = false}) =>
    fakeCr3(moovPadding: moovPadding, largeMoov: largeMoov, mdatLength: _cap);

Future<(Uint8List?, FakeCameraClient)> _read(Uint8List bytes) async {
  final object = cameraObject(1, 'IMG_0001.CR3', size: bytes.length);
  final client = FakeCameraClient([object])..contentOverrides[1] = bytes;
  final preview = await readCr3Preview(client, object, step: _step, cap: _cap);
  return (preview, client);
}

void main() {
  test('finds the embedded JPEG range', () {
    final bytes = _cr3();

    final range = cr3PreviewRange(bytes)!;

    expect(
      bytes.sublist(range.offset, range.offset + range.length),
      fakePreviewJpeg,
    );
  });

  test('walks boxes with a 64-bit size', () {
    final bytes = _cr3(moovPadding: 20, largeMoov: true);

    final range = cr3PreviewRange(bytes)!;

    expect(
      bytes.sublist(range.offset, range.offset + range.length),
      fakePreviewJpeg,
    );
  });

  test('reports nothing for a 64-bit size beyond the data', () {
    final hugeBox = ByteData(_largeBoxHeaderLength)
      ..setUint32(0, _largeSizeMarker)
      ..setUint64(_largeSizeOffset, _hugeBoxSize);
    final bytes = Uint8List.fromList([
      ...hugeBox.buffer.asUint8List(),
      ..._cr3(),
    ]);

    expect(cr3PreviewRange(bytes), isNull);
  });

  test('reports nothing while the JPEG is incomplete', () {
    final bytes = _cr3();
    final range = cr3PreviewRange(bytes)!;

    expect(
      cr3PreviewRange(Uint8List.sublistView(bytes, 0, range.offset + 1)),
      isNull,
    );
  });

  test('rejects a preview that is not a JPEG', () {
    final bytes = _cr3();
    final range = cr3PreviewRange(bytes)!;
    bytes[range.offset] = 0;

    expect(cr3PreviewRange(bytes), isNull);
  });

  test('reads only the first step when the preview is inside it', () async {
    final (preview, client) = await _read(_cr3());

    expect(preview, fakePreviewJpeg);
    expect(client.requestedOffsets[1], [0]);
  });

  test('reads further steps until the preview is complete', () async {
    final (preview, client) = await _read(_cr3(moovPadding: 100));

    expect(preview, fakePreviewJpeg);
    expect(client.requestedOffsets[1], [0, _step]);
  });

  test('gives up at the cap when the preview is missing', () async {
    final (preview, client) = await _read(_cr3(moovPadding: _cap));

    expect(preview, isNull);
    expect(client.requestedOffsets[1], [0, _step, 2 * _step, 3 * _step]);
  });

  test('stops when cancelled', () async {
    final bytes = _cr3(moovPadding: 100);
    final object = cameraObject(1, 'IMG_0001.CR3', size: bytes.length);
    final client = FakeCameraClient([object])..contentOverrides[1] = bytes;
    final token = CancelToken()..cancel();

    await expectLater(
      readCr3Preview(client, object, cancelToken: token, step: _step),
      throwsA(isA<TransferCancelledException>()),
    );
    expect(client.requestedOffsets, isEmpty);
  });
}
