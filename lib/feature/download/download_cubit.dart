import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;

import '../../data/download_history.dart';
import '../../data/photo_saver.dart';
import '../../data/settings_repository.dart';
import '../../ptpip/camera_client.dart';
import '../../upload/upload_queue.dart';
import '../gallery/photo_group.dart';
import '../live/ingest_coordinator.dart';
import 'download_plan.dart';
import 'download_state.dart';
import 'object_fetcher.dart';

class DownloadCubit extends Cubit<DownloadState> {
  DownloadCubit({
    required this._saver,
    required this._workDirectory,
    required this._history,
    IngestCoordinator? coordinator,
    this._uploadQueue,
    this._fetcher = const ObjectFetcher(),
  }) : _coordinator = coordinator ?? IngestCoordinator(),
       super(const DownloadState());

  static const disconnectedMessage =
      'Camera disconnected. Reconnect to resume the download.';

  final PhotoSaver _saver;
  final Directory _workDirectory;
  final DownloadHistoryRepository _history;
  final IngestCoordinator _coordinator;
  final UploadQueue? _uploadQueue;
  final ObjectFetcher _fetcher;
  final _changedTasks = <int>{};
  CancelToken? _cancelToken;
  String _cameraKey = '';

  Future<void> start(
    CameraClient client,
    List<PhotoGroup> groups,
    DownloadFormat format,
  ) async {
    if (state.status == DownloadStatus.running) return;
    await _discardPartialFiles();
    _changedTasks.clear();
    _cameraKey = cameraKeyOf(client.deviceInfo);
    final recorded = await _history.load();
    final plan = planDownload(
      groups,
      format,
      isDownloaded: (object) => recorded.contains(
        DownloadHistoryRepository.entryKey(_cameraKey, object),
      ),
    );
    emit(
      DownloadState(
        status: DownloadStatus.running,
        tasks: plan.tasks,
        skipped: plan.skipped,
        alreadyDownloaded: plan.alreadyDownloaded,
      ),
    );
    await _run(client, _cancelToken = CancelToken());
  }

  Future<void> resume(CameraClient client) async {
    if (state.status != DownloadStatus.paused) return;
    final token = _cancelToken = CancelToken();
    _emit(
      state.copyWith(
        status: DownloadStatus.running,
        error: () => null,
        currentFile: () => null,
        fileReceived: 0,
        fileTotal: 0,
        completedBytes: _bytesOfTasks(state.nextTask),
      ),
    );
    try {
      await _detectChangedPhotos(client, token);
    } on CameraDisconnectedException {
      _pause();
      return;
    }
    await _run(client, token);
  }

  Future<void> _detectChangedPhotos(
    CameraClient client,
    CancelToken token,
  ) async {
    for (var index = state.nextTask; index < state.tasks.length; index++) {
      if (token.isCancelled) return;
      for (final object in state.tasks[index].files) {
        if (!await _isUnchanged(client, object)) {
          _changedTasks.add(index);
          break;
        }
      }
    }
  }

  Future<bool> _isUnchanged(CameraClient client, CameraObject object) async {
    try {
      final current = await client.objectInfo(object.handle);
      return current != null &&
          current.filename == object.filename &&
          current.size == object.size &&
          current.captureDate == object.captureDate;
    } on CameraDisconnectedException {
      rethrow;
    } on Exception {
      return false;
    }
  }

  Future<void> cancel() async {
    switch (state.status) {
      case DownloadStatus.running:
        _cancelToken?.cancel();
      case DownloadStatus.paused:
        await _discardPartialFiles();
        _emit(state.copyWith(status: DownloadStatus.cancelled));
      case DownloadStatus.idle:
      case DownloadStatus.cancelled:
      case DownloadStatus.completed:
        break;
    }
  }

  void dismiss() {
    if (state.isActive) return;
    _emit(const DownloadState());
  }

