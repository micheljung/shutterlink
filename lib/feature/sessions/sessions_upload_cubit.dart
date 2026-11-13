import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/upload_worker.dart';
import 'sessions_dependencies.dart';

class SessionsUploadState extends Equatable {
  const SessionsUploadState({
    this.running = false,
    this.status = UploadWorkerStatus.idle,
    this.pending = 0,
    this.dropped = 0,
    this.expired = 0,
  });

  final bool running;
  final UploadWorkerStatus status;
  final int pending;
  final int dropped;
  final int expired;

  @override
  List<Object?> get props => [running, status, pending, dropped, expired];
}

class SessionsUploadCubit extends Cubit<SessionsUploadState> {
  SessionsUploadCubit(this._dependencies) : super(const SessionsUploadState());

  final SessionsDependencies _dependencies;
  UploadWorker? _worker;
  StreamSubscription<void>? _queueChanges;

  Future<void> setEnabled({required bool enabled}) async {
    if (!enabled) return _stop();
    final worker = _worker;
    if (worker != null) return worker.wake();
    final started = _worker = _dependencies.createWorker();
    started.status.addListener(_refresh);
    _queueChanges = _dependencies.queue.changes.listen((_) => _refresh());
    started.start();
    await _refresh();
  }

  Future<void> resumed() async => _worker?.wake();

  Future<void> _stop() async {
    final worker = _worker;
    if (worker == null) return;
    _worker = null;
    worker.status.removeListener(_refresh);
    await _queueChanges?.cancel();
    _queueChanges = null;
    await worker.dispose();
    if (!isClosed) emit(const SessionsUploadState());
  }

  Future<void> _refresh() async {
    final worker = _worker;
    if (worker == null) return;
    final queue = _dependencies.queue;
    final pending = (await queue.items()).length;
    final dropped = await queue.droppedCount();
    final expired = await queue.expiredCount();
    if (isClosed || _worker != worker) return;
    emit(
      SessionsUploadState(
        running: true,
        status: worker.status.value,
        pending: pending,
        dropped: dropped,
        expired: expired,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _stop();
    return super.close();
  }
}
