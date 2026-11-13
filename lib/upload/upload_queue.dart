import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../ptpip/camera_client.dart';
import 'destination.dart';
import 'media_saver.dart';
import 'network_policy.dart';
import 'remote_path.dart';
import 'storage_backend.dart';
import 'upload_item.dart';

typedef BackendFactory = Future<StorageBackend> Function(
  Destination destination, {
  required bool allowMetered,
});

typedef TimerFactory = Timer Function(Duration delay, void Function() wake);

const initialBackoff = Duration(seconds: 5);
const maxBackoff = Duration(minutes: 15);
const backoffJitter = 0.2;

/// How long an upload waits when the platform found no usable network while
/// the reported network status still offered one.
const noNetworkRecheck = Duration(seconds: 30);

/// 5 s × 2^(attempts-1), capped at 15 min, ±20 % jitter from [random] ∈ [0,1).
Duration backoffDelay(int attempts, double random) {
  final exponent = max(0, attempts - 1);
  final base = exponent >= 20
      ? maxBackoff
      : Duration(
          microseconds: min(
            initialBackoff.inMicroseconds * (1 << exponent),
            maxBackoff.inMicroseconds,
          ),
        );
  final factor = 1 - backoffJitter + 2 * backoffJitter * random;
  return Duration(microseconds: (base.inMicroseconds * factor).round());
}

class _JsonFile {
  _JsonFile(this.file);

  final File file;
  Future<void> _lastWrite = Future.value();

  Future<Object?> read() async {
    try {
      return jsonDecode(await file.readAsString());
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Serialized; [encode] runs when the write starts, so it sees the latest
  /// state.
  Future<void> write(Object? Function() encode) {
    final write = _lastWrite.then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(encode()), flush: true);
      await temporary.rename(file.path);
    });
    _lastWrite = write.catchError((Object _) {});
    return write;
  }
}

class UploadQueueRepository {
  UploadQueueRepository({required File queueFile, required File historyFile})
    : _queue = _JsonFile(queueFile),
      _history = _JsonFile(historyFile);

  factory UploadQueueRepository.inDirectory(Directory directory) =>
      UploadQueueRepository(
        queueFile: File(p.join(directory.path, queueFileName)),
        historyFile: File(p.join(directory.path, historyFileName)),
      );

  static const queueFileName = 'upload_queue.json';
  static const historyFileName = 'upload_history.json';

  final _JsonFile _queue;
  final _JsonFile _history;
  final _items = <String, UploadItem>{};
  final _uploaded = <String>{};

  Map<String, UploadItem> get items => Map.unmodifiable(_items);

  /// `"$destinationFingerprint|$itemId"` of every confirmed upload.
  Set<String> get uploadedKeys => Set.unmodifiable(_uploaded);

  static String uploadedKey(String fingerprint, String id) =>
      '$fingerprint|$id';

  Future<void> load() async {
    final queue = await _queue.read();
    _items.clear();
    if (queue is List) {
      for (final item in queue.map(UploadItem.fromJson).nonNulls) {
        _items[item.id] = item;
      }
    }
    final history = await _history.read();
    _uploaded
      ..clear()
      ..addAll(history is List ? history.whereType<String>() : const []);
  }

  Future<void> put(UploadItem item) {
    _items[item.id] = item;
    return _writeQueue();
  }

  Future<void> remove(String id) {
    _items.remove(id);
    return _writeQueue();
  }

  Future<void> recordUploaded(String key) {
    _uploaded.add(key);
    return _history.write(() => _uploaded.toList());
  }

  Future<void> _writeQueue() =>
      _queue.write(() => [for (final item in _items.values) item.toJson()]);
}

class UploadQueueSnapshot extends Equatable {
  const UploadQueueSnapshot({
    this.items = const [],
    this.waiting = const {},
    this.activeId,
    this.sentBytes = 0,
    this.totalBytes = 0,
    this.completed = 0,
  });

  /// Unfinished items plus gallery copies that await the user's consent.
  final List<UploadItem> items;
  final Map<String, WaitReason> waiting;
  final String? activeId;
  final int sentBytes;
  final int totalBytes;

  /// Uploads confirmed since the queue started.
  final int completed;

  bool get hasPendingUploads => items.any((item) => !item.state.isUploaded);

  @override
  List<Object?> get props => [
    items,
    waiting,
    activeId,
    sentBytes,
    totalBytes,
    completed,
  ];
}

