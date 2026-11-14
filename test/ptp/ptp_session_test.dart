import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptp/camera_client.dart';
import 'package:shutterlink/ptp/ptp_constants.dart';
import 'package:shutterlink/ptp/ptp_session.dart';
import 'package:shutterlink/ptp/ptp_transport.dart';

const _sessionTimeout = Duration(milliseconds: 50);
const _slowAnswer = Duration(milliseconds: 150);

/// Answers every command after [delay], reporting no progress meanwhile.
class _SlowTransport implements PtpTransport {
  _SlowTransport(this.delay, {this.minimumResponseTimeout});

  final Duration delay;
  final _disconnected = Completer<void>();
  Object? _cause;

  @override
  final Duration? minimumResponseTimeout;

  @override
  Future<PtpTransactionResult> transact(
    int opcode,
    List<int> params,
    int transactionId,
  ) async {
    await Future.any([Future<void>.delayed(delay), _disconnected.future]);
    if (!isConnected) {
      throw CameraDisconnectedException(_cause);
    }
    return PtpTransactionResult(
      code: PtpResponseCode.ok,
      params: const [],
      data: Uint8List(0),
    );
  }

  @override
  Stream<PtpEvent> get events => const Stream.empty();

  @override
  Future<void> get disconnected => _disconnected.future;

  @override
  bool get isConnected => !_disconnected.isCompleted;

  @override
  Object? get disconnectCause => _cause;

  @override
  set onActivity(void Function()? callback) {}

  @override
  void abort(Object cause) {
    if (isConnected) {
      _cause = cause;
      _disconnected.complete();
    }
  }

  @override
  void close() => abort(StateError('closed'));
}

void main() {
  test('a transport without progress lifts the response timeout', () async {
    final session = PtpSession(
      _SlowTransport(_slowAnswer, minimumResponseTimeout: _slowAnswer * 2),
      responseTimeout: _sessionTimeout,
    );
    final result = await session.execute(PtpOperation.getStorageIds);
    expect(result.code, PtpResponseCode.ok);
  });

  test('the session timeout holds when the transport sets none', () async {
    final transport = _SlowTransport(_slowAnswer);
    final session = PtpSession(transport, responseTimeout: _sessionTimeout);
    await expectLater(
      session.execute(PtpOperation.getStorageIds),
      throwsA(isA<CameraDisconnectedException>()),
    );
    expect(transport.disconnectCause, isA<TimeoutException>());
  });
}
