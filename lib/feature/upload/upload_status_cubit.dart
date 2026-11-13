import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../upload/network_policy.dart';
import '../../upload/upload_item.dart';
import '../../upload/upload_queue.dart';

class UploadStatusState extends Equatable {
  const UploadStatusState({
    this.pending = 0,
    this.uploadingFile,
    this.sentBytes = 0,
    this.totalBytes = 0,
    this.completed = 0,
    this.failed = const [],
    this.waitReason,
    this.keptCopies = 0,
  });

  /// Items not yet confirmed by the server, including the active one.
  final int pending;
  final String? uploadingFile;
  final int sentBytes;
  final int totalBytes;
  final int completed;

  /// Items whose last attempt failed.
  final List<UploadItem> failed;

  /// Why the queue is not uploading, when nothing is active.
  final WaitReason? waitReason;

  /// Gallery copies that could not be removed without the user's consent.
  final int keptCopies;

  double? get progress => totalBytes == 0 ? null : sentBytes / totalBytes;

  @override
  List<Object?> get props => [
    pending,
    uploadingFile,
    sentBytes,
    totalBytes,
    completed,
    failed,
    waitReason,
    keptCopies,
  ];
}

class UploadStatusCubit extends Cubit<UploadStatusState> {
  UploadStatusCubit(this._queue) : super(_stateOf(_queue.snapshot)) {
    _subscription = _queue.snapshots.listen(
      (snapshot) => emit(_stateOf(snapshot)),
    );
  }

  final UploadQueue _queue;
  late final StreamSubscription<UploadQueueSnapshot> _subscription;

  Future<void> retryNow() => _queue.retryNow();

  Future<int> removeKeptCopies() => _queue.removeKeptCopies();

  static UploadStatusState _stateOf(UploadQueueSnapshot snapshot) {
    final active = snapshot.items
        .where((item) => item.id == snapshot.activeId)
        .firstOrNull;
    final reasons = snapshot.waiting.values.toSet();
    return UploadStatusState(
      pending: snapshot.items.where((item) => !item.state.isUploaded).length,
      uploadingFile: active?.filename,
      sentBytes: snapshot.sentBytes,
      totalBytes: snapshot.totalBytes,
      completed: snapshot.completed,
      failed: [
        for (final item in snapshot.items)
          if (item.lastError != null && !item.state.isUploaded) item,
      ],
      waitReason: active != null
          ? null
          : WaitReason.values.where(reasons.contains).firstOrNull,
      keptCopies: snapshot.items.where((item) => item.deleteDenied).length,
    );
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    return super.close();
  }
}
