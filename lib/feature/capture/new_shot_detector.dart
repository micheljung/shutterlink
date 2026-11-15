import 'dart:async';

import '../../ptpip/camera_client.dart';

/// Starts the repeating timer that triggers a diff. Injectable so tests drive
/// ticks without waiting on the clock.
typedef PeriodicTimerFactory = Timer Function(
  Duration interval,
  void Function() onTick,
);

/// Finds shots a camera has taken, as candidate handles only. It does no
/// objectInfo, no fetch and no format filtering; the consumer does.
///
/// Handles come from the camera's object-added events and from a diff of the
/// newest folder, because not every body reports new shots (the EOS R sends
/// no ObjectAdded at all). The diff runs periodically and at once when the
/// camera reports a storage change. Each diff emits every newest-folder
/// handle that is neither in the baseline nor resolved, so a failed attempt is
/// retried on the next diff without any event.
class NewShotDetector {
  NewShotDetector({
    required this._client,
    required this._baseline,
    required this._isResolved,
    required this._consumerBusy,
    this._interval = defaultInterval,
    PeriodicTimerFactory? periodicTimer,
  }) : _periodicTimer = periodicTimer ?? _realPeriodicTimer;

  static const defaultInterval = Duration(seconds: 2);

  static Timer _realPeriodicTimer(Duration interval, void Function() onTick) =>
      Timer.periodic(interval, (_) => onTick());

  final CameraClient _client;
  final Set<int> _baseline;
  final bool Function(int handle) _isResolved;
  final bool Function() _consumerBusy;
  final Duration _interval;
  final PeriodicTimerFactory _periodicTimer;
  final _handles = StreamController<int>.broadcast(sync: true);
  final _changed = StreamController<void>.broadcast(sync: true);
  StreamSubscription<int>? _subscription;
  StreamSubscription<void>? _storageSubscription;
  Timer? _timer;
  bool _started = false;
  bool _closed = false;
  bool _diffRunning = false;
  bool _diffPending = false;

  /// Candidate handles. A handle may repeat across diffs until it resolves.
  Stream<int> get handles => _handles.stream;

  /// One tick after each completed diff of the card.
  Stream<void> get changed => _changed.stream;

  void start() {
    if (_closed || _started) return;
    _started = true;
    _subscription = _client.addedObjects.listen((handle) {
      if (!_closed) _handles.add(handle);
    });
    _storageSubscription = _client.storageChanged.listen((_) => _trigger());
    final timer = _periodicTimer(_interval, _trigger);
    _timer = timer;
    _client.disconnected.then((_) => timer.cancel());
  }

  /// Tells the detector its consumer has run out of work, so a diff skipped
  /// while it was busy can run now.
  void notifyIdle() => _drain();

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    await _subscription?.cancel();
    await _storageSubscription?.cancel();
    unawaited(_handles.close());
    unawaited(_changed.close());
  }

  void _trigger() {
    _diffPending = true;
    _drain();
  }

  /// Runs the one pending diff once nothing is running and the consumer is
  /// idle; ticks that arrive meanwhile only keep that single flag set.
  void _drain() {
    if (_closed || !_diffPending || _diffRunning || _consumerBusy()) {
      return;
    }
    _diffPending = false;
    _diffRunning = true;
    _diff().whenComplete(() {
      _diffRunning = false;
      _drain();
    });
  }

  Future<void> _diff() async {
    try {
      final newest = await _client.newestFolderHandles();
      if (_closed) return;
      for (final handle in newest.toSet()) {
        if (_baseline.contains(handle) || _isResolved(handle)) continue;
        _handles.add(handle);
      }
      if (!_closed) _changed.add(null);
    } on Object {
      // The next tick diffs again; an error must not escape the timer.
    }
  }
}
