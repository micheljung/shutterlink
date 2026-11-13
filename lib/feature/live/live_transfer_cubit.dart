import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/camera_host_resolver.dart';
import '../../data/identity_repository.dart';
import '../../data/live_service.dart';
import '../../data/network_binder.dart';
import '../../ptpip/camera_client.dart';
import '../../upload/upload_queue.dart';
import '../connect/connect_cubit.dart';
import 'live_ingestor.dart';

typedef LiveIngestorFactory = LiveIngestor Function(
  CameraClient client,
  LiveBaseline baseline,
);

sealed class LiveTransferState extends Equatable {
  const LiveTransferState({
    this.ingested = 0,
    this.notificationsDenied = false,
  });

  /// New shots saved and queued since Live started.
  final int ingested;

  /// Live runs, but its notification is hidden.
  final bool notificationsDenied;

  @override
  List<Object?> get props => [ingested, notificationsDenied];
}

class LiveIdle extends LiveTransferState {
  const LiveIdle();
}

class LiveConnecting extends LiveTransferState {
  const LiveConnecting({super.ingested, super.notificationsDenied});
}

class LiveTransferring extends LiveTransferState {
  const LiveTransferring({super.ingested, super.notificationsDenied});
}

class LiveReconnecting extends LiveTransferState {
  const LiveReconnecting({
    super.ingested,
    super.notificationsDenied,
    this.unreachable = false,
  });

  /// Retries have slowed down because the camera stayed away.
  final bool unreachable;

  @override
  List<Object?> get props => [...super.props, unreachable];
}

/// Runs a Live session: owns the camera connection while it lasts, ingests
/// new shots, reconnects until the user stops, and keeps the foreground
/// service's notification current.
class LiveTransferCubit extends Cubit<LiveTransferState> {
  LiveTransferCubit({
    required this._connect,
    required this._connector,
    required this._identity,
    required this._hostResolver,
    required this._networkBinder,
    required this._service,
    required this._queue,
    required this._ingestorFactory,
    DateTime Function()? clock,
    TimerFactory? timerFactory,
  }) : _clock = clock ?? DateTime.now,
       _timerFactory = timerFactory ?? Timer.new,
       super(const LiveIdle()) {
    _stopSubscription = _service.stopRequests.listen((_) => stop());
  }

  static const bindingOwner = 'live';
  static const initialReconnectDelay = Duration(seconds: 2);
  static const reconnectDelayFactor = 2;
  static const maxReconnectDelay = Duration(seconds: 30);
  static const unreachableReconnectDelay = Duration(seconds: 60);

  /// Failing this long counts as the camera being gone.
  static const unreachableAfter = Duration(minutes: 10);

  static const connectingText = 'Connecting to the camera';
  static const transferringText = 'Live transfer';
  static const reconnectingText = 'Reconnecting to the camera';
  static const unreachableText = 'Camera not reachable';

  final ConnectCubit _connect;
  final CameraConnector _connector;
  final IdentityRepository _identity;
  final CameraHostResolver _hostResolver;
  final NetworkBinder _networkBinder;
  final LiveService _service;
  final UploadQueue _queue;
  final LiveIngestorFactory _ingestorFactory;
  final DateTime Function() _clock;
  final TimerFactory _timerFactory;
  late final StreamSubscription<void> _stopSubscription;
  final _subscriptions = <StreamSubscription<Object?>>[];
  StreamSubscription<Object?>? _ingestedSubscription;
  CameraClient? _client;
  LiveIngestor? _ingestor;
  LiveBaseline? _baseline;
  String? _cameraHost;
  Timer? _retryTimer;
  Duration _reconnectDelay = initialReconnectDelay;
  DateTime? _failingSince;
  bool _unreachable = false;
  int _uploadedBefore = 0;
  int _session = 0;
  int? _reconnecting;
  Future<void>? _stopping;
  LiveStatus? _reported;

  static String photosText(int count) =>
      count == 1 ? '1 new photo' : '$count new photos';

