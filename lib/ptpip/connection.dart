import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'camera_client.dart';
import 'canon_eos.dart';
import 'packet.dart';
import 'packet_reader.dart';

const ptpIpDefaultPort = 15740;
const ptpIpDefaultConnectTimeout = Duration(seconds: 5);
const ptpIpDefaultPairingTimeout = Duration(seconds: 60);
const _busyInitFailReasons = {
  PtpIpInitFailReason.busy,
  PtpResponseCode.deviceBusy,
};
const _eventConnectAttempts = 3;
const _eventConnectRetryDelay = Duration(milliseconds: 100);

enum PtpIpChannel { command, event }

enum PacketDirection { sent, received }

typedef PacketTap = void Function(
  PtpIpChannel channel,
  PacketDirection direction,
  Uint8List frame,
);

class PtpIpProtocolException implements Exception {
  const PtpIpProtocolException(this.message);

  final String message;

  @override
  String toString() => 'PtpIpProtocolException: $message';
}

class PtpIpConnection {
  PtpIpConnection._(this._tap);

  final PacketTap? _tap;
  final _commandPackets = StreamController<PtpIpPacket>();
  final _eventPackets = StreamController<EventPacket>.broadcast();
  final _disconnected = Completer<void>();
  final _sockets = <PtpIpChannel, Socket>{};
  Completer<PtpIpPacket>? _handshakeReply;
  Object? _disconnectCause;
  bool _handshakeDone = false;
  bool _closed = false;

  late final InitCommandAck commandAck;

  void Function()? onCommandBytes;

  Stream<PtpIpPacket> get commandPackets => _commandPackets.stream;

  Stream<EventPacket> get events => _eventPackets.stream;

  Future<void> get disconnected => _disconnected.future;

  bool get isConnected => !_closed;

  Object? get disconnectCause => _disconnectCause;

  static Future<PtpIpConnection> open({
    required String host,
    int port = ptpIpDefaultPort,
    required CameraIdentity identity,
    Duration timeout = ptpIpDefaultConnectTimeout,
    Duration pairingTimeout = ptpIpDefaultPairingTimeout,
    PacketTap? tap,
  }) async {
    final connection = PtpIpConnection._(tap);
    try {
      await connection._handshake(
        host,
        port,
        identity,
        timeout,
        pairingTimeout,
      );
      return connection;
    } catch (error) {
      connection.close();
      if (error is PairingRequiredException ||
          error is CameraBusyException ||
          error is CameraDisconnectedException) {
        rethrow;
      }
      throw CameraDisconnectedException(error);
    }
  }

  Future<void> _handshake(
    String host,
    int port,
    CameraIdentity identity,
    Duration timeout,
    Duration pairingTimeout,
  ) async {
    await _attach(
      PtpIpChannel.command,
      await Socket.connect(host, port, timeout: timeout),
    );
    final PtpIpPacket ack;
    try {
      ack = await _request(
        PtpIpChannel.command,
        InitCommandRequest(guid: identity.guid, name: identity.name),
        pairingTimeout,
      );
    } on CameraDisconnectedException {
      // A real EOS R resets the connection instead of sending InitFail when
      // it does not know the GUID and is not waiting to pair.
      throw const PairingRequiredException();
    }
    if (ack is! InitCommandAck) {
      throw PtpIpProtocolException('Expected InitCommandAck, got $ack');
    }
    commandAck = ack;

    await _attach(PtpIpChannel.event, await _connectEvent(host, port, timeout));
    final eventAck = await _request(
      PtpIpChannel.event,
      InitEventRequest(ack.connectionNumber),
      timeout,
    );
    if (eventAck is! InitEventAck) {
      throw PtpIpProtocolException('Expected InitEventAck, got $eventAck');
    }
    _handshakeDone = true;
  }

  Future<Socket> _connectEvent(String host, int port, Duration timeout) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await Socket.connect(host, port, timeout: timeout);
      } on SocketException {
        if (attempt >= _eventConnectAttempts) {
          rethrow;
        }
        await Future<void>.delayed(_eventConnectRetryDelay);
      }
    }
  }

  Future<PtpIpPacket> _request(
    PtpIpChannel channel,
    PtpIpPacket packet,
    Duration timeout,
  ) async {
    final reply = _handshakeReply = Completer<PtpIpPacket>();
    send(packet, channel: channel);
    final response = await reply.future.timeout(timeout);
    if (response is InitFail) {
      throw _busyInitFailReasons.contains(response.reason)
          ? CameraBusyException(response.reason)
          : PairingRequiredException(response.reason);
    }
    return response;
  }

  Future<void> _attach(PtpIpChannel channel, Socket socket) async {
    if (!isConnected) {
      socket.destroy();
      throw CameraDisconnectedException(_disconnectCause);
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    _sockets[channel] = socket;
    socket.done.catchError((Object error) => _fail(error));
    final tap = _tap;
    final bytes = channel == PtpIpChannel.command
        ? socket.map((chunk) {
            onCommandBytes?.call();
            return chunk;
          })
        : socket;
    var frames = bytes.transform(const PtpIpFrameReader());
    if (tap != null) {
      frames = frames.map((frame) {
        tap(channel, PacketDirection.received, frame);
        return frame;
      });
    }
    frames
        .map(PtpIpPacket.decode)
        .listen(
          (packet) => _onPacket(channel, packet),
          onError: _fail,
          onDone: () => _fail(const SocketException('Connection closed')),
          cancelOnError: true,
        );
  }

  void _onPacket(PtpIpChannel channel, PtpIpPacket packet) {
    if (packet is PingPacket) {
      send(const PongPacket(), channel: channel);
      return;
    }
    if (!_handshakeDone) {
      final reply = _handshakeReply;
      _handshakeReply = null;
      reply?.complete(packet);
      return;
    }
    if (channel == PtpIpChannel.event) {
      if (packet is EventPacket) {
        _eventPackets.add(packet);
      }
      return;
    }
    _commandPackets.add(packet);
  }

  void send(PtpIpPacket packet, {PtpIpChannel channel = PtpIpChannel.command}) {
    final socket = _sockets[channel];
    if (!isConnected || socket == null) {
      throw CameraDisconnectedException(_disconnectCause);
    }
    final frame = packet.encode();
    _tap?.call(channel, PacketDirection.sent, frame);
    socket.add(frame);
  }

  void abort(Object cause) => _fail(cause);

  void close() => _fail(null);

  void _fail(Object? cause) {
    if (_closed) {
      return;
    }
    _closed = true;
    _disconnectCause = cause;
    for (final socket in _sockets.values) {
      socket.destroy();
    }
    _handshakeReply?.completeError(CameraDisconnectedException(cause));
    _handshakeReply = null;
    _disconnected.complete();
    _commandPackets.close();
    _eventPackets.close();
  }
}
