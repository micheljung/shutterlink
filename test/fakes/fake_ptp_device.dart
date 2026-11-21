import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:shutterlink/ptp/canon/canon_constants.dart';
import 'package:shutterlink/ptp/canon/canon_events.dart';
import 'package:shutterlink/ptp/dataset.dart';
import 'package:shutterlink/ptp/ptp_constants.dart';

const fakeStorageId = 0x00020001;
const _canonVendorExtensionId = 0x0B;
const _recordTypeAt = 0x04;
const _recordHandleAt = 0x08;
const _addedStorageAt = 0x0C;
const _addedFormatAt = 0x10;
const _addedSizeAt = 0x1C;
const _addedParentAt = 0x20;
const _objectAddedNameOffset = 0x28;
const _added64ParentAt = 0x24;
const _objectAdded64NameOffset = 0x2C;
const _transferFormatAt = 0x0C;
const _transferSizeAt = 0x14;
const _transferNameOffset = 0x1C;
const _u32Size = 4;
const _canonPropertyPayloadSize = 3 * _u32Size;
const _viewFinderRecordHeaderSize = 2 * _u32Size;

/// A GetViewFinderData record type that is not a JPEG, such as the EVF
/// info block a real body sends next to the frame.
const fakeViewFinderInfoRecordType = 4;
const _fakeViewFinderInfoLength = 16;

class FakeObject {
  FakeObject({
    required this.handle,
    required this.format,
    required this.filename,
    this.parent = 0,
    this.storageId = fakeStorageId,
    this.captureDate = '',
    Uint8List? content,
    this.thumbnail,
  }) : content = content ?? Uint8List(0);

  final int handle;
  final int format;
  final String filename;
  final int parent;
  final int storageId;
  final String captureDate;
  final Uint8List content;
  final Uint8List? thumbnail;

  PtpObjectInfo get info => PtpObjectInfo(
    storageId: storageId,
    objectFormat: format,
    compressedSize: content.length,
    parentObject: parent,
    filename: filename,
    captureDate: captureDate,
  );
}

Uint8List _withName(ByteData record, int nameOffset, String name) {
  final bytes = record.buffer.asUint8List();
  bytes.setAll(nameOffset, name.codeUnits);
  return bytes;
}

ByteData _record(int type, int nameOffset, String name) {
  final size = nameOffset + name.length + 1;
  return ByteData(size)
    ..setUint32(0, size, Endian.little)
    ..setUint32(_recordTypeAt, type, Endian.little);
}

/// A Canon ObjectAddedEx (or ObjectAddedEx64) record, laid out like
/// libgphoto2's `ptp_unpack_CANON_changes` reads it.
Uint8List objectAddedRecord(FakeObject object, {bool sixtyFourBit = false}) {
  final nameOffset = sixtyFourBit
      ? _objectAdded64NameOffset
      : _objectAddedNameOffset;
  final record =
      _record(
          sixtyFourBit
              ? CanonEosEvent.objectAddedEx64
              : CanonEosEvent.objectAddedEx,
          nameOffset,
          object.filename,
        )
        ..setUint32(_recordHandleAt, object.handle, Endian.little)
        ..setUint32(_addedStorageAt, object.storageId, Endian.little)
        ..setUint16(_addedFormatAt, object.format, Endian.little);
  if (sixtyFourBit) {
    record
      ..setUint64(_addedSizeAt, object.content.length, Endian.little)
      ..setUint32(_added64ParentAt, object.parent, Endian.little);
  } else {
    record
      ..setUint32(_addedSizeAt, object.content.length, Endian.little)
      ..setUint32(_addedParentAt, object.parent, Endian.little);
  }
  return _withName(record, nameOffset, object.filename);
}

Uint8List transferRequestRecord(FakeObject object) {
  final record =
      _record(
          CanonEosEvent.requestObjectTransfer,
          _transferNameOffset,
          object.filename,
        )
        ..setUint32(_recordHandleAt, object.handle, Endian.little)
        ..setUint16(_transferFormatAt, object.format, Endian.little)
        ..setUint32(_transferSizeAt, object.content.length, Endian.little);
  return _withName(record, _transferNameOffset, object.filename);
}

Uint8List objectRemovedRecord(int handle) {
  const size = _recordHandleAt + 4;
  final record = ByteData(size)
    ..setUint32(0, size, Endian.little)
    ..setUint32(_recordTypeAt, CanonEosEvent.objectRemoved, Endian.little)
    ..setUint32(_recordHandleAt, handle, Endian.little);
  return record.buffer.asUint8List();
}

