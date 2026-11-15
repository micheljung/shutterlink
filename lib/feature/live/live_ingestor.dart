import 'dart:async';

import '../../data/download_history.dart';
import '../../data/settings_repository.dart';
import '../../ptpip/camera_client.dart';
import '../../upload/upload_queue.dart';
import '../capture/new_shot_detector.dart';
import '../download/object_fetcher.dart';
import 'ingest_coordinator.dart';

/// The card as it was when Auto Upload started.
class LiveBaseline {
  const LiveBaseline({required this.keys, this.handles = const {}});

  LiveBaseline.of(String cameraKey, List<CameraObject> photos)
    : this(
        keys: {
          for (final object in photos)
            DownloadHistoryRepository.entryKey(cameraKey, object),
        },
        handles: {for (final object in photos) object.handle},
      );

  /// Entry keys of the photos on the card; they are never ingested.
  final Set<String> keys;

  /// Handles of those photos, valid only in the PTP session that listed
  /// them since a camera may renumber objects per session.
  final Set<int> handles;
}

/// Turns new camera objects into gallery copies and queued uploads.
class LiveIngestor {
  LiveIngestor({
    required this._client,
    required this._format,
    required this._baseline,
    required this._history,
    required this._queue,
    required this._coordinator,
    this._fetcher = const ObjectFetcher(),
    this._infoRetryDelay = defaultInfoRetryDelay,
    this._rescanInterval = defaultRescanInterval,
  }) : _cameraKey = cameraKeyOf(_client.deviceInfo),
       _resolvedHandles = {..._baseline.handles};

  static const defaultInfoRetryDelay = Duration(milliseconds: 500);
  static const defaultRescanInterval = Duration(seconds: 2);
  static const infoRetries = 3;

  final CameraClient _client;
  final DownloadFormat _format;
  final LiveBaseline _baseline;
  final DownloadHistoryRepository _history;
  final UploadQueue _queue;
  final IngestCoordinator _coordinator;
  final ObjectFetcher _fetcher;
  final Duration _infoRetryDelay;
  final Duration _rescanInterval;
  final String _cameraKey;
  final _ingested = StreamController<CameraObject>.broadcast();
  final Set<int> _resolvedHandles;
  NewShotDetector? _detector;
  StreamSubscription<int>? _subscription;
  bool _closed = false;
  Future<void> _pending = Future.value();
  int _queuedWork = 0;

  /// Objects saved to the gallery and queued for upload.
  Stream<CameraObject> get ingested => _ingested.stream;

  static Future<LiveBaseline> baselineOf(CameraClient client) async =>
      LiveBaseline.of(
        cameraKeyOf(client.deviceInfo),
        await client.listPhotos(),
      );

  /// How many of [photos] in [format] are neither queued nor uploaded to
  /// the queue's destination; downloads to the phone do not count.
  static Future<int> backlogOf(
    List<CameraObject> photos, {
    required String cameraKey,
    required DownloadFormat format,
    required UploadQueue queue,
  }) async {
    var count = 0;
    for (final object in photos) {
      if (!wanted(format, object)) continue;
      final key = DownloadHistoryRepository.entryKey(cameraKey, object);
      if (!await queue.contains(key)) count++;
    }
    return count;
  }

  /// Whether [object] is of a kind [format] uploads.
  static bool wanted(DownloadFormat format, CameraObject object) =>
      switch (format) {
        DownloadFormat.jpeg => object.kind == CameraObjectKind.jpeg,
        DownloadFormat.raw => object.kind == CameraObjectKind.raw,
        DownloadFormat.both => true,
      };

  /// Follows the camera's object-added events, and periodically diffs the
  /// newest folder because not every body reports new shots.
  void start() {
    if (_closed || _detector != null) return;
    final detector = NewShotDetector(
      client: _client,
      baseline: _baseline.handles,
      isResolved: _resolvedHandles.contains,
      consumerBusy: () => _queuedWork > 0,
      interval: _rescanInterval,
    );
    _detector = detector;
    _subscription = detector.handles.listen(
      (handle) => _enqueue(() => _onAdded(handle)),
    );
    detector.start();
  }

  /// Ingests what was missed while the camera was unreachable, and learns
  /// this session's handles so the rescan skips them.
  Future<void> catchUp() => _enqueue(() async {
    for (final object in await _client.listPhotos()) {
      if (_closed) return;
      if (await _ingest(object)) _resolvedHandles.add(object.handle);
    }
  });

  /// Abandons queued work; an ingest already running finishes first.
  Future<void> close() async {
    _closed = true;
    await _detector?.close();
    await _subscription?.cancel();
    await _pending;
    await _ingested.close();
  }

  Future<void> _enqueue(Future<void> Function() work) {
    _queuedWork++;
    final next = _pending.then((_) => work()).catchError((Object _) {}).then((
      _,
    ) {
      if (--_queuedWork == 0) _detector?.notifyIdle();
    });
    _pending = next;
    return next;
  }

  Future<void> _onAdded(int handle) async {
    if (_closed || _resolvedHandles.contains(handle)) return;
    final info = await _objectInfo(handle);
    if (info == null) return;
    final object = info.object;
    if (object == null || await _ingest(object)) _resolvedHandles.add(handle);
  }

  /// Retries while the camera is still writing the file. Gives up with null;
  /// the next rescan or the reconnect catch-up picks the file up later.
  Future<({CameraObject? object})?> _objectInfo(int handle) async {
    for (var attempt = 0; attempt <= infoRetries; attempt++) {
      if (attempt > 0) await Future<void>.delayed(_infoRetryDelay);
      try {
        final object = await _client.objectInfo(handle);
        if (object != null && object.size == 0) continue;
        return (object: object);
      } on CameraDisconnectedException {
        return null;
      } on Exception {
        continue;
      }
    }
    return null;
  }

  /// A photo only downloaded to the phone is not known: it still needs
  /// uploading.
  Future<bool> _isKnown(String key) async =>
      _baseline.keys.contains(key) || await _queue.contains(key);

  /// Whether the object needs no further attempt.
  Future<bool> _ingest(CameraObject object) async {
    if (!wanted(_format, object)) return true;
    final key = DownloadHistoryRepository.entryKey(_cameraKey, object);
    if (await _isKnown(key)) return true;
    return _coordinator.run([key], () async {
      if (await _isKnown(key)) return true;
      try {
        final file = await _fetcher.fetch(
          _client,
          object,
          _queue.stagingFileFor(key, object.filename),
        );
        await _queue.add(
          id: key,
          file: file,
          filename: object.filename,
          kind: object.kind,
          captureDate: object.captureDate,
        );
        await _history.record(_cameraKey, [object]);
      } on Exception {
        return false;
      }
      if (!_ingested.isClosed) _ingested.add(object);
      return true;
    });
  }
}