/// Persistent, single-worker upload queue. Every item walks the
/// [UploadState] machine; each state is persisted before its side effect.
class UploadQueue {
  UploadQueue({
    required this._repository,
    required this._stagingDirectory,
    required this._mediaSaver,
    required this._backendFactory,
    this._destination,
    this._networkStatus,
    NetworkStatus initialNetwork = const NetworkStatus.unrestricted(),
    DateTime Function()? clock,
    TimerFactory? timerFactory,
    Random? random,
    String Function()? uniqueId,
  }) : _network = initialNetwork,
       _clock = clock ?? DateTime.now,
       _timerFactory = timerFactory ?? Timer.new,
       _random = random ?? Random(),
       _uniqueId = uniqueId ?? const Uuid().v4;

  static const stagingDirectoryName = 'upload_staging';

  final UploadQueueRepository _repository;
  final Directory _stagingDirectory;
  final MediaSaver _mediaSaver;
  final BackendFactory _backendFactory;
  final Stream<NetworkStatus>? _networkStatus;
  final DateTime Function() _clock;
  final TimerFactory _timerFactory;
  final Random _random;
  final String Function() _uniqueId;
  final _snapshots = StreamController<UploadQueueSnapshot>.broadcast();
  final _busy = <String>{};
  final _networkWaiting = <String>{};
  final _idleWaiters = <Completer<void>>[];
  final _ready = Completer<void>();
  Destination? _destination;
  NetworkStatus _network;
  StreamSubscription<NetworkStatus>? _networkSubscription;
  Completer<void>? _wakeSignal;
  Future<void> _running = Future.value();
  bool _sleeping = false;
  bool _closed = false;
  String? _activeId;
  int _sentBytes = 0;
  int _totalBytes = 0;
  int _completed = 0;
  UploadQueueSnapshot _snapshot = const UploadQueueSnapshot();

  Destination? get destination => _destination;

  UploadQueueSnapshot get snapshot => _snapshot;

  Stream<UploadQueueSnapshot> get snapshots => _snapshots.stream;

  /// Completes once the worker has nothing to do right now.
  @visibleForTesting
  Future<void> get idle {
    if (_sleeping || _closed) return Future.value();
    final waiter = Completer<void>();
    _idleWaiters.add(waiter);
    return waiter.future;
  }

  Future<void> start() async {
    if (_ready.isCompleted) return;
    await _repository.load();
    for (final item in _repository.items.values) {
      if (item.state == UploadState.uploading) {
        await _repository.put(item.moveTo(UploadState.savedToGallery));
      }
    }
    await _retargetPending();
    await _deleteOrphanedStaging();
    _networkSubscription = _networkStatus?.listen(_onNetwork);
    _ready.complete();
    _running = _run();
  }

  File stagingFileFor(String id, String filename) => File(
    p.join(
      _stagingDirectory.path,
      sha256.convert(utf8.encode(id)).toString().substring(0, 32),
      p.basename(filename),
    ),
  );

  /// Whether [id] is queued or already uploaded to the current destination.
  Future<bool> contains(String id) async {
    await _ready.future;
    final fingerprint = _destination?.fingerprint;
    return _repository.items.containsKey(id) ||
        (fingerprint != null &&
            _repository.uploadedKeys.contains(
              UploadQueueRepository.uploadedKey(fingerprint, id),
            ));
  }

  /// Moves [file] into staging, saves it to the gallery and queues the
  /// upload. Completes once the gallery copy exists. On failure the item is
  /// dropped so the photo is offered again.
  Future<UploadItem> add({
    required String id,
    required File file,
    required String filename,
    required CameraObjectKind kind,
    required DateTime? captureDate,
  }) async {
    await _ready.future;
    final destination = _destination;
    if (destination == null) throw StateError('No upload destination');
    final existing = _repository.items[id];
    if (existing != null) {
      if (file.path != existing.localPath && await file.exists()) {
        await file.delete();
      }
      return existing;
    }
    _busy.add(id);
    try {
      final staged = await _stage(id, file, filename);
      var item = UploadItem(
        id: id,
        filename: filename,
        kind: kind,
        captureDay: captureDayOf(captureDate ?? _clock()),
        size: await staged.length(),
        sha256: (await sha256.bind(staged.openRead()).first).toString(),
        localPath: staged.path,
        destinationFingerprint: destination.fingerprint,
      );
      await _put(item);
      try {
        item = await _saveToGallery(item);
      } on Object {
        await _repository.remove(id);
        await _deleteStaging(staged.path);
        _emitSnapshot();
        rethrow;
      }
      return item;
    } finally {
      _busy.remove(id);
      _wake();
    }
  }

