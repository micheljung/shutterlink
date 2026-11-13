import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:shutterlink/ptpip/ptpip.dart';

const fakeStorageId = 0x00020001;
const fakeConnectionNumber = 7;
const fakeInitFailReason = PtpIpInitFailReason.rejectedInitiator;
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

final fakeCameraGuid = Uint8List.fromList(
  List.generate(ptpIpGuidSize, (i) => i),
);

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

Uint8List patternBytes(int length, {int seed = 1}) {
  final random = Random(seed);
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

class FakeCamera {
  FakeCamera({
    this.pairedGuids,
    List<FakeObject>? objects,
    this.maxFragmentSize,
    this.dataPacketSize = 64 * 1024,
    this.responseDelay = Duration.zero,
    this.dropAfterPartialBytes,
    this.supportedOperations = defaultOperations,
    this.sendPingAfterHandshake = false,
    this.ignoreInitCommand = false,
    this.openSessionCode = PtpResponseCode.ok,
    this.initFailReason = fakeInitFailReason,
    this.initAckDelay = Duration.zero,
    this.trickleDelay,
    this.eventRecords,
    this.initialDump,
    this.eventDataOverride,
  }) : objects = objects ?? defaultObjects();

  static const defaultOperations = [
    PtpOperation.getDeviceInfo,
    PtpOperation.openSession,
    PtpOperation.closeSession,
    PtpOperation.getStorageIds,
    PtpOperation.getObjectHandles,
    PtpOperation.getObjectInfo,
    PtpOperation.getThumb,
    PtpOperation.getPartialObject,
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
      format: PtpObjectFormat.canonCr3,
      filename: 'IMG_0001.CR3',
      parent: folderHandle,
      captureDate: '20240102T030405',
      content: patternBytes(rawSize, seed: rawHandle),
    ),
    FakeObject(
      handle: videoHandle,
      format: PtpObjectFormat.canonMov,
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

  final List<Uint8List>? pairedGuids;
  final List<FakeObject> objects;
  final int? maxFragmentSize;
  final int dataPacketSize;
  final Duration responseDelay;
  final int? dropAfterPartialBytes;
  final List<int> supportedOperations;
  final bool sendPingAfterHandshake;
  final bool ignoreInitCommand;
  final int openSessionCode;
  final int initFailReason;
  final Duration initAckDelay;
  final Duration? trickleDelay;
  final Uint8List? eventRecords;
  final Uint8List? initialDump;
  Uint8List? eventDataOverride;
  final _pendingEvents = <Uint8List>[];
  int getEventCount = 0;

  final receivedOpcodes = <int>[];
  final receivedRequests = <CommandRequest>[];
  final receivedNames = <String>[];
  int pongsReceived = 0;
  int maxConcurrentRequests = 0;
  int _inFlight = 0;
  int _partialBytesSent = 0;
  bool silent = false;
  final _random = Random(42);
  final _sockets = <Socket>[];
  Socket? _commandSocket;
  Socket? _eventSocket;
  late final ServerSocket _server;

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_onClient);
  }

  Future<void> stop() async {
    dropConnection();
    await _server.close();
  }

  void addObject(FakeObject object, {bool sixtyFourBit = false}) {
    objects.add(object);
    queueEventRecord(objectAddedRecord(object, sixtyFourBit: sixtyFourBit));
  }

  void queueEventRecord(Uint8List record) => _pendingEvents.add(record);

  void sendEvent(int code) =>
      _write(_eventSocket!, EventPacket(code: code, transactionId: 0));

  void dropConnection() {
    for (final socket in _sockets) {
      socket.destroy();
    }
  }

  void _onClient(Socket socket) {
    _sockets.add(socket);
    socket.done.ignore();
    socket
        .transform(const PtpIpPacketReader())
        .listen(
          (packet) => _onPacket(socket, packet),
          onError: (_) => socket.destroy(),
        );
  }

  void _write(Socket socket, PtpIpPacket packet) {
    if (silent) {
      return;
    }
    final frame = packet.encode();
    final maxFragment = maxFragmentSize;
    if (maxFragment == null) {
      socket.add(frame);
      return;
    }
    final fragments = <Uint8List>[];
    var offset = 0;
    while (offset < frame.length) {
      final size = min(1 + _random.nextInt(maxFragment), frame.length - offset);
      fragments.add(Uint8List.sublistView(frame, offset, offset + size));
      offset += size;
    }
    final delay = trickleDelay;
    if (delay == null) {
      fragments.forEach(socket.add);
      return;
    }
    _trickle = _trickle.then((_) async {
      for (final fragment in fragments) {
        if (silent) {
          return;
        }
        socket.add(fragment);
        await Future<void>.delayed(delay);
      }
    });
  }

  Future<void> _trickle = Future.value();

  void _onPacket(Socket socket, PtpIpPacket packet) {
    if (silent) {
      return;
    }
    switch (packet) {
      case InitCommandRequest(:final guid, :final name):
        receivedNames.add(name);
        if (ignoreInitCommand) {
          return;
        }
        final paired = pairedGuids;
        if (paired != null &&
            !paired.any((g) => const ListEquality<int>().equals(g, guid))) {
          _write(socket, InitFail(initFailReason));
          return;
        }
        _commandSocket = socket;
        Timer(
          initAckDelay,
          () => _write(
            socket,
            InitCommandAck(
              connectionNumber: fakeConnectionNumber,
              guid: fakeCameraGuid,
              name: 'Canon EOS R',
            ),
          ),
        );
      case InitEventRequest(:final connectionNumber):
        if (connectionNumber != fakeConnectionNumber) {
          _write(socket, const InitFail(fakeInitFailReason));
          return;
        }
        _eventSocket = socket;
        _write(socket, const InitEventAck());
        if (sendPingAfterHandshake) {
          _write(socket, const PingPacket());
          _write(_commandSocket!, const PingPacket());
        }
      case PongPacket():
        pongsReceived++;
      case CommandRequest():
        receivedOpcodes.add(packet.opcode);
        receivedRequests.add(packet);
        _inFlight++;
        maxConcurrentRequests = max(maxConcurrentRequests, _inFlight);
        if (responseDelay == Duration.zero) {
          _handle(socket, packet);
        } else {
          Timer(responseDelay, () => _handle(socket, packet));
        }
      default:
    }
  }

  void _handle(Socket socket, CommandRequest request) {
    _inFlight--;
    final txid = request.transactionId;
    void respond(int code, [Uint8List? data]) {
      if (data != null) {
        _sendData(socket, txid, data);
      }
      _write(socket, CommandResponse(code: code, transactionId: txid));
    }

    final p = request.params;
    FakeObject? object(int handle) =>
        objects.firstWhereOrNull((o) => o.handle == handle);
    switch (request.opcode) {
      case PtpOperation.openSession:
        respond(openSessionCode);
      case PtpOperation.getDeviceInfo:
        respond(PtpResponseCode.ok, deviceInfo.encode());
      case PtpOperation.getStorageIds:
        respond(PtpResponseCode.ok, _u32Array([fakeStorageId]));
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
        respond(PtpResponseCode.ok, _u32Array(handles));
      case PtpOperation.getObjectInfo:
        final o = object(p[0]);
        o == null
            ? respond(PtpResponseCode.invalidObjectHandle)
            : respond(PtpResponseCode.ok, o.info.encode());
      case PtpOperation.getThumb:
        final thumb = object(p[0])?.thumbnail;
        thumb == null
            ? respond(PtpResponseCode.noThumbnailPresent)
            : respond(PtpResponseCode.ok, thumb);
      case PtpOperation.getPartialObject:
        final o = object(p[0]);
        if (o == null) {
          respond(PtpResponseCode.invalidObjectHandle);
          return;
        }
        final start = min(p[1], o.content.length);
        final end = min(start + p[2], o.content.length);
        final drop = dropAfterPartialBytes;
        if (drop != null && _partialBytesSent + end - start > drop) {
          dropConnection();
          return;
        }
        _partialBytesSent += end - start;
        respond(
          PtpResponseCode.ok,
          Uint8List.sublistView(o.content, start, end),
        );
      case CanonEosOperation.getEvent:
        respond(PtpResponseCode.ok, _eventData());
      case PtpOperation.closeSession ||
          CanonEosOperation.setRemoteMode ||
          CanonEosOperation.setEventMode:
        respond(PtpResponseCode.ok);
      default:
        respond(PtpResponseCode.operationNotSupported);
    }
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

  void _sendData(Socket socket, int txid, Uint8List data) {
    _write(socket, StartData(transactionId: txid, totalLength: data.length));
    var offset = 0;
    while (data.length - offset > dataPacketSize) {
      _write(
        socket,
        DataPacket(
          transactionId: txid,
          payload: Uint8List.sublistView(data, offset, offset + dataPacketSize),
        ),
      );
      offset += dataPacketSize;
    }
    _write(
      socket,
      EndDataPacket(
        transactionId: txid,
        payload: Uint8List.sublistView(data, offset),
      ),
    );
  }

  PtpDeviceInfo get deviceInfo => PtpDeviceInfo(
    standardVersion: 100,
    vendorExtensionId: _canonVendorExtensionId,
    vendorExtensionVersion: 100,
    vendorExtensionDesc: 'microsoft.com: 1.0',
    functionalMode: 0,
    operationsSupported: supportedOperations,
    eventsSupported: const [],
    devicePropertiesSupported: const [],
    captureFormats: const [],
    imageFormats: const [PtpObjectFormat.exifJpeg, PtpObjectFormat.canonCr3],
    manufacturer: 'Canon Inc.',
    model: 'Canon EOS R',
    deviceVersion: '1-1.8.0',
    serialNumber: '123456789',
  );

  static Uint8List _u32Array(List<int> values) =>
      (PtpDataWriter()..u32Array(values)).toBytes();
}

final pairedGuid = Uint8List.fromList(
  List.generate(ptpIpGuidSize, (i) => 0xA0 + i),
);

final pairedIdentity = CameraIdentity(guid: pairedGuid, name: 'Shutterlink');

const testResponseTimeout = Duration(milliseconds: 500);
const testPollInterval = Duration(milliseconds: 50);

Future<PtpIpCameraClient> connectTo(
  FakeCamera camera, {
  CameraIdentity? identity,
  Duration eventPollInterval = testPollInterval,
  PacketTap? packetTap,
}) => PtpIpCameraClient.connect(
  host: InternetAddress.loopbackIPv4.address,
  port: camera.port,
  identity: identity ?? pairedIdentity,
  timeout: const Duration(seconds: 2),
  responseTimeout: testResponseTimeout,
  eventPollInterval: eventPollInterval,
  packetTap: packetTap,
);
