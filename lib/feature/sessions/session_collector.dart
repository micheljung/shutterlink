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
import '../capture/new_shot_detector.dart';
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

/// A RAW this young may still get its JPEG, which is sent instead of the
/// RAW's preview.
const collectorSettleDelay = Duration(seconds: 3);

/// Where auto-upload keeps its own copy of a camera file, if it has one.
typedef StagedFileOf = File Function(String key, String filename);

/// Sends the shots taken during a Session window to the Sessions upload
/// queue. A full pass over the listed card attributes and queues them, and
/// keeps the seen-store in step with the card. New shots found by the
/// [NewShotDetector] are queued at once by a fast pass over their handles
/// only, so they need not wait for a listing of the whole card.
class SessionCollector {
  SessionCollector({
    required this._client,
    required this._cameraKey,
    required this._clockSync,
    required this._sessions,
    required this._seen,
    required this._queue,
    required this._uploadDirectory,
    required this._baseline,
    IngestCoordinator? coordinator,
    this._stagedFileOf,
    this._isBusy = _neverBusy,
    this._clock = const Clock(),
    this._delay = _yield,
    this._timer = Timer.new,
    this._uuid = const Uuid(),
    this._detectorInterval = NewShotDetector.defaultInterval,
  }) : _coordinator = coordinator ?? IngestCoordinator();

  static const _jpegExtension = '.jpg';

  final CameraClient _client;
  final String _cameraKey;
  final ClockSyncCubit _clockSync;
  final SessionRepository _sessions;
  final SessionSeenStore _seen;
  final SessionsUploadQueue _queue;
  final Directory _uploadDirectory;

  /// The newest folder's handles when this client attached.
  final Set<int> _baseline;
  final IngestCoordinator _coordinator;
  final StagedFileOf? _stagedFileOf;
  final bool Function() _isBusy;
  final Clock _clock;
  final Delay _delay;
  final TimerFactory _timer;
  final Uuid _uuid;
  final Duration _detectorInterval;
  final _cancel = CancelToken();
  StreamSubscription<ClockState>? _clockChanges;
  StreamSubscription<void>? _sessionChanges;
  NewShotDetector? _detector;
  StreamSubscription<int>? _shots;
  Timer? _rescanTimer;

  /// Handles whose group a completed full pass settled.
  final _resolved = <int>{};

