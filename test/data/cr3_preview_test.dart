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

/// The PRVW box's size and type, and the preview `uuid` box before it.
const _previewHeader = 8 + 8 + 16 + 8;

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
    expect(client.downloadLengths[1], [_step, _step]);
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

  test('resumes after the bytes it was given', () async {
    final bytes = _cr3(moovPadding: 100);
    final object = cameraObject(1, 'IMG_0001.CR3', size: bytes.length);
    final client = FakeCameraClient([object])..contentOverrides[1] = bytes;
    final buffer = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(bytes, 0, _step));

    final preview = await readCr3Preview(
      client,
      object,
      step: _step,
      into: buffer,
    );

    expect(preview, fakePreviewJpeg);
    expect(client.requestedOffsets[1], [_step]);
  });

  test(
    'returns a preview already in the given bytes without reading',
    () async {
      final bytes = _cr3();
      final object = cameraObject(1, 'IMG_0001.CR3', size: bytes.length);
      final client = FakeCameraClient([object]);

      final preview = await readCr3Preview(
        client,
        object,
        into: BytesBuilder()..add(bytes),
      );

      expect(preview, fakePreviewJpeg);
      expect(client.requestedOffsets, isEmpty);
    },
  );

  group('orientation', () {
    test('comes from CMT1 in the Canon box', () {
      expect(cr3Orientation(fakeCr3(orientation: 6)), 6);
      expect(cr3Orientation(fakeCr3(orientation: 8)), 8);
    });

    test('is unknown without the Canon box', () {
      expect(cr3Orientation(fakeCr3()), isNull);
    });

    test('is unknown while CMT1 is cut off, and does not throw', () {
      final bytes = fakeCr3(orientation: 6);
      final metadataEnd =
          String.fromCharCodes(bytes).indexOf('PRVW') - _previewHeader;
      for (var length = 0; length < metadataEnd; length++) {
        expect(
          cr3Orientation(Uint8List.sublistView(bytes, 0, length)),
          isNull,
          reason: 'cut at $length',
        );
      }
    });
  });
}