/// A Canon PropValueChanged record with a single u32 value.
Uint8List propertyChangedRecord(int property, int value) =>
    propertyBytesChangedRecord(
      property,
      (ByteData(
        _u32Size,
      )..setUint32(0, value, Endian.little)).buffer.asUint8List(),
    );

/// A Canon PropValueChanged record with a value of any length.
Uint8List propertyBytesChangedRecord(int property, List<int> value) {
  const valueAt = _recordHandleAt + _u32Size;
  final size = valueAt + value.length;
  final record = ByteData(size)
    ..setUint32(0, size, Endian.little)
    ..setUint32(_recordTypeAt, CanonEosEvent.propValueChanged, Endian.little)
    ..setUint32(_recordHandleAt, property, Endian.little);
  return record.buffer.asUint8List()..setAll(valueAt, value);
}

/// A Canon AvailListChanged record; [count] overrides the real value count.
Uint8List allowedValuesRecord(
  int property,
  int dataType,
  List<int> values, {
  int? count,
}) {
  const dataTypeAt = _recordHandleAt + _u32Size;
  const countAt = dataTypeAt + _u32Size;
  const valuesAt = countAt + _u32Size;
  final size = valuesAt + values.length * _u32Size;
  final record = ByteData(size)
    ..setUint32(0, size, Endian.little)
    ..setUint32(_recordTypeAt, CanonEosEvent.availListChanged, Endian.little)
    ..setUint32(_recordHandleAt, property, Endian.little)
    ..setUint32(dataTypeAt, dataType, Endian.little)
    ..setUint32(countAt, count ?? values.length, Endian.little);
  for (final (i, value) in values.indexed) {
    record.setUint32(valuesAt + i * _u32Size, value, Endian.little);
  }
  return record.buffer.asUint8List();
}

/// A record whose size is below the header, which ends a Canon event batch.
Uint8List malformedEventRecord() {
  final record = ByteData(canonEventHeaderSize)
    ..setUint32(0, _u32Size, Endian.little)
    ..setUint32(_recordTypeAt, CanonEosEvent.storageInfoChanged, Endian.little);
  return record.buffer.asUint8List();
}

/// A Canon StorageInfoChanged record, as the EOS R sends it per shot.
Uint8List storageChangedRecord(int storageId) {
  const size = _recordHandleAt + 4;
  final record = ByteData(size)
    ..setUint32(0, size, Endian.little)
    ..setUint32(_recordTypeAt, CanonEosEvent.storageInfoChanged, Endian.little)
    ..setUint32(_recordHandleAt, storageId, Endian.little);
  return record.buffer.asUint8List();
}

Uint8List viewFinderRecord(int type, Uint8List payload) {
  final size = _viewFinderRecordHeaderSize + payload.length;
  final record = ByteData(size)
    ..setUint32(0, size, Endian.little)
    ..setUint32(_u32Size, type, Endian.little);
  return record.buffer.asUint8List()
    ..setAll(_viewFinderRecordHeaderSize, payload);
}

