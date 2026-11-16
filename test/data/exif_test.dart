import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/data/exif.dart';

import '../fakes/exif_jpeg.dart';

void main() {
  for (final endian in [Endian.big, Endian.little]) {
    test('reads the original date, in $endian byte order', () {
      final jpeg = exifJpeg(
        endian: endian,
        dateTime: '2026:11:15 18:00:00',
        original: '2026:11:14 09:30:05',
      );

      expect(exifCaptureDate(jpeg), DateTime(2026, 11, 14, 9, 30, 5));
    });
  }

  test('falls back to the date the photo was changed', () {
    final jpeg = exifJpeg(dateTime: '2026:11:15 18:00:00');

    expect(exifCaptureDate(jpeg), DateTime(2026, 11, 15, 18));
  });

  test('a blank original date falls back too', () {
    final jpeg = exifJpeg(
      endian: Endian.little,
      dateTime: '2026:11:15 18:00:00',
      original: '    :  :     :  :  ',
    );

    expect(exifCaptureDate(jpeg), DateTime(2026, 11, 15, 18));
  });

  test('a zero date is no date', () {
    expect(exifCaptureDate(exifJpeg(dateTime: '0000:00:00 00:00:00')), isNull);
  });

  test('a JPEG without EXIF has no date', () {
    expect(
      exifCaptureDate(
        Uint8List.fromList([0xFF, 0xD8, ...jfifSegment, ...scanToEnd]),
      ),
      isNull,
    );
    expect(exifCaptureDate(exifJpeg()), isNull);
  });

  test('anything else has no date', () {
    expect(exifCaptureDate(Uint8List(0)), isNull);
    expect(
      exifCaptureDate(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])),
      isNull,
    );
    expect(
      exifCaptureDate(Uint8List.fromList([0xFF, 0xD8, 0, 0, 0, 0])),
      isNull,
    );
  });

  test('a header cut before the date has none and does not throw', () {
    const original = '2026:11:14 09:30:05';
    final jpeg = exifJpeg(original: original);
    final dateEnd =
        String.fromCharCodes(jpeg).indexOf(original) + original.length;

    for (var length = 0; length < dateEnd; length++) {
      expect(
        exifCaptureDate(Uint8List.sublistView(jpeg, 0, length)),
        isNull,
        reason: 'cut at $length',
      );
    }
  });

  group('orientation', () {
    for (final endian in [Endian.big, Endian.little]) {
      test('is read as a SHORT in $endian byte order', () {
        for (final orientation in [1, 3, 6, 8]) {
          expect(
            exifOrientation(exifJpeg(endian: endian, orientation: orientation)),
            orientation,
          );
        }
      });
    }

    test('is unknown without the tag or without EXIF', () {
      expect(
        exifOrientation(exifJpeg(dateTime: '2026:11:15 18:00:00')),
        isNull,
      );
      expect(exifOrientation(Uint8List.fromList([0xFF, 0xD8])), isNull);
      expect(exifOrientation(Uint8List(0)), isNull);
    });

    test('ignores values outside 1 to 8', () {
      expect(exifOrientation(exifJpeg(orientation: 0)), isNull);
      expect(exifOrientation(exifJpeg(orientation: 9)), isNull);
    });

    test('turns clockwise to upright', () {
      expect(
        [
          for (var orientation = 0; orientation <= 8; orientation++)
            quarterTurnsOf(orientation),
        ],
        [0, 0, 0, 2, 2, 1, 1, 3, 3],
      );
      expect(quarterTurnsOf(null), 0);
    });
  });

  test('an APP1 shorter than its own signature has no EXIF', () {
    final jpeg = Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE1, 0, 4, ...'Exif'.codeUnits, 0, 0, //
      ...List.filled(16, 0),
    ]);

    expect(exifOrientation(jpeg), isNull);
    expect(exifCaptureDate(jpeg), isNull);
  });
}