  /// Pending items move to [destination]; uploaded ones stay recorded for
  /// the old one.
  Future<void> setDestination(Destination? destination) async {
    await _ready.future;
    _destination = destination;
    await _retargetPending();
    await _resetWaiting(clearAttention: true);
    _wake();
  }

  /// Retries waiting items immediately, e.g. on user request or app resume.
  Future<void> retryNow() async {
    await _ready.future;
    await _resetWaiting(clearAttention: true);
    _wake();
  }

  /// Asks the user to remove gallery copies the app no longer owns.
  Future<int> removeKeptCopies() async {
    await _ready.future;
    final kept = _repository.items.values
        .where((item) => item.deleteDenied && item.mediaRef != null)
        .toList();
    if (kept.isEmpty) return 0;
    if (!await _mediaSaver.requestDelete([
      for (final item in kept) item.mediaRef!,
    ])) {
      return 0;
    }
    for (final item in kept) {
      await _repository.remove(item.id);
    }
    _emitSnapshot();
    return kept.length;
  }

  Future<void> close() async {
    _closed = true;
    _wake();
    await _networkSubscription?.cancel();
    for (final waiter in _idleWaiters) {
      waiter.complete();
    }
    _idleWaiters.clear();
    await _running;
    await _snapshots.close();
  }

  Future<void> _onNetwork(NetworkStatus status) async {
    final gainedInternet =
        (status.hasUnmeteredInternet && !_network.hasUnmeteredInternet) ||
        (status.hasMeteredInternet && !_network.hasMeteredInternet);
    _network = status;
    if (gainedInternet) await _resetWaiting(clearAttention: false);
    _wake();
  }

  Future<void> _retargetPending() async {
    final fingerprint = _destination?.fingerprint;
    if (fingerprint == null) return;
    for (final item in _repository.items.values.toList()) {
      if (!item.state.isUploaded &&
          item.destinationFingerprint != fingerprint) {
        await _put(item.retarget(fingerprint));
      }
    }
  }

  Future<void> _resetWaiting({required bool clearAttention}) async {
    for (final item in _repository.items.values.toList()) {
      if (item.id == _activeId || _busy.contains(item.id)) continue;
      final attention = clearAttention && item.needsAttention;
      if (item.nextAttemptAt != null || attention) {
        await _put(
          item.copyWith(
            nextAttemptAt: () => null,
            needsAttention: attention ? false : null,
          ),
        );
      }
    }
  }

  Future<void> _run() async {
    while (!_closed) {
      final task = _nextTask();
      if (task == null) {
        await _sleep();
        continue;
      }
      try {
        await task();
      } on Exception {
        // Persisting failed; wait for an external trigger before retrying.
        if (!_closed) await _sleep();
      }
    }
  }

  Future<void> Function()? _nextTask() {
    final now = _clock();
    final destination = _destination;
    for (final item in _repository.items.values) {
      if (_busy.contains(item.id)) continue;
      final due =
          item.nextAttemptAt == null || !item.nextAttemptAt!.isAfter(now);
      switch (item.state) {
        case UploadState.staged || UploadState.saving:
          if (due) return () => _galleryStep(item);
        case UploadState.savedToGallery || UploadState.uploading:
          if (destination == null || !due || item.needsAttention) continue;
          if (decideNetwork(_network, destination.policy, item.kind)
              case UploadAllowed(:final metered)) {
            return () => _uploadStep(item, destination, metered: metered);
          }
        case UploadState.uploaded:
          return () => _finishLocal(item);
        case UploadState.localDeleted || UploadState.localKept:
          break;
      }
    }
    return null;
  }

  Future<void> _sleep() async {
    final signal = _wakeSignal = Completer<void>();
    _sleeping = true;
    final due = _nextDue();
    final timer = due == null
        ? null
        : _timerFactory(due.difference(_clock()), _wake);
    _emitSnapshot();
    for (final waiter in _idleWaiters) {
      waiter.complete();
    }
    _idleWaiters.clear();
    await signal.future;
    timer?.cancel();
  }

