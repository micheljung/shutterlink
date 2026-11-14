import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptpip/ptpip.dart';

import 'fake_camera.dart';

const _terminator = [8, 0, 0, 0, 0, 0, 0, 0];
const _unknownType = 0xC1F6;
const _bigSize = 0x123456789;
const _sizeAt = 0x1C;
const _beforeName = 0x20;
const _pastEnd = 0x30;
const _partialHeader = 4;
const _unknownPayload = 5;
const _longPropertyRecord = 52;

Uint8List _join(List<List<int>> parts) =>
    Uint8List.fromList([for (final part in parts) ...part]);

Uint8List _unknownRecord(int payloadLength) {
  final size = canonEventHeaderSize + payloadLength;
  return (ByteData(size)
        ..setUint32(0, size, Endian.little)
        ..setUint32(4, _unknownType, Endian.little))
      .buffer
      .asUint8List();
}

void main() {
  final jpeg = FakeObject(
    handle: 0x91234567,
    format: PtpObjectFormat.exifJpeg,
    filename: 'IMG_0042.JPG',
    parent: 0x00100011,
    storageId: 0x00020001,
    content: Uint8List(3000),
  );
  const jpegAdded = CanonObjectAdded(
    handle: 0x91234567,
    storageId: 0x00020001,
    format: PtpObjectFormat.exifJpeg,
    size: 3000,
    parent: 0x00100011,
  );

  test('ObjectAddedEx yields the handle, storage, format, size, parent', () {
    expect(parseCanonEvents(_join([objectAddedRecord(jpeg), _terminator])), [
      jpegAdded,
    ]);
  });

  test('ObjectAddedEx64 reads the 64-bit size and the shifted parent', () {
    final raw = FakeObject(
      handle: 0x22,
      format: PtpObjectFormat.canonCr3,
      filename: 'IMG_0042.CR3',
      parent: 0x11,
    );
    final record = objectAddedRecord(raw, sixtyFourBit: true);
    ByteData.sublistView(record).setUint64(_sizeAt, _bigSize, Endian.little);

    expect(parseCanonEvents(record), [
      const CanonObjectAdded(
        handle: 0x22,
        storageId: fakeStorageId,
        format: PtpObjectFormat.canonCr3,
        size: _bigSize,
        parent: 0x11,
      ),
    ]);
  });

  test('an object removal yields its handle', () {
    expect(parseCanonEvents(objectRemovedRecord(0x22)), [
      const CanonObjectRemoved(0x22),
    ]);
  });

  test('a transfer request yields its handle', () {
    expect(
      parseCanonEvents(
        _join([transferRequestRecord(jpeg), objectAddedRecord(jpeg)]),
      ),
      [const CanonTransferRequested(0x91234567), jpegAdded],
    );
  });

  test('a storage change and a u32 property change are decoded', () {
    expect(
      parseCanonEvents(
        _join([
          storageChangedRecord(0x00020001),
          propertyChangedRecord(CanonEosProperty.cameraTime, 0x6af859d9),
        ]),
      ),
      [
        const CanonStorageChanged(),
        const CanonPropertyChanged(CanonEosProperty.cameraTime, 0x6af859d9),
      ],
    );
  });

  test('a property change with a longer value is skipped', () {
    final long = Uint8List(_longPropertyRecord);
    ByteData.sublistView(long)
      ..setUint32(0, _longPropertyRecord, Endian.little)
      ..setUint32(4, CanonEosEvent.propValueChanged, Endian.little)
      ..setUint32(8, 0xD157, Endian.little);
    expect(parseCanonEvents(long), isEmpty);
  });

  test('unknown and too short records are skipped by their size', () {
    final short = objectAddedRecord(jpeg).sublist(0, _beforeName);
    ByteData.sublistView(short).setUint32(0, short.length, Endian.little);

    expect(
      parseCanonEvents(
        _join([
          _unknownRecord(_unknownPayload),
          short,
          _unknownRecord(0),
          objectAddedRecord(jpeg),
        ]),
      ),
      [jpegAdded],
    );
  });

  test('parsing stops at the terminator or a trailing partial header', () {
    expect(parseCanonEvents(Uint8List(0)), isEmpty);
    expect(
      parseCanonEvents(_join([_terminator, objectAddedRecord(jpeg)])),
      isEmpty,
    );
    expect(
      parseCanonEvents(
        _join([
          objectAddedRecord(jpeg),
          _terminator.sublist(0, _partialHeader),
        ]),
      ),
      [jpegAdded],
    );
  });

  test('a size below the header or past the end is a protocol error', () {
    final tooSmall = _join([
      [4, 0, 0, 0, 1, 0, 0, 0],
      _terminator,
    ]);
    final truncated = objectAddedRecord(jpeg).sublist(0, _pastEnd);

    expect(
      () => parseCanonEvents(tooSmall),
      throwsA(isA<PtpIpProtocolException>()),
    );
    expect(
      () => parseCanonEvents(truncated),
      throwsA(isA<PtpIpProtocolException>()),
    );
  });

  test('records expose their type and bytes', () {
    final record = objectAddedRecord(jpeg);
    final records = canonEventRecords(_join([record, _terminator]));

    expect(records.single.type, CanonEosEvent.objectAddedEx);
    expect(records.single.bytes, record);
  });
}
