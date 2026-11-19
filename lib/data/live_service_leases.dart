import 'dart:async';

import 'live_service.dart';

/// Shares the one foreground service between modes that can run at once,
/// e.g. Auto Upload during a time-lapse. The service runs while any holder
/// has started it, the notification shows the holder that updated it last,
/// and its Stop goes to that holder only.
class LiveServiceLeases {
  LiveServiceLeases(this._service) {
    _service.stopRequests.listen((_) {
      final shown = _shown;
      if (shown != null) shown._stopRequests.add(null);
    });
  }

  static final _shared = Expando<LiveServiceLeases>();

  /// The leases of [service], made on first use.
  static LiveServiceLeases of(LiveService service) =>
      _shared[service] ??= LiveServiceLeases(service);

  final LiveService _service;
  final _running = <_Lease>[];
  _Lease? _shown;

  /// A view of the service for one holder.
  LiveService lease() => _Lease(this);

  Future<void> _start(_Lease lease, LiveStatus status) async {
    lease._status = status;
    final first = _running.isEmpty;
    if (!_running.contains(lease)) _running.add(lease);
    _shown = lease;
    await (first ? _service.start(status) : _service.updateStatus(status));
  }

  Future<void> _update(_Lease lease, LiveStatus status) async {
    lease._status = status;
    if (!_running.contains(lease)) return;
    _shown = lease;
    await _service.updateStatus(status);
  }

  Future<void> _stop(_Lease lease) async {
    final wasRunning = _running.remove(lease);
    if (_running.isEmpty) {
      _shown = null;
      // A holder may stop a service it never started, e.g. on a Stop tap
      // that arrived late; it only ends the service when nobody holds it.
      await _service.stop();
      return;
    }
    if (!wasRunning || _shown != lease) return;
    final next = _running.last;
    _shown = next;
    final status = next._status;
    if (status != null) await _service.updateStatus(status);
  }
}

class _Lease implements LiveService {
  _Lease(this._leases);

  final LiveServiceLeases _leases;
  final _stopRequests = StreamController<void>.broadcast();
  LiveStatus? _status;

  @override
  Future<void> start(LiveStatus status) => _leases._start(this, status);

  @override
  Future<void> updateStatus(LiveStatus status) => _leases._update(this, status);

  @override
  Future<void> stop() => _leases._stop(this);

  @override
  Future<bool> requestNotificationPermission() =>
      _leases._service.requestNotificationPermission();

  @override
  Stream<void> get stopRequests => _stopRequests.stream;
}
