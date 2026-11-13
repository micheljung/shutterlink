import 'dart:async';

import '../../data/download_history.dart';
import '../../data/settings_repository.dart';
import '../../ptpip/camera_client.dart';
import '../../upload/upload_queue.dart';
import '../download/object_fetcher.dart';
import 'ingest_coordinator.dart';

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
  }) : _cameraKey = cameraKeyOf(_client.deviceInfo);

  static const defaultInfoRetryDelay = Duration(milliseconds: 500);
  static const defaultRescanInterval = Duration(seconds: 5);
  static const infoRetries = 3;

  final CameraClient _client;
  final DownloadFormat _format;
  final Set<String> _baseline;
  final DownloadHistoryRepository _history;
  final UploadQueue _queue;
  final IngestCoordinator _coordinator;
  final ObjectFetcher _fetcher;
  final Duration _infoRetryDelay;
  final Duration _rescanInterval;
  final String _cameraKey;
  final _ingested = StreamController<CameraObject>.broadcast();
  final _resolvedHandles = <int>{};
  StreamSubscription<int>? _subscription;
  Timer? _rescanTimer;
  bool _rescanQueued = false;
  Future<void> _pending = Future.value();

  /// Objects saved to the gallery and queued for upload.
  Stream<CameraObject> get ingested => _ingested.stream;

  /// Entry keys of the photos on the card when Live starts; they are never
  /// ingested.
  static Future<Set<String>> baselineOf(CameraClient client) async {
    final cameraKey = cameraKeyOf(client.deviceInfo);
    return {
      for (final object in await client.listPhotos())
        DownloadHistoryRepository.entryKey(cameraKey, object),
    };
  }

  /// Follows the camera's object-added events, and periodically diffs the
  /// newest folder because not every body reports new shots.
  void start() {
    if (_subscription != null) return;
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
        await _onAdded(handle);
      }
    });
  }

  /// Ingests what was missed while the camera was unreachable.
  Future<void> catchUp() => _enqueue(() async {
    for (final object in await _client.listPhotos()) {
      await _ingest(object);
    }
  });

  Future<void> close() async {
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
    if (_resolvedHandles.contains(handle)) return;
    final object = await _objectInfo(handle);
    if (object != null) await _ingest(object);
  }

  /// Retries while the camera is still writing the file. Gives up silently;
  /// the next rescan or the reconnect catch-up picks the file up later.
  Future<CameraObject?> _objectInfo(int handle) async {
    for (var attempt = 0; attempt <= infoRetries; attempt++) {
      if (attempt > 0) await Future<void>.delayed(_infoRetryDelay);
      try {
        final object = await _client.objectInfo(handle);
        if (object != null && object.size == 0) continue;
        _resolvedHandles.add(handle);
        return object;
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
      _baseline.contains(key) ||
      (await _history.load()).contains(key) ||
      await _queue.contains(key);

  Future<void> _ingest(CameraObject object) async {
    if (!_wanted(object)) return;
    final key = DownloadHistoryRepository.entryKey(_cameraKey, object);
    if (await _isKnown(key)) return;
    await _coordinator.run([key], () async {
      if (await _isKnown(key)) return;
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
        // Left for the reconnect catch-up.
        return;
      }
      if (!_ingested.isClosed) _ingested.add(object);
    });
  }
}
