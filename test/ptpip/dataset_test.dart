import 'dart:typed_data';

import 'package:eos_transfer/ptpip/ptpip.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PTP string is u8 count including NUL plus UTF-16LE', () {
    final bytes = (PtpDataWriter()..string('Hé')).toBytes();
    expect(bytes, [3, 0x48, 0, 0xE9, 0, 0, 0]);
    expect(PtpDataReader(bytes).string(), 'Hé');
    expect((PtpDataWriter()..string('')).toBytes(), [0]);
    expect(PtpDataReader(Uint8List.fromList([0])).string(), '');
    expect(PtpDataReader(Uint8List.fromList([1, 0x41, 0])).string(), 'A');
    expect(() => PtpDataWriter().string('x' * 255), throwsArgumentError);
  });

  test('integers and arrays round-trip', () {
    final bytes =
        (PtpDataWriter()
              ..u8(1)
              ..u16(0x1234)
              ..u32(0xDEADBEEF)
              ..u64(0x123456789A)
              ..u16Array([1, 2])
              ..u32Array([3]))
            .toBytes();
    final r = PtpDataReader(bytes);
    expect(r.u8(), 1);
    expect(r.u16(), 0x1234);
    expect(r.u32(), 0xDEADBEEF);
    expect(r.u64(), 0x123456789A);
    expect(r.u16Array(), [1, 2]);
    expect(r.u32Array(), [3]);
    expect(r.remaining, 0);
    expect(r.u8, throwsFormatException);
    expect(parseU32Array((PtpDataWriter()..u32Array([5, 6])).toBytes()), [
      5,
      6,
    ]);
  });

  test('DeviceInfo round-trips', () {
    const info = PtpDeviceInfo(
      standardVersion: 100,
      vendorExtensionId: 11,
      vendorExtensionVersion: 100,
      vendorExtensionDesc: 'desc',
      functionalMode: 0,
      operationsSupported: [0x1001, 0x9116],
      eventsSupported: [0x4002],
      devicePropertiesSupported: [0x5001],
      captureFormats: [0x3801],
      imageFormats: [0xB108],
      manufacturer: 'Canon Inc.',
      model: 'Canon EOS R',
      deviceVersion: '1-1.8.0',
      serialNumber: '42',
    );
    final parsed = PtpDeviceInfo.parse(info.encode());
    expect(parsed.standardVersion, 100);
    expect(parsed.vendorExtensionId, 11);
    expect(parsed.vendorExtensionVersion, 100);
    expect(parsed.vendorExtensionDesc, 'desc');
    expect(parsed.functionalMode, 0);
    expect(parsed.operationsSupported, [0x1001, 0x9116]);
    expect(parsed.eventsSupported, [0x4002]);
    expect(parsed.devicePropertiesSupported, [0x5001]);
    expect(parsed.captureFormats, [0x3801]);
    expect(parsed.imageFormats, [0xB108]);
    expect(parsed.manufacturer, 'Canon Inc.');
    expect(parsed.model, 'Canon EOS R');
    expect(parsed.deviceVersion, '1-1.8.0');
    expect(parsed.serialNumber, '42');
  });

  test('ObjectInfo round-trips and tolerates missing keywords', () {
    const info = PtpObjectInfo(
      storageId: 0x20001,
      objectFormat: PtpObjectFormat.canonCr3,
      protectionStatus: 1,
      compressedSize: 31000000,
      thumbFormat: PtpObjectFormat.exifJpeg,
      thumbCompressedSize: 9000,
      thumbPixWidth: 160,
      thumbPixHeight: 120,
      imagePixWidth: 6720,
      imagePixHeight: 4480,
      imageBitDepth: 14,
      parentObject: 0x11,
      associationType: 0,
      associationDesc: 0,
      sequenceNumber: 3,
      filename: 'IMG_0001.CR3',
      captureDate: '20240102T030405',
      modificationDate: '20240102T030406',
      keywords: 'k',
    );
    final bytes = info.encode();
    final parsed = PtpObjectInfo.parse(bytes);
    expect(parsed.storageId, 0x20001);
    expect(parsed.objectFormat, PtpObjectFormat.canonCr3);
    expect(parsed.protectionStatus, 1);
    expect(parsed.compressedSize, 31000000);
    expect(parsed.thumbFormat, PtpObjectFormat.exifJpeg);
    expect(parsed.thumbCompressedSize, 9000);
    expect(parsed.thumbPixWidth, 160);
    expect(parsed.thumbPixHeight, 120);
    expect(parsed.imagePixWidth, 6720);
    expect(parsed.imagePixHeight, 4480);
    expect(parsed.imageBitDepth, 14);
    expect(parsed.parentObject, 0x11);
    expect(parsed.associationType, 0);
    expect(parsed.associationDesc, 0);
    expect(parsed.sequenceNumber, 3);
    expect(parsed.filename, 'IMG_0001.CR3');
    expect(parsed.captureDate, '20240102T030405');
    expect(parsed.modificationDate, '20240102T030406');
    expect(parsed.keywords, 'k');

    final withoutKeywords = Uint8List.sublistView(bytes, 0, bytes.length - 5);
    expect(PtpObjectInfo.parse(withoutKeywords).keywords, '');
  });

  group('parsePtpDateTime', () {
    test('local time', () {
      expect(
        parsePtpDateTime('20240102T030405'),
        DateTime(2024, 1, 2, 3, 4, 5),
      );
    });

    test('tenths of a second', () {
      expect(
        parsePtpDateTime('20240102T030405.7'),
        DateTime(2024, 1, 2, 3, 4, 5, 700),
      );
    });

    test('UTC and offsets', () {
      expect(
        parsePtpDateTime('20240102T030405Z'),
        DateTime.utc(2024, 1, 2, 3, 4, 5),
      );
      expect(
        parsePtpDateTime('20240102T030405+0130'),
        DateTime.utc(2024, 1, 2, 1, 34, 5),
      );
      expect(
        parsePtpDateTime('20240102T030405-0200'),
        DateTime.utc(2024, 1, 2, 5, 4, 5),
      );
    });

    test('invalid input yields null', () {
      expect(parsePtpDateTime(''), isNull);
      expect(parsePtpDateTime('yesterday'), isNull);
    });

    test('format round-trips', () {
      final value = DateTime(2024, 11, 9, 8, 7, 6);
      expect(formatPtpDateTime(value), '20241109T080706');
      expect(parsePtpDateTime(formatPtpDateTime(value)), value);
    });
  });
}
