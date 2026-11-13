import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:shutterlink_server/src/zip_stream.dart';
import 'package:test/test.dart';

import 'support.dart';

const int _mebibyte = 1024 * 1024;
const int _largeFileBytes = 64 * _mebibyte;
const int _largeChunkBytes = _mebibyte;

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

void main() {
  test('crc32 matches the reference implementation', () {
    final bytes = photoBytes(7, 5000);
    expect(crc32(bytes), getCrc32(bytes));
    expect(crc32(const []), 0);
  });

  test('archive decodes names, sizes, CRCs and content', () async {
    final files = {
      'a.jpg': photoBytes(1, 10),
      'b.jpg': photoBytes(2, 70000),
      'empty.jpg': <int>[],
    };
    final bytes = await _collect(
      storeZip([
        for (final MapEntry(:key, :value) in files.entries)
          ZipEntry(key, t0, () => chunked(value, 4096)),
      ]),
    );
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    expect(archive.files.map((f) => f.name), files.keys);
    for (final file in archive.files) {
      final expected = files[file.name]!;
      expect(file.size, expected.length);
      expect(file.crc32, getCrc32(expected));
      expect(file.content, expected);
    }
  });

  test('an empty archive is valid', () async {
    final bytes = await _collect(storeZip(const []));
    expect(ZipDecoder().decodeBytes(bytes).files, isEmpty);
  });

  test('streams a 64 MiB file without buffering it', () async {
    final chunk = Uint8List.fromList(photoBytes(9, _largeChunkBytes));
    var produced = 0;
    Stream<List<int>> source() async* {
      for (var i = 0; i < _largeFileBytes ~/ _largeChunkBytes; i++) {
        produced++;
        yield chunk;
      }
    }

    int? producedAtFirstData;
    final builder = BytesBuilder(copy: false);
    await for (final out in storeZip([ZipEntry('big.jpg', t0, source)])) {
      if (identical(out, chunk)) producedAtFirstData ??= produced;
      builder.add(out);
    }
    expect(producedAtFirstData, 1);

    final file = ZipDecoder().decodeBytes(builder.takeBytes()).files.single;
    expect(file.size, _largeFileBytes);
    final expectedCrc = List.filled(
      _largeFileBytes ~/ _largeChunkBytes,
      chunk,
    ).fold<int>(0, (crc, part) => getCrc32(part, crc));
    expect(file.crc32, expectedCrc);
  });
}