  /// Past due items wait for the network, which wakes the worker itself.
  DateTime? _nextDue() {
    final now = _clock();
    DateTime? earliest;
    for (final item in _repository.items.values) {
      final next = item.nextAttemptAt;
      if (next == null || !next.isAfter(now) || item.needsAttention) continue;
      if (earliest == null || next.isBefore(earliest)) earliest = next;
    }
    return earliest;
  }

  void _wake() {
    _sleeping = false;
    final signal = _wakeSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  Future<void> _galleryStep(UploadItem item) async {
    try {
      await _saveToGallery(item);
    } on Exception catch (error) {
      await _fail(item.id, item.destinationFingerprint, error);
    }
  }

  Future<UploadItem> _saveToGallery(UploadItem item) async {
    final pendingRef = item.pendingRef;
    if (item.state == UploadState.saving && pendingRef != null) {
      switch (await _mediaSaver.query(pendingRef)) {
        case MediaRowState.published:
          return _put(
            item.moveTo(
              UploadState.savedToGallery,
              pendingRef: () => null,
              mediaRef: () => pendingRef,
            ),
          );
        case MediaRowState.pending:
          await _mediaSaver.delete(pendingRef);
        case MediaRowState.missing:
          break;
      }
    }
    final reserved = await _mediaSaver.beginSave(
      filename: item.filename,
      kind: item.kind,
    );
    final saving = await _put(
      item.moveTo(UploadState.saving, pendingRef: () => reserved),
    );
    final mediaRef = await _mediaSaver.finishSave(
      reserved,
      path: saving.localPath,
      kind: saving.kind,
    );
    return _put(
      saving
          .moveTo(
            UploadState.savedToGallery,
            pendingRef: () => null,
            mediaRef: () => mediaRef,
          )
          .copyWith(
            attempts: 0,
            nextAttemptAt: () => null,
            lastError: () => null,
          ),
    );
  }

  Future<void> _uploadStep(
    UploadItem item,
    Destination destination, {
    required bool metered,
  }) async {
    final fingerprint = destination.fingerprint;
    final key = UploadQueueRepository.uploadedKey(fingerprint, item.id);
    if (_repository.uploadedKeys.contains(key)) {
      await _markUploaded(item, key);
      return;
    }
    _activeId = item.id;
    _networkWaiting.remove(item.id);
    _sentBytes = 0;
    _totalBytes = item.size;
    _emitSnapshot();
    StorageBackend? backend;
    try {
      backend = await _backendFactory(destination, allowMetered: metered);
      var current = item;
      var index = current.remoteName == null
          ? await _freeNameIndex(backend, current, 0)
          : candidateIndexOf(current.filename, current.remoteName!);
      if (!_targets(current.id, fingerprint)) return;
      if (index == null) {
        await _markUploaded(current, key);
        return;
      }
      final name = candidateName(current.filename, index);
      current = await _put(
        current
            .copyWith(
              remoteName: () => name,
              tempName: () =>
                  current.tempName ?? tempNameFor(name, _uniqueId()),
            )
            .moveTo(UploadState.uploading),
      );
      while (true) {
        final result = await backend.upload(
          UploadRequest(
            source: File(current.localPath),
            target: RemoteTarget(
              directory: current.captureDay,
              name: current.remoteName!,
            ),
            tempName: current.tempName!,
            size: current.size,
            sha256: current.sha256,
          ),
          onProgress: (sent, total) {
            _sentBytes = sent;
            _totalBytes = total;
            _emitSnapshot();
          },
        );
        if (!_targets(current.id, fingerprint)) return;
        if (result != UploadResult.nameTaken) {
          await _markUploaded(current, key);
          return;
        }
        index = await _freeNameIndex(backend, current, index! + 1);
        if (!_targets(current.id, fingerprint)) return;
        if (index == null) {
          await _markUploaded(current, key);
          return;
        }
        final next = candidateName(current.filename, index);
        current = await _put(current.copyWith(remoteName: () => next));
      }
    } on Exception catch (error) {
      await _fail(item.id, fingerprint, error);
    } finally {
      _activeId = null;
      _sentBytes = 0;
      _totalBytes = 0;
      try {
        await backend?.close();
      } on Exception {
        // Closing is best effort.
      }
      _emitSnapshot();
    }
  }

  bool _targets(String id, String fingerprint) =>
      !_closed && _repository.items[id]?.destinationFingerprint == fingerprint;

  Future<int?> _freeNameIndex(
    StorageBackend backend,
    UploadItem item,
    int from,
  ) => freeNameIndex(
    backend,
    directory: item.captureDay,
    filename: item.filename,
    size: item.size,
    sha256: item.sha256,
    from: from,
  );

  Future<void> _markUploaded(UploadItem item, String key) async {
    await _repository.recordUploaded(key);
    _completed++;
    await _put(
      item
          .moveTo(UploadState.uploaded)
          .copyWith(
            attempts: 0,
            nextAttemptAt: () => null,
            lastError: () => null,
          ),
    );
  }

  Future<void> _finishLocal(UploadItem item) async {
    await _deleteStaging(item.localPath);
    final mediaRef = item.mediaRef;
    final keep = _destination?.keepLocalCopy ?? true;
    if (keep || mediaRef == null || mediaRef.isEmpty) {
      await _put(item.moveTo(UploadState.localKept));
      await _repository.remove(item.id);
      return;
    }
    try {
      await _mediaSaver.delete(mediaRef);
    } on Exception catch (error) {
      await _put(
        item
            .moveTo(UploadState.localKept, deleteDenied: true)
            .copyWith(lastError: () => '$error'),
      );
      return;
    }
    await _put(item.moveTo(UploadState.localDeleted));
    await _repository.remove(item.id);
  }

  Future<void> _fail(String id, String fingerprint, Exception error) async {
    final item = _repository.items[id];
    if (item == null || item.destinationFingerprint != fingerprint) return;
    if (error is NoNetworkException) {
      _networkWaiting.add(id);
      await _put(
        item.copyWith(
          state: item.state == UploadState.uploading
              ? UploadState.savedToGallery
              : null,
          nextAttemptAt: () => _clock().add(noNetworkRecheck),
        ),
      );
      return;
    }
    final attempts = item.attempts + 1;
    final permanent = error is StorageException && !error.retryable;
    await _put(
      item.copyWith(
        state: item.state == UploadState.uploading
            ? UploadState.savedToGallery
            : null,
        attempts: attempts,
        nextAttemptAt: () => permanent
            ? null
            : _clock().add(backoffDelay(attempts, _random.nextDouble())),
        lastError: () => '$error',
        needsAttention: permanent,
      ),
    );
  }

  Future<File> _stage(String id, File file, String filename) async {
    final target = stagingFileFor(id, filename);
    if (file.path == target.path) return target;
    await target.parent.create(recursive: true);
    try {
      return await file.rename(target.path);
    } on FileSystemException {
      final copy = await file.copy(target.path);
      await file.delete();
      return copy;
    }
  }

  Future<void> _deleteStaging(String localPath) async {
    final directory = File(localPath).parent;
    if (p.isWithin(_stagingDirectory.path, directory.path) &&
        await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _deleteOrphanedStaging() async {
    if (!await _stagingDirectory.exists()) return;
    final referenced = {
      for (final item in _repository.items.values)
        File(item.localPath).parent.path,
    };
    await for (final entry in _stagingDirectory.list()) {
      if (!referenced.contains(entry.path)) {
        await entry.delete(recursive: true);
      }
    }
  }

  Future<UploadItem> _put(UploadItem item) async {
    await _repository.put(item);
    _emitSnapshot();
    return item;
  }

  void _emitSnapshot() {
    if (_closed) return;
    final now = _clock();
    final destination = _destination;
    final items = _repository.items.values
        .where((item) => !item.state.isTerminal || item.deleteDenied)
        .toList();
    _snapshot = UploadQueueSnapshot(
      items: items,
      waiting: {
        for (final item in items)
          if (item.id != _activeId && !item.state.isUploaded)
            item.id: ?_waitReason(item, destination, now),
      },
      activeId: _activeId,
      sentBytes: _sentBytes,
      totalBytes: _totalBytes,
      completed: _completed,
    );
    _snapshots.add(_snapshot);
  }

  WaitReason? _waitReason(
    UploadItem item,
    Destination? destination,
    DateTime now,
  ) {
    if (item.needsAttention) return WaitReason.attention;
    final next = item.nextAttemptAt;
    if (next != null && next.isAfter(now)) {
      return _networkWaiting.contains(item.id)
          ? WaitReason.network
          : WaitReason.backoff;
    }
    if (item.state.index < UploadState.savedToGallery.index) return null;
    if (destination == null) return WaitReason.noDestination;
    return switch (decideNetwork(_network, destination.policy, item.kind)) {
      UploadAllowed() => null,
      UploadWaits(:final reason) => reason,
    };
  }
}
