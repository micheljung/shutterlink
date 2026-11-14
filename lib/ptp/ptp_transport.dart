import 'dart:typed_data';

const ptpMaxDataInLength = 64 * 1024 * 1024;

class PtpTransactionResult {
  const PtpTransactionResult({
    required this.code,
    required this.params,
    required this.data,
  });

  final int code;
  final List<int> params;
  final Uint8List data;
}

/// A standard PTP event as the camera pushes it, outside any transaction.
class PtpEvent {
  const PtpEvent({
    required this.code,
    required this.transactionId,
    this.params = const [],
  });

  final int code;
  final int transactionId;
  final List<int> params;
}

/// Moves whole PTP transactions over one wire. Framing is the transport's;
/// queueing and timeouts are `PtpSession`'s.
abstract interface class PtpTransport {
  /// Sends one command and completes with its data-in phase and response.
  /// Fails with `CameraDisconnectedException` once the transport is down.
  Future<PtpTransactionResult> transact(
    int opcode,
    List<int> params,
    int transactionId,
  );

  Stream<PtpEvent> get events;

  Future<void> get disconnected;

  bool get isConnected;

  Object? get disconnectCause;

  /// Called on every non-empty read, so a slow transfer stays alive.
  set onActivity(void Function()? callback);

  /// A floor for the session's response timeout, for transports that report
  /// no progress while a transaction runs. Null keeps the session's.
  Duration? get minimumResponseTimeout;

  void abort(Object cause);

  void close();
}
