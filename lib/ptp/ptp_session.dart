import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'camera_client.dart';
import 'ptp_constants.dart';
import 'ptp_transport.dart';

const ptpDefaultResponseTimeout = Duration(seconds: 3);
const _openSessionTransactionId = 0;
const _firstTransactionId = 1;
const _maxTransactionId = 0xFFFFFFFE;

/// Where one transaction's time went, measured from the request being
/// handed to the transport.
class PtpTiming {
  const PtpTiming({
    required this.opcode,
    required this.requestSent,
    required this.response,
    this.firstByte,
    this.channelOverhead,
  });

  final int opcode;

  final DateTime requestSent;

  /// Null when the transport reports no received bytes.
  final Duration? firstByte;

  final Duration response;

  /// Null unless the transport measures its platform channel.
  final Duration? channelOverhead;
}

class PtpSession {
  PtpSession(
    this._transport, {
    this.responseTimeout = ptpDefaultResponseTimeout,
  }) {
    _transport.onActivity = _onBytes;
    _transport.disconnected.then((_) => _watchdog?.cancel());
  }

  final PtpTransport _transport;
  final Duration responseTimeout;
  int _nextTransactionId = _firstTransactionId;
  final _queue = Queue<_Job>();
  final _lowPriorityQueue = <_Job>[];
  int _lowPriorityHolds = 0;
  bool _running = false;
  bool _inTransaction = false;
  Duration? _callTimeout;
  Timer? _watchdog;
  void Function(int transactionId, PtpTiming timing)? _onTiming;
  _Measurement? _measurement;

  Future<void> get disconnected => _transport.disconnected;

  /// Reports the timing of every transaction that gets a response. One owner
  /// at a time: clear it before another owner sets it.
  set onTiming(void Function(int transactionId, PtpTiming timing)? callback) {
    assert(
      callback == null || _onTiming == null,
      'PtpSession.onTiming already has an owner',
    );
    _onTiming = callback;
    _measurement = null;
    _transport.onTransferTiming = callback == null ? null : _onTransferTiming;
  }

  Future<void> openSession() => _enqueue(() async {
    await _run(
      PtpOperation.openSession,
      const [PtpHandle.sessionId],
      _openSessionTransactionId,
      const {PtpResponseCode.ok, PtpResponseCode.sessionAlreadyOpen},
    );
    _nextTransactionId = _firstTransactionId;
  });

  /// [timeout] replaces [responseTimeout] for this call only.
  Future<PtpTransactionResult> execute(
    int opcode, {
    List<int> params = const [],
    Set<int> acceptedCodes = const {PtpResponseCode.ok},
    Uint8List? dataOut,
    Duration? timeout,
  }) => _enqueue(
    () => _run(
      opcode,
      params,
      _takeTransactionId(),
      acceptedCodes,
      dataOut: dataOut,
      timeout: timeout,
    ),
  );

  /// [timeout] replaces [responseTimeout] for this call only.
  Future<PtpTransactionResult> executeLowPriority(
    int opcode, {
    List<int> params = const [],
    Set<int> acceptedCodes = const {PtpResponseCode.ok},
    Uint8List? dataOut,
    Duration? timeout,
    CancelToken? cancelToken,
  }) => _enqueue(
    () => _run(
      opcode,
      params,
      _takeTransactionId(),
      acceptedCodes,
      dataOut: dataOut,
      timeout: timeout,
    ),
    lowPriority: true,
    cancelToken: cancelToken,
  );

  void Function() holdLowPriority() {
    _lowPriorityHolds++;
    var released = false;
    return () {
      if (released) {
        return;
      }
      released = true;
      _lowPriorityHolds--;
      _pump();
    };
  }

  int _takeTransactionId() {
    final id = _nextTransactionId;
    _nextTransactionId = id >= _maxTransactionId ? _firstTransactionId : id + 1;
    return id;
  }