  Future<void> _run(CameraClient client, CancelToken token) async {
    try {
      if (token.isCancelled) throw const TransferCancelledException();
      while (state.nextTask < state.tasks.length) {
        final task = state.tasks[state.nextTask];
        final failure = _changedTasks.contains(state.nextTask)
            ? await _discardChanged(task)
            : await _runTask(client, task, token);
        final done = state.nextTask + 1;
        _emit(
          state.copyWith(
            nextTask: done,
            currentFile: () => null,
            fileReceived: 0,
            fileTotal: 0,
            completedBytes: _bytesOfTasks(done),
            saved: failure == null ? [...state.saved, task.group] : null,
            failed: failure == null
                ? null
                : [...state.failed, DownloadFailure(task.group, failure)],
          ),
        );
      }
      _emit(state.copyWith(status: DownloadStatus.completed));
    } on TransferCancelledException {
      await _discardPartialFiles();
      _emit(
        state.copyWith(
          status: DownloadStatus.cancelled,
          currentFile: () => null,
          fileReceived: 0,
        ),
      );
    } on CameraDisconnectedException {
      _pause();
    }
  }

  void _pause() => _emit(
    state.copyWith(
      status: DownloadStatus.paused,
      error: () => disconnectedMessage,
    ),
  );

  Future<DownloadFailureReason> _discardChanged(DownloadTask task) async {
    await _deleteTaskFiles(task);
    return DownloadFailureReason.photoChanged;
  }

  Future<DownloadFailureReason?> _runTask(
    CameraClient client,
    DownloadTask task,
    CancelToken token,
  ) => _coordinator.run(
    task.files.map(_entryKey),
    () => _runClaimedTask(client, task, token),
  );

  String _entryKey(CameraObject object) =>
      DownloadHistoryRepository.entryKey(_cameraKey, object);

  Future<DownloadFailureReason?> _runClaimedTask(
    CameraClient client,
    DownloadTask task,
    CancelToken token,
  ) async {
    final files = <CameraObject, File>{};
    var keepFiles = false;
    try {
      final recorded = await _history.load();
      final pending = task.files
          .where((object) => !recorded.contains(_entryKey(object)))
          .toList();
      for (final object in pending) {
        if (token.isCancelled) throw const TransferCancelledException();
        files[object] = await _fetch(client, object, token);
      }
      if (token.isCancelled) throw const TransferCancelledException();
      final queue = _uploadQueue;
      if (queue != null && queue.destination != null) {
        for (final object in pending) {
          await queue.add(
            id: _entryKey(object),
            file: files[object]!,
            filename: object.filename,
            kind: object.kind,
            captureDate: object.captureDate,
          );
          await _record([object]);
        }
      } else if (pending.isNotEmpty) {
        await _saver.save(
          jpeg: files[task.group.jpeg],
          raw: files[task.group.raw],
        );
        await _record(pending);
      }
      return null;
    } on TransferCancelledException {
      rethrow;
    } on CameraDisconnectedException {
      keepFiles = true;
      rethrow;
    } on Exception {
      return DownloadFailureReason.saveFailed;
    } finally {
      if (!keepFiles) await _deleteTaskFiles(task);
    }
  }

  Future<void> _record(List<CameraObject> objects) async {
    try {
      await _history.record(_cameraKey, objects);
    } on FileSystemException {
      // The photo is saved; a lost entry only means it is offered again.
    }
  }

  Future<File> _fetch(
    CameraClient client,
    CameraObject object,
    CancelToken token,
  ) async {
    final file = await _fetcher.fetch(
      client,
      object,
      _workFile(object),
      cancelToken: token,
      onResume: (received) => _emit(
        state.copyWith(
          currentFile: () => object.filename,
          fileReceived: received,
          fileTotal: object.size,
        ),
      ),
      onReceived: (received) => _emit(state.copyWith(fileReceived: received)),
    );
    _emit(
      state.copyWith(
        completedBytes: state.completedBytes + object.size,
        fileReceived: 0,
      ),
    );
    return file;
  }

  File _workFile(CameraObject object) => File(
    p.join(
      _workDirectory.path,
      '${object.storageId}_${object.handle}',
      p.basename(object.filename),
    ),
  );

  Future<void> _deleteTaskFiles(DownloadTask task) async {
    for (final object in task.files) {
      final directory = _workFile(object).parent;
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }

  Future<void> _discardPartialFiles() async {
    if (await _workDirectory.exists()) {
      await _workDirectory.delete(recursive: true);
    }
  }

  int _bytesOfTasks(int count) =>
      state.tasks.take(count).fold(0, (sum, task) => sum + task.totalBytes);

  void _emit(DownloadState next) {
    if (!isClosed) emit(next);
  }
}
