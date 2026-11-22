import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptp/camera_client.dart';
import 'package:shutterlink/ptp/ptp_constants.dart';
import 'package:shutterlink/ptp/ptp_session.dart';
import 'package:shutterlink/ptp/ptp_transport.dart';

const _sessionTimeout = Duration(milliseconds: 50);
const _slowAnswer = Duration(milliseconds: 150);
const _firstBytes = Duration(milliseconds: 20);
const _overhead = Duration(microseconds: 1234);

/// Answers every command after [delay], reporting no progress meanwhile
/// unless [bytesAfter] is set.
class _SlowTransport implements PtpTransport {
  _SlowTransport(
    this.delay, {
    this.minimumResponseTimeout,
    this.bytesAfter,
    this.channelOverhead,
    this.overheadTransactionShift = 0,
  });

  final Duration delay;
  final Duration? bytesAfter;
  final Duration? channelOverhead;
  final int overheadTransactionShift;
  final _disconnected = Completer<void>();
  final dataOuts = <Uint8List?>[];
  void Function()? _onActivity;
  void Function(int transactionId, Duration channelOverhead)? transferTiming;
  Object? _cause;

  @override
  final Duration? minimumResponseTimeout;

  @override
  Future<PtpTransactionResult> transact(
    int opcode,
    List<int> params,
    int transactionId, {
    Uint8List? dataOut,
  }) async {
    dataOuts.add(dataOut);
    final firstBytes = bytesAfter;
    if (firstBytes != null) {
      Timer(firstBytes, () => _onActivity?.call());
    }
    await Future.any([Future<void>.delayed(delay), _disconnected.future]);
    if (!isConnected) {
      throw CameraDisconnectedException(_cause);
    }
    final overhead = channelOverhead;
    if (overhead != null) {
      transferTiming?.call(transactionId + overheadTransactionShift, overhead);
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
  set onActivity(void Function()? callback) => _onActivity = callback;

  @override
  set onTransferTiming(
    void Function(int transactionId, Duration channelOverhead)? callback,
  ) => transferTiming = callback;

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

  group('per-call timeout', () {
    test('lifts the session timeout for one call', () async {
      final session = PtpSession(
        _SlowTransport(_slowAnswer),
        responseTimeout: _sessionTimeout,
      );
      final result = await session.execute(
        PtpOperation.getStorageIds,
        timeout: _slowAnswer * 2,
      );
      expect(result.code, PtpResponseCode.ok);
      final low = await session.executeLowPriority(
        PtpOperation.getStorageIds,
        timeout: _slowAnswer * 2,
      );
      expect(low.code, PtpResponseCode.ok);
    });

    test('shortens the session timeout for one call', () async {
      final transport = _SlowTransport(_slowAnswer);
      final session = PtpSession(transport, responseTimeout: _slowAnswer * 2);
      await expectLater(
        session.execute(PtpOperation.getStorageIds, timeout: _sessionTimeout),
        throwsA(isA<CameraDisconnectedException>()),
      );
      expect(transport.disconnectCause, isA<TimeoutException>());
    });

    test('applies to its call only', () async {
      final transport = _SlowTransport(_slowAnswer);
      final session = PtpSession(transport, responseTimeout: _sessionTimeout);
      await session.execute(
        PtpOperation.getStorageIds,
        timeout: _slowAnswer * 2,
      );
      await expectLater(
        session.execute(PtpOperation.getStorageIds),
        throwsA(isA<CameraDisconnectedException>()),
      );
    });
  });

  test('hands the data-out phase to the transport', () async {
    final transport = _SlowTransport(Duration.zero);
    final session = PtpSession(transport);
    final value = Uint8List.fromList([1, 2, 3, 4]);
    await session.execute(PtpOperation.setDevicePropValue, dataOut: value);
    await session.executeLowPriority(
      PtpOperation.setDevicePropValue,
      dataOut: value,
    );
    await session.execute(PtpOperation.getStorageIds);
    expect(transport.dataOuts, [value, value, null]);
  });

  group('timing tap', () {
    test('reports first byte, response and channel overhead', () async {
      final transport = _SlowTransport(
        _slowAnswer,
        bytesAfter: _firstBytes,
        channelOverhead: _overhead,
      );
      final session = PtpSession(transport, responseTimeout: _slowAnswer * 2);
      final timings = <(int, PtpTiming)>[];
      final before = DateTime.now();
      session.onTiming = (id, timing) => timings.add((id, timing));
      expect(transport.transferTiming, isNotNull);

      await session.execute(PtpOperation.getStorageIds);
      await session.execute(PtpOperation.getStorageIds);

      expect([for (final (id, _) in timings) id], [1, 2]);
      final (_, timing) = timings.first;
      expect(timing.requestSent.isBefore(before), isFalse);
      expect(timing.firstByte, greaterThanOrEqualTo(_firstBytes));
      expect(timing.response, greaterThanOrEqualTo(_slowAnswer));
      expect(timing.firstByte!, lessThan(timing.response));
      expect(timing.channelOverhead, _overhead);
    });

    test('leaves out what the transport does not report', () async {
      final session = PtpSession(_SlowTransport(Duration.zero));
      PtpTiming? reported;
      session.onTiming = (_, timing) => reported = timing;
      await session.execute(PtpOperation.getStorageIds);
      expect(reported!.firstByte, isNull);
      expect(reported!.channelOverhead, isNull);
    });

    test('ignores overhead reported for another transaction', () async {
      final session = PtpSession(
        _SlowTransport(
          Duration.zero,
          channelOverhead: _overhead,
          overheadTransactionShift: 1,
        ),
      );
      PtpTiming? reported;
      session.onTiming = (_, timing) => reported = timing;
      await session.execute(PtpOperation.getStorageIds);
      expect(reported!.channelOverhead, isNull);
    });

    test('reports a rejected response too', () async {
      final session = PtpSession(_SlowTransport(Duration.zero));
      final ids = <int>[];
      session.onTiming = (id, _) => ids.add(id);
      await expectLater(
        session.execute(PtpOperation.getStorageIds, acceptedCodes: const {}),
        throwsA(isA<PtpResponseException>()),
      );
      expect(ids, [1]);
    });

    test('stops when cleared, even mid-transaction', () async {
      final transport = _SlowTransport(_firstBytes);
      final session = PtpSession(transport);
      final ids = <int>[];
      session.onTiming = (id, _) => ids.add(id);
      final pending = session.execute(PtpOperation.getStorageIds);
      session.onTiming = null;
      expect(transport.transferTiming, isNull);
      await pending;
      await session.execute(PtpOperation.getStorageIds);
      expect(ids, isEmpty);
    });

    test('a tap replaced mid-transaction gets no earlier timing', () async {
      final session = PtpSession(_SlowTransport(_firstBytes));
      final old = <int>[];
      final replacement = <int>[];
      session.onTiming = (id, _) => old.add(id);
      final pending = session.execute(PtpOperation.getStorageIds);
      session
        ..onTiming = null
        ..onTiming = (id, _) => replacement.add(id);
      await pending;
      await session.execute(PtpOperation.getStorageIds);
      expect(old, isEmpty);
      expect(replacement, [2]);
    });

    test('has one owner at a time', () {
      final session = PtpSession(_SlowTransport(Duration.zero));
      session.onTiming = (_, _) {};
      expect(
        () => session.onTiming = (_, _) {},
        throwsA(isA<AssertionError>()),
      );
      session
        ..onTiming = null
        ..onTiming = (_, _) {};
    });
  });
}