  Future<T> _enqueue<T>(
    Future<T> Function() task, {
    bool lowPriority = false,
    CancelToken? cancelToken,
  }) {
    final completer = Completer<T>();
    final job = _Job(task, completer, cancelToken: cancelToken);
    if (lowPriority) {
      _lowPriorityQueue.add(job);
    } else {
      _queue.add(job);
    }
    _pump();
    return completer.future;
  }

  void _pump() {
    if (_running) {
      return;
    }
    final job = _nextJob();
    if (job == null) {
      return;
    }
    _running = true;
    job.run().whenComplete(() {
      _running = false;
      _pump();
    });
  }

  _Job? _nextJob() {
    if (_queue.isNotEmpty) {
      return _queue.removeFirst();
    }
    while (_lowPriorityHolds == 0 && _lowPriorityQueue.isNotEmpty) {
      final job = _lowPriorityQueue.removeLast();
      if (job.cancelToken?.isCancelled ?? false) {
        job.drop();
        continue;
      }
      return job;
    }
    return null;
  }

  Future<PtpTransactionResult> _run(
    int opcode,
    List<int> params,
    int transactionId,
    Set<int> acceptedCodes, {
    Uint8List? dataOut,
    Duration? timeout,
  }) async {
    if (!_transport.isConnected) {
      throw CameraDisconnectedException(_transport.disconnectCause);
    }
    _inTransaction = true;
    _callTimeout = timeout;
    final tap = _onTiming;
    final measurement = _measurement = tap == null
        ? null
        : _Measurement(transactionId, opcode, tap);
    _armWatchdog();
    try {
      final result = await _transport.transact(
        opcode,
        params,
        transactionId,
        dataOut: dataOut,
      );
      if (measurement != null && identical(measurement, _measurement)) {
        measurement.report();
      }
      if (!acceptedCodes.contains(result.code)) {
        throw PtpResponseException(opcode, result.code);
      }
      return result;
    } finally {
      _inTransaction = false;
      _callTimeout = null;
      _measurement = null;
      _watchdog?.cancel();
    }
  }

  Duration get _effectiveTimeout {
    final requested = _callTimeout ?? responseTimeout;
    final minimum = _transport.minimumResponseTimeout;
    return minimum != null && minimum > requested ? minimum : requested;
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    final timeout = _effectiveTimeout;
    _watchdog = Timer(
      timeout,
      () => _transport.abort(TimeoutException('No PTP response', timeout)),
    );
  }

  void _onBytes() {
    if (_inTransaction) {
      _measurement?.byteArrived();
      _armWatchdog();
    }
  }

  void _onTransferTiming(int transactionId, Duration channelOverhead) {
    final measurement = _measurement;
    if (measurement != null && measurement.transactionId == transactionId) {
      measurement.channelOverhead = channelOverhead;
    }
  }
}

class _Measurement {
  _Measurement(this.transactionId, this.opcode, this._tap);

  final int transactionId;
  final int opcode;
  final void Function(int transactionId, PtpTiming timing) _tap;
  final requestSent = DateTime.now();
  final _clock = Stopwatch()..start();
  Duration? _firstByte;
  Duration? channelOverhead;

  void byteArrived() => _firstByte ??= _clock.elapsed;

  void report() => _tap(
    transactionId,
    PtpTiming(
      opcode: opcode,
      requestSent: requestSent,
      firstByte: _firstByte,
      response: _clock.elapsed,
      channelOverhead: channelOverhead,
    ),
  );
}

class _Job {
  _Job(this._task, this._completer, {this.cancelToken});

  final Future<Object?> Function() _task;
  final Completer<Object?> _completer;
  final CancelToken? cancelToken;

  Future<void> run() {
    final result = _task();
    _completer.complete(result);
    return result.then<void>((_) {}, onError: (_) {});
  }

  void drop() => _completer.completeError(const TransferCancelledException());
}