Uint8List patternBytes(int length, {int seed = 1}) {
  final random = Random(seed);
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

Uint8List ptpStringValue(String value) =>
    (PtpDataWriter()..string(value)).toBytes();

/// The camera's answer to one command.
class FakePtpReply {
  const FakePtpReply(
    this.code, {
    this.params = const [],
    this.data,
    this.dropAfterBytes,
  });

  final int code;
  final List<int> params;
  final Uint8List? data;

  /// Cut the link after this many bytes of [data] instead of answering.
  final int? dropAfterBytes;
}

/// A PTP camera with an EOS's opcodes and card, independent of the wire.
/// Each transport adapter records a command in [receivedOpcodes] when it
/// arrives and asks [handle] for the reply when it is due.
class FakePtpDevice {
  FakePtpDevice({
    List<FakeObject>? objects,
    this.dropAfterPartialBytes,
    this.supportedOperations = defaultOperations,
    this.openSessionCode = PtpResponseCode.ok,
    this.eventRecords,
    this.initialDump,
    this.eventDataOverride,
    Map<int, Uint8List>? devicePropertyValues,
    this.devicePropValueCode = PtpResponseCode.ok,
    this.deleteDeniedCode,
    this.deleteBusyResponses = 0,
    this._deviceInfo,
  }) : objects = objects ?? defaultObjects(),
       devicePropertyValues = devicePropertyValues ?? {};

  static const defaultOperations = [
    PtpOperation.getDeviceInfo,
    PtpOperation.openSession,
    PtpOperation.closeSession,
    PtpOperation.getStorageIds,
    PtpOperation.getObjectHandles,
    PtpOperation.getObjectInfo,
    PtpOperation.getThumb,
    PtpOperation.deleteObject,
    PtpOperation.getPartialObject,
    PtpOperation.getDevicePropValue,
    CanonEosOperation.setRemoteMode,
    CanonEosOperation.setEventMode,
    CanonEosOperation.getEvent,
  ];

  static const dcimHandle = 0x10;
  static const folderHandle = 0x11;
  static const jpegHandle = 0x21;
  static const rawHandle = 0x22;
  static const videoHandle = 0x23;
  static const largeJpegHandle = 0x24;
  static const rootJpegHandle = 0x25;
  static const jpegSize = 3000;
  static const rawSize = 5000;
  static const largeSize = 2 * 1024 * 1024 + 12345;

  static final _largeContent = patternBytes(largeSize, seed: largeJpegHandle);

  static List<FakeObject> defaultObjects() => [
    FakeObject(
      handle: dcimHandle,
      format: PtpObjectFormat.association,
      filename: 'DCIM',
    ),
    FakeObject(
      handle: folderHandle,
      format: PtpObjectFormat.association,
      filename: '100CANON',
      parent: dcimHandle,
    ),
    FakeObject(
      handle: jpegHandle,
      format: PtpObjectFormat.exifJpeg,
      filename: 'IMG_0001.JPG',
      parent: folderHandle,
      captureDate: '20240102T030405',
      content: patternBytes(jpegSize, seed: jpegHandle),
      thumbnail: patternBytes(100, seed: 99),
    ),
    FakeObject(
      handle: rawHandle,
      format: CanonObjectFormat.cr3,
      filename: 'IMG_0001.CR3',
      parent: folderHandle,
      captureDate: '20240102T030405',
      content: patternBytes(rawSize, seed: rawHandle),
    ),
    FakeObject(
      handle: videoHandle,
      format: CanonObjectFormat.mov,
      filename: 'MVI_0002.MOV',
      parent: folderHandle,
      content: patternBytes(10, seed: videoHandle),
    ),
    FakeObject(
      handle: largeJpegHandle,
      format: PtpObjectFormat.exifJpeg,
      filename: 'IMG_0003.JPG',
      parent: folderHandle,
      captureDate: '20240105T101010.5',
      content: _largeContent,
    ),
    FakeObject(
      handle: rootJpegHandle,
      format: PtpObjectFormat.jfif,
      filename: 'ROOT.JPG',
      content: patternBytes(10, seed: rootJpegHandle),
    ),
  ];

  final List<FakeObject> objects;
  final Map<int, Uint8List> devicePropertyValues;
  final int devicePropValueCode;
  int? deleteDeniedCode;
  int deleteBusyResponses;
  int? dropAfterPartialBytes;
  final List<int> supportedOperations;
  final int openSessionCode;
  final Uint8List? eventRecords;
  final Uint8List? initialDump;
  Uint8List? eventDataOverride;
  final _pendingEvents = <Uint8List>[];
  int getEventCount = 0;
  final receivedOpcodes = <int>[];
  int _partialBytesSent = 0;

  /// Canon properties set with SetDevicePropValueEx, by property.
  final canonProperties = <int, int>{};

  /// Every SetDevicePropValueEx payload, in order.
  final canonPropertyPayloads = <Uint8List>[];

  /// JPEGs GetViewFinderData hands out, one per request, while the EVF
  /// output includes the PC.
  final liveViewFrames = Queue<Uint8List>();

  /// Response codes GetViewFinderData answers with before any frame, one per
  /// request.
  final viewFinderCodes = Queue<int>();

  /// Remote release, zoom and AF commands, in order.
  final vendorCalls = <({int opcode, List<int> params, Uint8List? dataOut})>[];

  /// Response codes that replace the normal answer, by opcode.
  final responseOverrides = <int, int>{};

  /// Queue a PropValueChanged echo for every SetDevicePropValueEx.
  bool echoCanonProperties = false;

  static const _firstCapturedHandle = 0x30;
  int _capturedCount = 0;

  void addObject(FakeObject object, {bool sixtyFourBit = false}) {
    objects.add(object);
    queueEventRecord(objectAddedRecord(object, sixtyFourBit: sixtyFourBit));
  }

  void removeObject(int handle) {
    objects.removeWhere((object) => object.handle == handle);
    queueEventRecord(objectRemovedRecord(handle));
  }

  void queueEventRecord(Uint8List record) => _pendingEvents.add(record);

  /// Operations whose command is followed by a data-out phase.
  static const dataOutOperations = {
    PtpOperation.setDevicePropValue,
    CanonEosOperation.setDevicePropValueEx,
    CanonEosOperation.setLiveAfFrame,
  };

  FakePtpReply handle(int opcode, List<int> params, {Uint8List? dataOut}) {
    final p = params;
    FakeObject? object(int handle) =>
        objects.firstWhereOrNull((o) => o.handle == handle);
    final override = responseOverrides[opcode];
    if (override != null) {
      return FakePtpReply(override);
    }
    switch (opcode) {
      case PtpOperation.openSession:
        return FakePtpReply(openSessionCode);
      case PtpOperation.getDeviceInfo:
        return FakePtpReply(PtpResponseCode.ok, data: deviceInfo.encode());
      case PtpOperation.getStorageIds:
        return FakePtpReply(
          PtpResponseCode.ok,
          data: _u32Array([fakeStorageId]),
        );
      case PtpOperation.getObjectHandles:
        final parent = p[2];
        final handles = objects
            .where(
              (o) => switch (parent) {
                PtpHandle.root => o.parent == 0,
                0 => true,
                _ => o.parent == parent,
              },
            )
            .map((o) => o.handle)
            .toList();
        return FakePtpReply(PtpResponseCode.ok, data: _u32Array(handles));
      case PtpOperation.getObjectInfo:
        final o = object(p[0]);
        return o == null
            ? const FakePtpReply(PtpResponseCode.invalidObjectHandle)
            : FakePtpReply(PtpResponseCode.ok, data: o.info.encode());
      case PtpOperation.getThumb:
        final thumb = object(p[0])?.thumbnail;
        return thumb == null
            ? const FakePtpReply(PtpResponseCode.noThumbnailPresent)
            : FakePtpReply(PtpResponseCode.ok, data: thumb);
      case PtpOperation.deleteObject:
        final o = object(p[0]);
        final denied = deleteDeniedCode;
        if (o == null) {
          return const FakePtpReply(PtpResponseCode.invalidObjectHandle);
        } else if (deleteBusyResponses > 0) {
          deleteBusyResponses--;
          return const FakePtpReply(PtpResponseCode.deviceBusy);
        } else if (denied != null) {
          return FakePtpReply(denied);
        }
        objects.remove(o);
        return const FakePtpReply(PtpResponseCode.ok);
      case PtpOperation.getPartialObject:
        final o = object(p[0]);
        if (o == null) {
          return const FakePtpReply(PtpResponseCode.invalidObjectHandle);
        }
        final start = min(p[1], o.content.length);
        final end = min(start + p[2], o.content.length);
        final data = Uint8List.sublistView(o.content, start, end);
        final drop = dropAfterPartialBytes;
        if (drop != null && _partialBytesSent + end - start > drop) {
          return FakePtpReply(
            PtpResponseCode.ok,
            data: data,
            dropAfterBytes: 0,
          );
        }
        _partialBytesSent += end - start;
        return FakePtpReply(PtpResponseCode.ok, data: data);
      case PtpOperation.getDevicePropValue:
        final value = devicePropertyValues[p[0]];
        if (value == null) {
          return const FakePtpReply(PtpResponseCode.devicePropNotSupported);
        } else if (devicePropValueCode != PtpResponseCode.ok) {
          return FakePtpReply(devicePropValueCode);
        }
        return FakePtpReply(PtpResponseCode.ok, data: value);
      case PtpOperation.setDevicePropValue:
        if (dataOut == null) {
          return const FakePtpReply(PtpResponseCode.generalError);
        }
        devicePropertyValues[p[0]] = dataOut;
        return const FakePtpReply(PtpResponseCode.ok);
      case CanonEosOperation.setDevicePropValueEx:
        return _setCanonProperty(dataOut);
      case CanonEosOperation.getViewFinderData:
        return _viewFinderData();
      case CanonEosOperation.remoteReleaseOn ||
          CanonEosOperation.remoteReleaseOff ||
          CanonEosOperation.zoom ||
          CanonEosOperation.zoomPosition ||
          CanonEosOperation.doAf ||
          CanonEosOperation.setLiveAfFrame:
        vendorCalls.add((opcode: opcode, params: p, dataOut: dataOut));
        if (opcode == CanonEosOperation.remoteReleaseOn &&
            p.firstOrNull == CanonRemoteRelease.fullPress) {
          _capture();
        }
        return const FakePtpReply(PtpResponseCode.ok);
      case CanonEosOperation.getEvent:
        return FakePtpReply(PtpResponseCode.ok, data: _eventData());
      case PtpOperation.closeSession ||
          CanonEosOperation.setRemoteMode ||
          CanonEosOperation.setEventMode:
        return const FakePtpReply(PtpResponseCode.ok);
      default:
        return const FakePtpReply(PtpResponseCode.operationNotSupported);
    }
  }

  /// A shot written to the card: StorageInfoChanged, then the new object.
  void _capture() {
    final handle = _firstCapturedHandle + _capturedCount++;
    queueEventRecord(storageChangedRecord(fakeStorageId));
    addObject(
      FakeObject(
        handle: handle,
        format: PtpObjectFormat.exifJpeg,
        filename: 'IMG_${handle.toString().padLeft(4, '0')}.JPG',
        parent: folderHandle,
        content: patternBytes(jpegSize, seed: handle),
        thumbnail: patternBytes(100, seed: handle),
      ),
    );
  }

  FakePtpReply _setCanonProperty(Uint8List? dataOut) {
    if (dataOut == null || dataOut.length != _canonPropertyPayloadSize) {
      return const FakePtpReply(PtpResponseCode.generalError);
    }
    canonPropertyPayloads.add(dataOut);
    final view = ByteData.sublistView(dataOut);
    final property = view.getUint32(_u32Size, Endian.little);
    final value = view.getUint32(2 * _u32Size, Endian.little);
    canonProperties[property] = value;
    if (echoCanonProperties) {
      queueEventRecord(propertyChangedRecord(property, value));
    }
    return const FakePtpReply(PtpResponseCode.ok);
  }

  FakePtpReply _viewFinderData() {
    if (viewFinderCodes.isNotEmpty) {
      return FakePtpReply(viewFinderCodes.removeFirst());
    }
    final output = canonProperties[CanonEosProperty.evfOutputDevice] ?? 0;
    if ((output & CanonEvfOutput.pc) == 0 || liveViewFrames.isEmpty) {
      return const FakePtpReply(CanonEosResponseCode.deviceNotReady);
    }
    final data = PtpDataWriter()
      ..bytes(
        viewFinderRecord(
          fakeViewFinderInfoRecordType,
          Uint8List(_fakeViewFinderInfoLength),
        ),
      )
      ..bytes(
        viewFinderRecord(
          CanonViewFinder.jpegRecordType,
          liveViewFrames.removeFirst(),
        ),
      );
    return FakePtpReply(PtpResponseCode.ok, data: data.toBytes());
  }

  Uint8List _eventData() {
    final first = getEventCount++ == 0;
    final override = eventDataOverride;
    if (override != null) {
      return override;
    }
    final events = PtpDataWriter();
    final dump = initialDump;
    if (first && dump != null) {
      events.bytes(dump);
    }
    final records = eventRecords;
    if (records != null) {
      events.bytes(records);
    }
    _pendingEvents
      ..forEach(events.bytes)
      ..clear();
    events
      ..u32(canonEventHeaderSize)
      ..u32(CanonEosEvent.terminator);
    return events.toBytes();
  }

  final PtpDeviceInfo? _deviceInfo;

  /// An EOS R unless the test passes another camera.
  PtpDeviceInfo get deviceInfo => _deviceInfo ?? _eosDeviceInfo;

  PtpDeviceInfo get _eosDeviceInfo => PtpDeviceInfo(
    standardVersion: 100,
    vendorExtensionId: _canonVendorExtensionId,
    vendorExtensionVersion: 100,
    vendorExtensionDesc: 'microsoft.com: 1.0',
    functionalMode: 0,
    operationsSupported: supportedOperations,
    eventsSupported: const [],
    devicePropertiesSupported: devicePropertyValues.keys.toList(),
    captureFormats: const [],
    imageFormats: const [PtpObjectFormat.exifJpeg, CanonObjectFormat.cr3],
    manufacturer: 'Canon Inc.',
    model: 'Canon EOS R',
    deviceVersion: '1-1.8.0',
    serialNumber: '123456789',
  );

  static Uint8List _u32Array(List<int> values) =>
      (PtpDataWriter()..u32Array(values)).toBytes();
}
