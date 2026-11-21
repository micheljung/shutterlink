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
const _longValue = [0x10, 0x20, 0x30, 0x40, 0x50, 0x60];
const _evfProperty = 0xD1B0;
const _isoProperty = 0xD103;
const _isoValues = [0x48, 0x50, 0x58];
const _enumDataType = 3;
const _u32 = 4;

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
      format: CanonObjectFormat.cr3,
      filename: 'IMG_0042.CR3',
      parent: 0x11,
    );
    final record = objectAddedRecord(raw, sixtyFourBit: true);
    ByteData.sublistView(record).setUint64(_sizeAt, _bigSize, Endian.little);

    expect(parseCanonEvents(record), [
      const CanonObjectAdded(
        handle: 0x22,
        storageId: fakeStorageId,
        format: CanonObjectFormat.cr3,
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
    final events = parseCanonEvents(
      _join([
        storageChangedRecord(0x00020001),
        propertyChangedRecord(CanonEosProperty.cameraTime, 0x6af859d9),
      ]),
    );
    expect(events, [
      const CanonStorageChanged(),
      CanonPropertyChanged(
        CanonEosProperty.cameraTime,
        Uint8List.fromList([0xd9, 0x59, 0xf8, 0x6a]),
      ),
    ]);
    expect((events.last as CanonPropertyChanged).u32, 0x6af859d9);
  });

  test('a property change keeps a longer value as raw bytes', () {
    final event =
        parseCanonEvents(propertyBytesChangedRecord(_evfProperty, _longValue))
                .single
            as CanonPropertyChanged;
    expect(event.property, _evfProperty);
    expect(event.value, _longValue);
    expect(event.u32, isNull);
  });

  test('a property change without a value has empty bytes', () {
    final event =
        parseCanonEvents(propertyBytesChangedRecord(_evfProperty, const []))
                .single
            as CanonPropertyChanged;
    expect(event.value, isEmpty);
    expect(event.u32, isNull);
  });

  test('an allowed-values list yields the property, type and values', () {
    expect(
      parseCanonEvents(
        _join([
          allowedValuesRecord(_isoProperty, _enumDataType, _isoValues),
          _terminator,
        ]),
      ),
      [const CanonAllowedValues(_isoProperty, _enumDataType, _isoValues)],
    );
    expect(
      parseCanonEvents(
        allowedValuesRecord(_isoProperty, _enumDataType, const []),
      ),
      [const CanonAllowedValues(_isoProperty, _enumDataType, [])],
    );
  });

  test('an allowed-values list whose count overruns the record is skipped', () {
    expect(
      parseCanonEvents(
        _join([
          allowedValuesRecord(
            _isoProperty,
            _enumDataType,
            _isoValues,
            count: _isoValues.length + 1,
          ),
          storageChangedRecord(fakeStorageId),
        ]),
      ),
      [const CanonStorageChanged()],
    );
  });

  test('0xC18B stays an unknown record', () {
    final record = _unknownRecord(_u32);
    ByteData.sublistView(record).setUint32(4, 0xC18B, Endian.little);
    final records = canonEventRecords(record);
    expect(records.single.type, 0xC18B);
    expect(parseCanonEvent(records.single), isNull);
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

  test('a malformed record ends the batch and keeps the records before', () {
    final tooSmall = _join([
      objectAddedRecord(jpeg),
      malformedEventRecord(),
      storageChangedRecord(fakeStorageId),
      _terminator,
    ]);
    final truncated = _join([
      storageChangedRecord(fakeStorageId),
      objectAddedRecord(jpeg).sublist(0, _pastEnd),
    ]);
    final malformed = <(int, int)>[];

    expect(parseCanonEvents(tooSmall), [jpegAdded]);
    expect(
      canonEventRecords(
        truncated,
        onMalformed: (offset, size) => malformed.add((offset, size)),
      ).map(parseCanonEvent),
      [const CanonStorageChanged()],
    );
    expect(malformed, [
      (
        storageChangedRecord(fakeStorageId).length,
        objectAddedRecord(jpeg).length,
      ),
    ]);
  });

  test('records expose their type and bytes', () {
    final record = objectAddedRecord(jpeg);
    final records = canonEventRecords(_join([record, _terminator]));

    expect(records.single.type, CanonEosEvent.objectAddedEx);
    expect(records.single.bytes, record);
  });
}
