import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'camera_client.dart';
import 'canon_eos.dart';
import 'connection.dart';
import 'packet.dart';

const ptpDefaultResponseTimeout = Duration(seconds: 3);
const _openSessionTransactionId = 0;
const _firstTransactionId = 1;
const _maxTransactionId = 0xFFFFFFFE;
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

class PtpSession {
  PtpSession(
    this._connection, {
    this.responseTimeout = ptpDefaultResponseTimeout,
  }) {
    _connection.commandPackets.listen(_onPacket);
    _connection.onCommandBytes = _onBytes;
    _connection.disconnected.then((_) => _abortCurrent());
  }

  final PtpIpConnection _connection;
  final Duration responseTimeout;
  int _nextTransactionId = _firstTransactionId;
  final _queue = Queue<_Job>();
  final _lowPriorityQueue = <_Job>[];
  int _lowPriorityHolds = 0;
  bool _running = false;
  _Transaction? _current;
  Timer? _watchdog;

  Future<void> get disconnected => _connection.disconnected;

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
    if (!_connection.isConnected) {
      throw CameraDisconnectedException(_connection.disconnectCause);
    }
    final transaction = _current = _Transaction(opcode, transactionId);
    _armWatchdog();
    try {
      _connection.send(
        CommandRequest(
          opcode: opcode,
          transactionId: transactionId,
          params: params,
        ),
      );
      final result = await transaction.completer.future;
      if (!acceptedCodes.contains(result.code)) {
        throw PtpResponseException(opcode, result.code);
      }
      return result;
    } finally {
      _current = null;
      _watchdog?.cancel();
    }
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(
      responseTimeout,
      () => _connection.abort(
        TimeoutException('No PTP response', responseTimeout),
      ),
    );
  }

  void _onBytes() {
    if (_current != null) {
      _armWatchdog();
    }
  }

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
    _watchdog?.cancel();
    final transaction = _current;
    if (transaction != null && !transaction.completer.isCompleted) {
      transaction.completer.completeError(
        CameraDisconnectedException(_connection.disconnectCause),
      );
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
