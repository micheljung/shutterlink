import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../data/cr3_preview.dart';
import '../../data/session_repository.dart';
import '../../data/session_seen_store.dart';
import '../../data/sessions_upload_queue.dart';
import '../../data/upload_worker.dart';
import '../../ptpip/camera_client.dart';
import '../gallery/photo_group.dart';
import '../live/ingest_coordinator.dart';
import 'attribution.dart';
import 'clock_sync_cubit.dart';
import 'clock_sync_state.dart';
import 'session.dart';
import 'sessions_config.dart';

const collectorRescanInterval = Duration(seconds: 30);
const collectorYield = Duration(milliseconds: 200);

/// Lets a burst of camera object-added events settle into one rescan.
const collectorAddedDelay = Duration(seconds: 2);

/// Where auto-upload keeps its own copy of a camera file, if it has one.
typedef StagedFileOf = File Function(String key, String filename);

class SessionCollector {
  SessionCollector({
    required this._client,
    required this._cameraKey,
    required this._clockSync,
    required this._sessions,
    required this._seen,
    required this._queue,
    required this._uploadDirectory,
    IngestCoordinator? coordinator,
    this._stagedFileOf,
    this._isBusy = _neverBusy,
    this._clock = const Clock(),
    this._delay = _yield,
    this._timer = Timer.new,
    this._uuid = const Uuid(),
  }) : _coordinator = coordinator ?? IngestCoordinator();

  static const _jpegExtension = '.jpg';

  final CameraClient _client;
  final String _cameraKey;
  final ClockSyncCubit _clockSync;
  final SessionRepository _sessions;
  final SessionSeenStore _seen;
  final SessionsUploadQueue _queue;
  final Directory _uploadDirectory;
  final IngestCoordinator _coordinator;
  final StagedFileOf? _stagedFileOf;
  final bool Function() _isBusy;
  final Clock _clock;
  final Delay _delay;
  final TimerFactory _timer;
  final Uuid _uuid;
  final _cancel = CancelToken();
  StreamSubscription<ClockState>? _clockChanges;
  StreamSubscription<void>? _sessionChanges;
  StreamSubscription<int>? _added;
  Timer? _rescanTimer;
  bool _addedDuringRescan = false;
  bool _rescanning = false;
  List<PhotoGroup>? _groups;
  Future<void>? _running;
  bool _again = false;
  bool _disposed = false;

  static bool _neverBusy() => false;

  static Future<void> _yield(Duration duration) => Future.delayed(duration);

  void start() {
    _clockChanges = _clockSync.stream.listen((state) {
      if (state is ClockResolved) unawaited(_collect());
    });
    _sessionChanges = _sessions.changes.listen((_) => unawaited(_collect()));
    _added = _client.addedObjects.listen((_) => _onAdded());
    _scheduleRescan();
  }

  Future<void> onGroups(List<PhotoGroup> groups) {
    _groups = groups;
    return _collect();
  }

  Future<void> rescan() async {
    _rescanTimer?.cancel();
    _rescanning = true;
    _addedDuringRescan = false;
    try {
      if (!_isBusy()) {
        await onGroups(groupPhotos(await _client.listPhotos()));
      }
    } on Object {
      return;
    } finally {
      _rescanning = false;
      _scheduleRescan(
        _addedDuringRescan ? collectorAddedDelay : collectorRescanInterval,
      );
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _cancel.cancel();
    _rescanTimer?.cancel();
    await _clockChanges?.cancel();
    await _sessionChanges?.cancel();
    await _added?.cancel();
    await _running;
    await _persistBaseline();
  }

  void _onAdded() {
    if (_rescanning) {
      _addedDuringRescan = true;
    } else {
      _scheduleRescan(collectorAddedDelay);
    }
  }

  void _scheduleRescan([Duration delay = collectorRescanInterval]) {
    if (_disposed) return;
    _rescanTimer?.cancel();
    _rescanTimer = _timer(delay, () => unawaited(rescan()));
  }

  Future<void> _collect() {
    if (_disposed) return Future.value();
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _run().whenComplete(() {
      _running = null;
      if (_again) unawaited(_collect());
    });
  }

  /// A failed pass is not repeated until something new triggers one.
  Future<void> _run() async {
    do {
      _again = false;
      try {
        await _pass();
      } on Object {
        return;
      }
    } while (_again && !_disposed);
  }

  Future<void> _pass() async {
    final groups = _groups;
    final clockState = _clockSync.state;
    if (groups == null || clockState is! ClockResolved) return;
    final listed = _keysOf(groups);
    await _seen.pruneExcluded(_cameraKey, listed);
    final seen = await _seen.states();
    var first = true;
    for (final group in groups.reversed) {
      if (_disposed || _cancel.isCancelled) return;
      final keys = _keysOf([group]);
      if (keys.any(seen.containsKey)) continue;
      final session = await _sessionFor(group, clockState.offset);
      if (session == null) continue;
      if (!first) await _delay(collectorYield);
      first = false;
      final file = await _coordinator.run(keys, () => _download(group));
      if (file == null) continue;
      await _queue.enqueue(sessionCode: session.code, file: file);
      await _seen.markQueued(_cameraKey, keys);
    }
    await _seen.setBaseline(_cameraKey, listed);
  }

  Future<Session?> _sessionFor(PhotoGroup group, Duration offset) async {
    final captureDate = group.captureDate;
    if (captureDate == null) return null;
    final now = _clock.now().toUtc();
    if (captureDate.toUtc().add(offset).isBefore(now.subtract(queueMaxAge))) {
      return null;
    }
    final session = attribute(
      captureDate,
      await _sessions.all(),
      offset,
      openUntil: now.add(standardReadTolerance),
    );
    return session != null && session.isRetainedAt(now) ? session : null;
  }

  Future<File?> _download(PhotoGroup group) async {
    await _uploadDirectory.create(recursive: true);
    final file = File(
      p.join(_uploadDirectory.path, '${_uuid.v4()}$_jpegExtension'),
    );
    try {
      final jpeg = group.jpeg;
      if (jpeg != null && await _copyStaged(jpeg, file)) return file;
      if (jpeg != null) {
        final sink = file.openWrite();
        try {
          await _client.download(
            jpeg,
            (chunk) async => sink.add(chunk),
            cancelToken: _cancel,
          );
        } finally {
          await sink.close();
        }
        return file;
      }
      final preview = await readCr3Preview(
        _client,
        group.raw!,
        cancelToken: _cancel,
      );
      if (preview == null) return null;
      await file.writeAsBytes(preview, flush: true);
      return file;
    } on Object {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  /// Reuses a JPEG auto-upload already took off the camera, so it is not
  /// downloaded twice. A staging file of another size is still being written
  /// or is left over from a different photo.
  Future<bool> _copyStaged(CameraObject jpeg, File target) async {
    final staged = _stagedFileOf?.call(
      SessionSeenStore.keyOf(_cameraKey, jpeg),
      jpeg.filename,
    );
    if (staged == null) return false;
    try {
      if (await staged.length() != jpeg.size) return false;
      await staged.copy(target.path);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _persistBaseline() async {
    final groups = _groups;
    if (groups == null || _clockSync.state is! ClockResolved) return;
    await _seen.setBaseline(_cameraKey, _keysOf(groups));
  }

  Set<String> _keysOf(Iterable<PhotoGroup> groups) => {
    for (final group in groups)
      for (final object in [?group.jpeg, ?group.raw])
        SessionSeenStore.keyOf(_cameraKey, object),
  };
}
