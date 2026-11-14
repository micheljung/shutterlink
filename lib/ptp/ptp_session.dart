import 'dart:async';
import 'dart:collection';

import 'camera_client.dart';
import 'ptp_constants.dart';
import 'ptp_transport.dart';

const ptpDefaultResponseTimeout = Duration(seconds: 3);
const _openSessionTransactionId = 0;
const _firstTransactionId = 1;
const _maxTransactionId = 0xFFFFFFFE;

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
  Timer? _watchdog;

  Future<void> get disconnected => _transport.disconnected;

  Future<void> openSession() => _enqueue(() async {
    await _run(
      PtpOperation.openSession,
      const [PtpHandle.sessionId],
      _openSessionTransactionId,
      const {PtpResponseCode.ok, PtpResponseCode.sessionAlreadyOpen},
    );
    _nextTransactionId = _firstTransactionId;
  });

  Future<PtpTransactionResult> execute(
    int opcode, {
    List<int> params = const [],
    Set<int> acceptedCodes = const {PtpResponseCode.ok},
  }) =>
      _enqueue(() => _run(opcode, params, _takeTransactionId(), acceptedCodes));

  Future<PtpTransactionResult> executeLowPriority(
    int opcode, {
    List<int> params = const [],
    Set<int> acceptedCodes = const {PtpResponseCode.ok},
    CancelToken? cancelToken,
  }) => _enqueue(
    () => _run(opcode, params, _takeTransactionId(), acceptedCodes),
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
    Set<int> acceptedCodes,
  ) async {
    if (!_transport.isConnected) {
      throw CameraDisconnectedException(_transport.disconnectCause);
    }
    _inTransaction = true;
    _armWatchdog();
    try {
      final result = await _transport.transact(opcode, params, transactionId);
      if (!acceptedCodes.contains(result.code)) {
        throw PtpResponseException(opcode, result.code);
      }
      return result;
    } finally {
      _inTransaction = false;
      _watchdog?.cancel();
    }
  }

  Duration get _effectiveTimeout {
    final minimum = _transport.minimumResponseTimeout;
    return minimum != null && minimum > responseTimeout
        ? minimum
        : responseTimeout;
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
      _armWatchdog();
    }
  }
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