  Future<void> start() async {
    await _stopping;
    if (state is! LiveIdle || isClosed) return;
    final session = ++_session;
    emit(const LiveConnecting());
    final permitted = await _notificationsPermitted();
    if (!_isCurrent(session)) return;
    _uploadedBefore = _queue.snapshot.completed;
    _emit(LiveConnecting(notificationsDenied: !permitted));
    final status = _reported = _status();
    await _guard(() => _service.start(status));
    if (!_isCurrent(session)) return;
    _subscriptions
      ..add(_networkBinder.bindingLost.listen((_) => _onBindingLost()))
      ..add(_queue.snapshots.listen((_) => _report()));
    final client = _client = _connect.handOver(bindingOwner);
    if (client == null) return _tryReconnect(session);
    String? gateway;
    try {
      gateway = await _networkBinder.acquireBinding(
        bindingOwner,
        holdNetwork: true,
      );
    } on PlatformException {
      gateway = null;
    }
    if (!_isCurrent(session)) return _releaseStale();
    _cameraHost = await _hostResolver.resolve(boundGateway: gateway);
    if (!_isCurrent(session)) return;
    if (!await _attach(client, catchUp: false)) _scheduleReconnect(session);
  }

  /// Ends Live. A connected camera goes back to the gallery.
  Future<void> stop() {
    if (isClosed) return Future.value();
    return _stopping ??= _stop().whenComplete(() => _stopping = null);
  }

  Future<void> _stop() async {
    if (state is LiveIdle) return _guard(_service.stop);
    _session++;
    final client = _client;
    _client = null;
    await _teardown();
    _emit(const LiveIdle());
    await _guard(_service.stop);
    if (client != null && _connect.takeBack(client, owner: bindingOwner)) {
      return;
    }
    _connect.takeBack(null, owner: bindingOwner);
    try {
      await client?.close();
    } on Exception {
      // The connection is gone either way; the binding must still go.
    }
    await _release();
  }

  bool _isCurrent(int session) => session == _session && !isClosed;

  Future<bool> _notificationsPermitted() async {
    try {
      return await _service.requestNotificationPermission();
    } on PlatformException {
      return false;
    }
  }

  /// Live owns [client] until a disconnect, Stop or close takes it.
  Future<bool> _attach(CameraClient client, {required bool catchUp}) async {
    final previous = _client;
    _client = client;
    if (previous != null && previous != client) unawaited(previous.close());
    final known = _baseline;
    final LiveBaseline baseline;
    try {
      baseline = known == null
          ? _baseline = await LiveIngestor.baselineOf(client)
          : LiveBaseline(keys: known.keys);
    } on Exception {
      if (_client != client) return false;
      _client = null;
      await client.close();
      return false;
    }
    if (_client != client) return false;
    unawaited(_ingestor?.close());
    final ingestor = _ingestor = _ingestorFactory(client, baseline);
    await _ingestedSubscription?.cancel();
    _ingestedSubscription = null;
    if (_client != client) {
      unawaited(ingestor.close());
      return false;
    }
    _ingestedSubscription = ingestor.ingested.listen((_) {
      _emit(_withIngested(state.ingested + 1));
      _report();
    });
    ingestor.start();
    unawaited(client.disconnected.then((_) => _onDisconnected(client)));
    _reconnectDelay = initialReconnectDelay;
    _failingSince = null;
    _unreachable = false;
    _emit(
      LiveTransferring(
        ingested: state.ingested,
        notificationsDenied: state.notificationsDenied,
      ),
    );
    _report();
    if (catchUp) unawaited(ingestor.catchUp());
    return true;
  }

  void _onBindingLost() {
    final client = _client;
    if (client == null) return;
    _onDisconnected(client);
    unawaited(client.close());
  }

  void _onDisconnected(CameraClient client) {
    if (client != _client || isClosed) return;
    _client = null;
    final ingestor = _ingestor;
    _ingestor = null;
    unawaited(ingestor?.close());
    _scheduleReconnect(_session);
  }

  void _scheduleReconnect(int session) {
    if (!_isCurrent(session) ||
        _reconnecting == session ||
        (_retryTimer?.isActive ?? false)) {
      return;
    }
    final now = _clock();
    final failingSince = _failingSince ??= now;
    if (now.difference(failingSince) >= unreachableAfter) _unreachable = true;
    _emit(
      LiveReconnecting(
        ingested: state.ingested,
        notificationsDenied: state.notificationsDenied,
        unreachable: _unreachable,
      ),
    );
    _report();
    _retryTimer = _timerFactory(
      _nextDelay(),
      () => unawaited(_tryReconnect(session)),
    );
  }

  Duration _nextDelay() {
    if (_unreachable) return unreachableReconnectDelay;
    final delay = _reconnectDelay;
    final next = delay * reconnectDelayFactor;
    _reconnectDelay = next > maxReconnectDelay ? maxReconnectDelay : next;
    return delay;
  }

