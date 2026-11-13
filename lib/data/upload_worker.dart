import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import 'session_repository.dart';
import 'sessions_credentials.dart';
import 'sessions_upload_queue.dart';
import 'settings_repository.dart';
import 'upload_client.dart';
import 'upload_transport.dart';

const initialRetryDelay = Duration(seconds: 5);
const maxRetryDelay = Duration(minutes: 5);
const retryJitter = 0.2;

typedef TimerFactory = Timer Function(Duration delay, void Function() callback);

enum UploadWorkerStatus {
  idle,
  uploading,
  waitingForNetwork,
  notConfigured,
  unauthorized,
  serverConfiguration,

  /// Reading the token or the queue failed; retried with backoff.
  retrying,
}

class UploadWorker {
  UploadWorker({
    required this._queue,
    required this._transport,
    required this._sessions,
    required this._settings,
    required this._credentials,
    this._client = const UploadClient(),
    this._clock = const Clock(),
    Random? random,
    this._timer = Timer.new,
  }) : _random = random ?? Random();

  final SessionsUploadQueue _queue;
  final UploadTransport _transport;
  final SessionRepository _sessions;
  final SettingsRepository _settings;
  final SessionsCredentials _credentials;
  final UploadClient _client;
  final Clock _clock;
  final Random _random;
  final TimerFactory _timer;
  final _status = ValueNotifier(UploadWorkerStatus.idle);
  StreamSubscription<void>? _enqueued;
  Timer? _wakeTimer;
  Future<void>? _running;
  bool _again = false;
  int _failedSteps = 0;
  bool _unavailableDuringRequest = false;
  bool _disposed = false;

  ValueListenable<UploadWorkerStatus> get status => _status;

  bool get _paused =>
      _status.value == UploadWorkerStatus.unauthorized ||
      _status.value == UploadWorkerStatus.serverConfiguration;

  void start() {
    _transport.available.addListener(_onAvailability);
    _enqueued = _queue.enqueued.listen((_) => drain());
    unawaited(drain());
  }

  Future<void> wake() {
    if (_paused) _status.value = UploadWorkerStatus.idle;
    return drain();
  }

  Future<void> drain() {
    if (_disposed) return Future.value();
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _run().whenComplete(() {
      _running = null;
      if (_again) unawaited(drain());
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    _transport.available.removeListener(_onAvailability);
    _wakeTimer?.cancel();
    await _enqueued?.cancel();
    await _running;
    _status.dispose();
  }

  void _onAvailability() {
    if (_transport.available.value) {
      unawaited(drain());
    } else {
      _unavailableDuringRequest = true;
    }
  }

  Future<void> _run() async {
    do {
      _again = false;
      while (!_disposed && await _guardedStep()) {}
    } while (_again && !_disposed);
  }

  Future<bool> _guardedStep() async {
    try {
      final more = await _step();
      _failedSteps = 0;
      return more;
    } on Object {
      if (_disposed) return false;
      _failedSteps++;
      _status.value = UploadWorkerStatus.retrying;
      _arm(_retryDelay(_failedSteps), drain);
      return false;
    }
  }

  Future<bool> _step() async {
    if (_paused) return false;
    if (!_transport.available.value) {
      _status.value = UploadWorkerStatus.waitingForNetwork;
      return false;
    }
    final serverUrl = Uri.tryParse(_settings.sessionsServerUrl ?? '');
    final token = await _credentials.token();
    if (serverUrl == null || !serverUrl.hasAuthority || token == null) {
      _status.value = UploadWorkerStatus.notConfigured;
      return false;
    }
    final item = await _queue.nextDue();
    if (item == null) {
      _status.value = UploadWorkerStatus.idle;
      await _scheduleWake();
      return false;
    }
    _status.value = UploadWorkerStatus.uploading;
    _unavailableDuringRequest = false;
    final client = _transport.client();
    final UploadResult result;
    try {
      result = await _client.upload(
        client,
        serverUrl: serverUrl,
        token: token,
        item: item,
      );
    } finally {
      client.close();
    }
    return _handle(item, result);
  }

  Future<bool> _handle(UploadItem item, UploadResult result) async {
    switch (result) {
      case UploadDone(:final expiresAt):
        await _sessions.setExpiresAt(item.sessionCode, expiresAt);
        await _queue.complete(item);
      case UploadExpired():
        await _sessions.markExpired(item.sessionCode);
        await _queue.complete(item, expired: true);
      case UploadRejected():
        await _queue.drop(item);
      case UploadUnauthorized():
        await _queue.reschedule(item.copyWith(lastStatus: result.status));
        _status.value = UploadWorkerStatus.unauthorized;
        return false;
      case UploadMisconfigured():
        await _queue.reschedule(item.copyWith(lastStatus: result.status));
        _status.value = UploadWorkerStatus.serverConfiguration;
        _arm(maxRetryDelay, wake);
        return false;
      case UploadRetry():
        final now = _clock.now().toUtc();
        final bound = _unavailableDuringRequest || !_transport.available.value;
        final attempts = bound ? item.attempts : item.attempts + 1;
        await _queue.reschedule(
          item.copyWith(
            attempts: attempts,
            nextAttemptAt: bound ? now : now.add(_retryDelay(attempts)),
            lastStatus: result.status,
          ),
        );
    }
    return true;
  }

  Duration _retryDelay(int attempts) {
    final exponential =
        initialRetryDelay.inMicroseconds * pow(2, max(0, attempts - 1));
    final capped = min(exponential, maxRetryDelay.inMicroseconds);
    final jitter = 1 + retryJitter * (2 * _random.nextDouble() - 1);
    return Duration(microseconds: (capped * jitter).round());
  }

  Future<void> _scheduleWake() async {
    final next = await _queue.nextAttemptAt();
    if (next == null) {
      _wakeTimer?.cancel();
      return;
    }
    final delay = next.difference(_clock.now());
    _arm(delay.isNegative ? Duration.zero : delay, drain);
  }

  void _arm(Duration delay, Future<void> Function() action) {
    _wakeTimer?.cancel();
    if (_disposed) return;
    _wakeTimer = _timer(delay, () => unawaited(action()));
  }
}
