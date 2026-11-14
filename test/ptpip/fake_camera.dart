import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:shutterlink/ptpip/ptpip.dart';

import '../fakes/fake_ptp_device.dart';

export '../fakes/fake_ptp_device.dart';

const fakeConnectionNumber = 7;
const fakeInitFailReason = PtpIpInitFailReason.rejectedInitiator;

final fakeCameraGuid = Uint8List.fromList(
  List.generate(ptpIpGuidSize, (i) => i),
);

/// A [FakePtpDevice] behind a PTP/IP socket.
class FakeCamera {
  FakeCamera({
    this.pairedGuids,
    List<FakeObject>? objects,
    this.maxFragmentSize,
    this.dataPacketSize = 64 * 1024,
    this.responseDelay = Duration.zero,
    int? dropAfterPartialBytes,
    List<int> supportedOperations = defaultOperations,
    this.sendPingAfterHandshake = false,
    this.ignoreInitCommand = false,
    int openSessionCode = PtpResponseCode.ok,
    this.initFailReason = fakeInitFailReason,
    this.resetUnknownGuid = false,
    this.initAckDelay = Duration.zero,
    this.trickleDelay,
    Uint8List? eventRecords,
    Uint8List? initialDump,
    Uint8List? eventDataOverride,
    Map<int, Uint8List>? devicePropertyValues,
    int devicePropValueCode = PtpResponseCode.ok,
    int? deleteDeniedCode,
    int deleteBusyResponses = 0,
    PtpDeviceInfo? deviceInfo,
  }) : device = FakePtpDevice(
         objects: objects,
         dropAfterPartialBytes: dropAfterPartialBytes,
         supportedOperations: supportedOperations,
         openSessionCode: openSessionCode,
         eventRecords: eventRecords,
         initialDump: initialDump,
         eventDataOverride: eventDataOverride,
         devicePropertyValues: devicePropertyValues,
         devicePropValueCode: devicePropValueCode,
         deleteDeniedCode: deleteDeniedCode,
         deleteBusyResponses: deleteBusyResponses,
         deviceInfo: deviceInfo,
       );

  static const defaultOperations = FakePtpDevice.defaultOperations;
  static const dcimHandle = FakePtpDevice.dcimHandle;
  static const folderHandle = FakePtpDevice.folderHandle;
  static const jpegHandle = FakePtpDevice.jpegHandle;
  static const rawHandle = FakePtpDevice.rawHandle;
  static const videoHandle = FakePtpDevice.videoHandle;
  static const largeJpegHandle = FakePtpDevice.largeJpegHandle;
  static const rootJpegHandle = FakePtpDevice.rootJpegHandle;
  static const jpegSize = FakePtpDevice.jpegSize;
  static const rawSize = FakePtpDevice.rawSize;
  static const largeSize = FakePtpDevice.largeSize;

  static List<FakeObject> defaultObjects() => FakePtpDevice.defaultObjects();

  final FakePtpDevice device;
  final List<Uint8List>? pairedGuids;
  final int? maxFragmentSize;
  final int dataPacketSize;
  final Duration responseDelay;
  final bool sendPingAfterHandshake;
  final bool ignoreInitCommand;
  final int initFailReason;

  /// Reset the connection for an unknown GUID, as a real EOS R does, instead
  /// of answering InitFail.
  final bool resetUnknownGuid;
  final Duration initAckDelay;
  final Duration? trickleDelay;

  final receivedRequests = <CommandRequest>[];
  final receivedNames = <String>[];
  int pongsReceived = 0;
  int maxConcurrentRequests = 0;
  int _inFlight = 0;
  bool silent = false;
  final _random = Random(42);
  final _sockets = <Socket>[];
  Socket? _commandSocket;
  Socket? _eventSocket;
  late final ServerSocket _server;

  List<FakeObject> get objects => device.objects;
  Map<int, Uint8List> get devicePropertyValues => device.devicePropertyValues;
  List<int> get receivedOpcodes => device.receivedOpcodes;
  int? get dropAfterPartialBytes => device.dropAfterPartialBytes;
  List<int> get supportedOperations => device.supportedOperations;
  int get openSessionCode => device.openSessionCode;
  Uint8List? get eventRecords => device.eventRecords;
  Uint8List? get initialDump => device.initialDump;
  int get devicePropValueCode => device.devicePropValueCode;
  int? get deleteDeniedCode => device.deleteDeniedCode;
  int get getEventCount => device.getEventCount;
  set getEventCount(int value) => device.getEventCount = value;
  PtpDeviceInfo get deviceInfo => device.deviceInfo;
  Uint8List? get eventDataOverride => device.eventDataOverride;
  set eventDataOverride(Uint8List? value) => device.eventDataOverride = value;
  int get deleteBusyResponses => device.deleteBusyResponses;
  set deleteBusyResponses(int value) => device.deleteBusyResponses = value;

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_onClient);
  }

  Future<void> stop() async {
    dropConnection();
    await _server.close();
  }

  void addObject(FakeObject object, {bool sixtyFourBit = false}) =>
      device.addObject(object, sixtyFourBit: sixtyFourBit);

  void removeObject(int handle) => device.removeObject(handle);

  void queueEventRecord(Uint8List record) => device.queueEventRecord(record);

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
          if (resetUnknownGuid) {
            socket.destroy();
            return;
          }
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
        device.receivedOpcodes.add(packet.opcode);
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
    final reply = device.handle(request.opcode, request.params);
    final data = reply.data;
    final drop = reply.dropAfterBytes;
    if (drop != null) {
      if (data != null && drop > 0) {
        _write(
          socket,
          StartData(transactionId: txid, totalLength: data.length),
        );
        _write(
          socket,
          DataPacket(
            transactionId: txid,
            payload: Uint8List.sublistView(data, 0, min(drop, data.length)),
          ),
        );
      }
      dropConnection();
      return;
    }
    if (data != null) {
      _sendData(socket, txid, data);
    }
    _write(
      socket,
      CommandResponse(
        code: reply.code,
        transactionId: txid,
        params: reply.params,
      ),
    );
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
