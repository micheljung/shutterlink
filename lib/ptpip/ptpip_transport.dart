import 'dart:async';
import 'dart:typed_data';

import '../ptp/camera_client.dart';
import '../ptp/ptp_transport.dart';
import 'connection.dart';
import 'packet.dart';

class PtpIpTransport implements PtpTransport {
  PtpIpTransport(this._connection) {
    _connection.commandPackets.listen(_onPacket);
    _connection.onCommandBytes = () => _onActivity?.call();
    _connection.disconnected.then((_) => _abortCurrent());
  }

  final PtpIpConnection _connection;
  void Function()? _onActivity;
  _Transaction? _current;

  @override
  Stream<PtpEvent> get events => _connection.events.map(
    (packet) => PtpEvent(
      code: packet.code,
      transactionId: packet.transactionId,
      params: packet.params,
    ),
  );

  @override
  Future<void> get disconnected => _connection.disconnected;

  @override
  bool get isConnected => _connection.isConnected;

  @override
  Object? get disconnectCause => _connection.disconnectCause;

  @override
  set onActivity(void Function()? callback) => _onActivity = callback;

  @override
  Duration? get minimumResponseTimeout => null;

  @override
  Future<PtpTransactionResult> transact(
    int opcode,
    List<int> params,
    int transactionId,
  ) async {
    if (!_connection.isConnected) {
      throw CameraDisconnectedException(_connection.disconnectCause);
    }
    final transaction = _current = _Transaction(opcode, transactionId);
    try {
      _connection.send(
        CommandRequest(
          opcode: opcode,
          transactionId: transactionId,
          params: params,
        ),
      );
      return await transaction.completer.future;
    } finally {
      if (identical(_current, transaction)) {
        _current = null;
      }
    }
  }

  @override
  void abort(Object cause) => _connection.abort(cause);

  @override
  void close() => _connection.close();

  void _onPacket(PtpIpPacket packet) {
    final transaction = _current;
    if (transaction == null || transaction.completer.isCompleted) {
      return;
    }
    try {
      transaction.accept(packet);
    } on PtpIpProtocolException catch (error) {
      _connection.abort(error);
    }
  }

  void _abortCurrent() {
    final transaction = _current;
    if (transaction != null && !transaction.completer.isCompleted) {
      transaction.completer.completeError(
        CameraDisconnectedException(_connection.disconnectCause),
      );
    }
  }
}

class _Transaction {
  _Transaction(this.opcode, this.transactionId);

  final int opcode;
  final int transactionId;
  final completer = Completer<PtpTransactionResult>();
  Uint8List? _data;
  int _filled = 0;

  void accept(PtpIpPacket packet) {
    switch (packet) {
      case StartData(:final transactionId, :final totalLength)
          when transactionId == this.transactionId:
        if (totalLength > ptpMaxDataInLength) {
          throw PtpIpProtocolException('Data phase too large: $totalLength');
        }
        _data = Uint8List(totalLength);
        _filled = 0;
      case DataPacket(:final transactionId, :final payload) ||
              EndDataPacket(:final transactionId, :final payload)
          when transactionId == this.transactionId:
        _append(payload);
      case CommandResponse(:final transactionId, :final code, :final params)
          when transactionId == this.transactionId:
        final data = _data;
        completer.complete(
          PtpTransactionResult(
            code: code,
            params: params,
            data: data == null
                ? Uint8List(0)
                : Uint8List.sublistView(data, 0, _filled),
          ),
        );
      default:
    }
  }

  void _append(Uint8List payload) {
    final data = _data;
    if (data == null || _filled + payload.length > data.length) {
      throw PtpIpProtocolException(
        'Unexpected data for opcode 0x${opcode.toRadixString(16)}',
      );
    }
    data.setRange(_filled, _filled + payload.length, payload);
    _filled += payload.length;
  }
}
