import 'dart:async';
import 'dart:io';

import '../../data/download_history.dart';
import '../../data/settings_repository.dart';
import '../../ptpip/camera_client.dart';
import '../../upload/upload_queue.dart';
import '../download/object_fetcher.dart';
import 'ingest_coordinator.dart';

/// The card as it was when Live started.
class LiveBaseline {
  const LiveBaseline({required this.keys, this.handles = const {}});

  /// Entry keys of the photos on the card; they are never ingested.
  final Set<String> keys;

  /// Handles of those photos, valid only in the PTP session that listed
  /// them since a camera may renumber objects per session.
  final Set<int> handles;
}

/// Receives a complete JPEG before it is queued and may be moved away.
typedef JpegFetched = Future<void> Function(String key, File file);

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
    this._onJpegFetched,
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
  final JpegFetched? _onJpegFetched;
  final Duration _infoRetryDelay;
  final Duration _rescanInterval;
  final String _cameraKey;
  final _ingested = StreamController<CameraObject>.broadcast();
  final Set<int> _resolvedHandles;
  StreamSubscription<int>? _subscription;
  Timer? _rescanTimer;
  bool _rescanQueued = false;
  bool _closed = false;
  Future<void> _pending = Future.value();

  /// Objects saved to the gallery and queued for upload.
  Stream<CameraObject> get ingested => _ingested.stream;

  static Future<LiveBaseline> baselineOf(CameraClient client) async {
    final cameraKey = cameraKeyOf(client.deviceInfo);
    final photos = await client.listPhotos();
    return LiveBaseline(
      keys: {
        for (final object in photos)
          DownloadHistoryRepository.entryKey(cameraKey, object),
      },
      handles: {for (final object in photos) object.handle},
    );
  }

  /// Follows the camera's object-added events, and periodically diffs the
  /// newest folder because not every body reports new shots.
  void start() {
    if (_closed || _subscription != null) return;
    _subscription = _client.addedObjects.listen(
      (handle) => _enqueue(() => _onAdded(handle)),
    );
    final timer = Timer.periodic(_rescanInterval, (_) => _rescan());
    _rescanTimer = timer;
    _client.disconnected.then((_) => timer.cancel());
  }

  void _rescan() {
    if (_rescanQueued) return;
    _rescanQueued = true;
    _enqueue(() async {
      _rescanQueued = false;
      for (final handle in await _client.newestFolderHandles()) {
        if (_closed) return;
        await _onAdded(handle);
      }
    });
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
    _rescanTimer?.cancel();
    await _subscription?.cancel();
    await _pending;
    await _ingested.close();
  }

  Future<void> _enqueue(Future<void> Function() work) {
    final next = _pending.then((_) => work()).catchError((Object _) {});
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

  bool _wanted(CameraObject object) => switch (_format) {
    DownloadFormat.jpeg => object.kind == CameraObjectKind.jpeg,
    DownloadFormat.raw => object.kind == CameraObjectKind.raw,
    DownloadFormat.both => true,
  };

  Future<bool> _isKnown(String key) async =>
      _baseline.keys.contains(key) ||
      (await _history.load()).contains(key) ||
      await _queue.contains(key);

  /// Whether the object needs no further attempt.
  Future<bool> _ingest(CameraObject object) async {
    if (!_wanted(object)) return true;
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
        if (object.kind == CameraObjectKind.jpeg) {
          await _onJpegFetched?.call(key, file);
        }
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