  /// Shots the fast pass read, by handle.
  final _shotInfo = <int, CameraObject>{};
  final _fastHandles = <int>{};
  Future<void>? _fastRunning;
  bool _addedDuringRescan = false;
  bool _rescanSoon = false;
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
    final detector = _detector = NewShotDetector(
      client: _client,
      baseline: _baseline,
      isResolved: _resolved.contains,
      consumerBusy: () => _fastRunning != null,
      interval: _detectorInterval,
    );
    _shots = detector.handles.listen(_onShot);
    detector.start();
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
    final detecting = _detector?.close();
    await _clockChanges?.cancel();
    await _sessionChanges?.cancel();
    await _shots?.cancel();
    await detecting;
    await _running;
    await _fastRunning;
    await _persistBaseline();
  }

  /// Queues the shot at once, and lists the card soon after to settle it.
  void _onShot(int handle) {
    if (_disposed) return;
    _fastHandles.add(handle);
    _fastRunning ??= _runFast();
    _onAdded();
  }

  /// Fast passes run one at a time; handles that arrive meanwhile are all
  /// taken by the next one.
  Future<void> _runFast() async {
    // The handles of one diff arrive together.
    await Future<void>.value();
    while (_fastHandles.isNotEmpty && !_disposed) {
      final handles = {..._fastHandles};
      _fastHandles.clear();
      try {
        await _fastPass(handles);
      } on Object {
        // The detector offers the shot again.
      }
    }
    _fastRunning = null;
    _detector?.notifyIdle();
  }

  /// Queues the groups of [handles] with no listing of the card. It never
  /// prunes the seen-store or sets the baseline, which need the whole card,
  /// and it resolves nothing: the next full pass does.
  Future<void> _fastPass(Set<int> handles) async {
    final clockState = _clockSync.state;
    if (clockState is! ClockResolved) return;
    for (final handle in handles) {
      if (_disposed) return;
      if (_shotInfo.containsKey(handle)) continue;
      final object = await _client.objectInfo(handle);
      if (object != null && object.size > 0) _shotInfo[handle] = object;
    }
    // A RAW is grouped with a JPEG already listed or read, so a pair
    // settled earlier is not sent again as the RAW's preview.
    final known = {
      for (final group in _groups ?? const <PhotoGroup>[])
        for (final object in [?group.jpeg, ?group.raw]) object.handle: object,
      ..._shotInfo,
    };
    final groups = groupPhotos(known.values)
        .where((group) => _handlesOf(group).any(handles.contains));
    for (final group in groups.toList().reversed) {
      if (_disposed) return;
      if (!_isReady(group, clockState.offset)) continue;
      final session = await _sessionFor(group, clockState.offset);
      if (session == null) continue;
      await _collectGroup(group, session);
    }
  }

  /// A rescan already brought forward is not pushed back: the detector
  /// offers a shot again on every diff until a full pass resolves it.
  void _onAdded() {
    if (_rescanning) {
      _addedDuringRescan = true;
    } else if (!_rescanSoon) {
      _scheduleRescan(collectorAddedDelay);
    }
  }

  void _scheduleRescan([Duration delay = collectorRescanInterval]) {
    if (_disposed) return;
    _rescanTimer?.cancel();
    _rescanSoon = delay < collectorRescanInterval;
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
    final settled = <int>{};
    var first = true;
    for (final group in groups.reversed) {
      if (_disposed || _cancel.isCancelled) return;
      final keys = _keysOf([group]);
      if (keys.any(seen.containsKey)) {
        settled.addAll(_handlesOf(group));
        continue;
      }
      if (!_isReady(group, clockState.offset)) continue;
      final session = await _sessionFor(group, clockState.offset);
      if (session == null) {
        settled.addAll(_handlesOf(group));
        continue;
      }
      if (!first) await _delay(collectorYield);
      first = false;
      if (_isBusy()) return;
      if (await _collectGroup(group, session)) {
        settled.addAll(_handlesOf(group));
      }
    }
    await _seen.setBaseline(_cameraKey, listed);
    _resolved.addAll(settled);
  }

  /// Whether [group] can be sent now: every file is written, and a RAW on
  /// its own is old enough that no JPEG is coming.
  bool _isReady(PhotoGroup group, Duration offset) {
    if ([?group.jpeg, ?group.raw].any((object) => object.size == 0)) {
      return false;
    }
    if (group.jpeg != null) return true;
    final captureDate = group.captureDate;
    if (captureDate == null) return true;
    final takenAt = captureDate.toUtc().add(offset);
    return _clock.now().toUtc().difference(takenAt) >= collectorSettleDelay;
  }

  /// Downloads, queues and marks [group] as one unit, so the fast and the
  /// full pass never both send it. Returns whether the group is settled.
  Future<bool> _collectGroup(PhotoGroup group, Session session) {
    final keys = _keysOf([group]);
    return _coordinator.run(keys, () async {
      final seen = await _seen.states();
      if (keys.any(seen.containsKey)) return true;
      if (_disposed) return false;
      final file = await _download(group);
      // A RAW without a preview has nothing to send, now or later.
      if (file == null) return true;
      if (_disposed) {
        await file.delete();
        return false;
      }
      await _queue.enqueue(sessionCode: session.code, file: file);
      await _seen.markQueued(_cameraKey, keys);
      return true;
    });
  }

  static Iterable<int> _handlesOf(PhotoGroup group) => [
    ?group.jpeg?.handle,
    ?group.raw?.handle,
  ];

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