  Future<void> _tryReconnect(int session) async {
    if (!_isCurrent(session) || _reconnecting == session) return;
    _reconnecting = session;
    final bool attached;
    try {
      attached = await _reconnect(session);
    } finally {
      if (_reconnecting == session) _reconnecting = null;
    }
    if (!attached || _client == null) _scheduleReconnect(session);
  }

  Future<bool> _reconnect(int session) async {
    String? host;
    try {
      final gateway = await _networkBinder.acquireBinding(
        bindingOwner,
        holdNetwork: true,
      );
      if (!_isCurrent(session)) {
        await _releaseStale();
        return false;
      }
      host = await _hostResolver.resolve(boundGateway: gateway);
      final client = await _connector(host, await _identity.identity());
      if (!_isCurrent(session)) {
        await client.close();
        return false;
      }
      _cameraHost ??= host;
      if (await _attach(client, catchUp: true)) return true;
    } on Exception {
      if (!_isCurrent(session)) return false;
    }
    final cameraHost = _cameraHost;
    if (host != null && cameraHost != null && host != cameraHost) {
      _unreachable = true;
    }
    return false;
  }

  LiveTransferState _withIngested(int ingested) => switch (state) {
    LiveIdle() => state,
    LiveConnecting(:final notificationsDenied) => LiveConnecting(
      ingested: ingested,
      notificationsDenied: notificationsDenied,
    ),
    LiveTransferring(:final notificationsDenied) => LiveTransferring(
      ingested: ingested,
      notificationsDenied: notificationsDenied,
    ),
    LiveReconnecting(:final notificationsDenied, :final unreachable) =>
      LiveReconnecting(
        ingested: ingested,
        notificationsDenied: notificationsDenied,
        unreachable: unreachable,
      ),
  };

  LiveStatus _status() {
    final snapshot = _queue.snapshot;
    final (serviceState, text) = switch (state) {
      LiveIdle() ||
      LiveConnecting() => (LiveServiceState.connecting, connectingText),
      LiveTransferring() => (LiveServiceState.transferring, transferringText),
      LiveReconnecting(unreachable: false) => (
        LiveServiceState.reconnecting,
        reconnectingText,
      ),
      LiveReconnecting(unreachable: true) => (
        LiveServiceState.unreachable,
        unreachableText,
      ),
    };
    final uploaded = snapshot.completed - _uploadedBefore;
    final pending = snapshot.items
        .where((item) => !item.state.isUploaded)
        .length;
    return LiveStatus(
      count: state.ingested,
      uploaded: uploaded,
      pending: pending,
      state: serviceState,
      text:
          '$text · ${photosText(state.ingested)} · '
          '$uploaded uploaded · $pending waiting',
    );
  }

  void _report() {
    if (state is LiveIdle || isClosed) return;
    final status = _status();
    if (status == _reported) return;
    _reported = status;
    unawaited(_guard(() => _service.updateStatus(status)));
  }

  Future<void> _guard(Future<void> Function() call) async {
    try {
      await call();
    } on PlatformException {
      // The notification is best effort; Live keeps running without it.
    }
  }

  Future<void> _teardown() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _ingestedSubscription?.cancel();
    _ingestedSubscription = null;
    final ingestor = _ingestor;
    _ingestor = null;
    await ingestor?.close();
    _baseline = null;
    _cameraHost = null;
    _reconnectDelay = initialReconnectDelay;
    _failingSince = null;
    _unreachable = false;
    _reported = null;
  }

  /// Drops a binding acquired after Live ended, once Stop handed the
  /// camera's binding back.
  Future<void> _releaseStale() async {
    await _stopping;
    if (isClosed || state is LiveIdle) await _release();
  }

  Future<void> _release() async {
    try {
      await _networkBinder.releaseBinding(bindingOwner);
    } on PlatformException {
      return;
    }
  }

  void _emit(LiveTransferState next) {
    if (!isClosed) emit(next);
  }

  @override
  Future<void> close() async {
    _session++;
    final active = state is! LiveIdle;
    final client = _client;
    _client = null;
    try {
      await _stopSubscription.cancel();
      await _teardown();
      if (active) await _guard(_service.stop);
      await client?.close();
    } finally {
      await _release();
      await super.close();
    }
  }
}
