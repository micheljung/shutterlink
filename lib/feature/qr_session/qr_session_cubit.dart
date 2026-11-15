import 'dart:async';

import 'package:clock/clock.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/live_service.dart';
import '../../data/session_repository.dart';
import '../../ptpip/camera_client.dart';
import '../connect/connect_cubit.dart';
import '../connect/connect_state.dart';
import '../mode/mode_cubit.dart';
import '../mode/operating_mode.dart';
import '../sessions/clock_sync_cubit.dart';
import '../sessions/session.dart';
import '../sessions/session_collector.dart';
import '../sessions/sessions_dependencies.dart';

class QrSessionState extends Equatable {
  const QrSessionState({
    this.active = false,
    this.resumable,
    this.client,
    this.clockSync,
    this.notificationsDenied = false,
  });

  /// The mode is open.
  final bool active;

  /// The previous Session, while the user has not said whether to resume
  /// it or start a new one.
  final Session? resumable;

  /// The camera new shots are collected from; null while it reconnects.
  final CameraClient? client;

  /// The camera clock of [client].
  final ClockSyncCubit? clockSync;

  /// The mode runs, but its notification is hidden.
  final bool notificationsDenied;

  @override
  List<Object?> get props => [
    active,
    resumable,
    client,
    clockSync,
    notificationsDenied,
  ];
}

/// Runs QR Session while [ModeCubit] has it selected: shots taken during an
/// open Session window go to the Sessions server only, in the background
/// too. Leaving the mode closes the window. The connection itself belongs
/// to [ConnectCubit].
class QrSessionCubit extends Cubit<QrSessionState> {
  QrSessionCubit({
    required this._connect,
    required this._modes,
    required this._service,
    required this._sessions,
    this._clock = const Clock(),
  }) : super(const QrSessionState()) {
    _cleanup = _closeLeftoverWindow();
    _modeSubscription = _modes.stream.listen(_onMode);
    _connectSubscription = _connect.stream.listen(_onConnection);
    _stopSubscription = _service.stopRequests.listen((_) => _onStopRequest());
    _onMode(_modes.state);
  }

  static const title = 'QR Session';
  static const connectingText = 'Connecting to the camera';
  static const runningText = 'Sending new photos to the Session';
  static const reconnectingText = 'Reconnecting to the camera';
  static const unreachableText = 'Camera not reachable';
  static const userActionText = 'Open Shutterlink to allow USB access';

  final ConnectCubit _connect;
  final ModeCubit _modes;
  final LiveService _service;
  final SessionsDependencies _sessions;
  final Clock _clock;
  late final Future<void> _cleanup;
  late final StreamSubscription<OperatingMode?> _modeSubscription;
  late final StreamSubscription<ConnectState> _connectSubscription;
  late final StreamSubscription<void> _stopSubscription;
  SessionCollector? _collector;
  bool _active = false;

  /// Set once the service runs; connection changes wait for it.
  bool _ready = false;
  int _session = 0;
  LiveStatus? _reported;

  SessionRepository get _repository => _sessions.repository;

  /// Opens a new window of the offered Session.
  Future<void> resume() async {
    final resumable = state.resumable;
    if (resumable == null || !_active) return;
    _emit(_copy(resumable: () => null));
    try {
      await _repository.reactivate(resumable.id);
    } on ReactivationBlockedException {
      await _repository.start();
    }
  }

  /// Starts a new Session instead of the offered one.
  Future<void> startNew() async {
    if (!_active) return;
    _emit(_copy(resumable: () => null));
    await _repository.start();
  }

  /// A window left open by a crash or a kill collects nothing any more.
  Future<void> _closeLeftoverWindow() async {
    try {
      if (await _repository.active() != null) await _repository.stop();
    } on Exception {
      // Leaving the mode stops it again.
    }
  }

  void _onMode(OperatingMode? mode) {
    if (isClosed) return;
    if (mode == OperatingMode.qrSession && !_active) {
      unawaited(_enter());
    } else if (mode != OperatingMode.qrSession && _active) {
      unawaited(_leave());
    }
  }

  /// The notification's Stop leaves the mode, with the camera connected.
  void _onStopRequest() {
    if (_active) _modes.leave();
  }

  Future<void> _enter() async {
    _active = true;
    final session = ++_session;
    _emit(const QrSessionState(active: true));
    await _cleanup;
    final resumable = await _resumable();
    if (!_isCurrent(session)) return;
    if (resumable == null) {
      await _repository.start();
    } else {
      _emit(_copy(resumable: () => resumable));
    }
    final permitted = await _notificationsPermitted();
    if (!_isCurrent(session)) return;
    _emit(_copy(notificationsDenied: permitted ? null : true));
    final status = _reported = _status();
    await _guard(() => _service.start(status));
    if (!_isCurrent(session)) return;
    unawaited(_connect.setHoldNetwork(true));
    _ready = true;
    _onConnection(_connect.state);
  }

  /// The newest Session that may still get a new window.
  Future<Session?> _resumable() async {
    final now = _clock.now().toUtc();
    final sessions = await _repository.all();
    return sessions.reversed
        .where((session) => session.canReactivateAt(now))
        .firstOrNull;
  }

  Future<void> _leave() async {
    _active = false;
    _ready = false;
    _session++;
    _reported = null;
    final detaching = _detach();
    _emit(const QrSessionState());
    unawaited(_connect.setHoldNetwork(false));
    await _guard(_repository.stop);
    await _guard(_service.stop);
    await detaching;
  }

  void _onConnection(ConnectState connection) {
    if (!_ready || isClosed) return;
    switch (connection) {
      case ConnectConnected(:final client) when client != state.client:
        _attach(client);
      case ConnectReconnecting():
        unawaited(_detach());
      default:
    }
    _report();
  }

  void _attach(CameraClient client) {
    unawaited(_detach());
    final clockSync = _sessions.createClockSync(client);
    unawaited(clockSync.start());
    final collector = _collector = _sessions.createCollector(client, clockSync)
      ..start();
    unawaited(collector.rescan());
    _emit(_copy(client: () => client, clockSync: () => clockSync));
  }

  /// Stops collecting from the camera at once; the returned future waits
  /// for a transfer that is already running.
  Future<void> _detach() async {
    final collector = _collector;
    final clockSync = state.clockSync;
    _collector = null;
    final disposing = collector?.dispose();
    if (state.client != null) {
      _emit(_copy(client: () => null, clockSync: () => null));
    }
    await disposing;
    await clockSync?.close();
  }

  bool _isCurrent(int session) => session == _session && !isClosed;

  Future<bool> _notificationsPermitted() async {
    try {
      return await _service.requestNotificationPermission();
    } on PlatformException {
      return false;
    }
  }

  LiveStatus _status() {
    final (serviceState, text) = switch (_connect.state) {
      ConnectReconnecting(userActionNeeded: true) => (
        LiveServiceState.reconnecting,
        userActionText,
      ),
      ConnectReconnecting(unreachable: true) => (
        LiveServiceState.unreachable,
        unreachableText,
      ),
      ConnectReconnecting() => (
        LiveServiceState.reconnecting,
        reconnectingText,
      ),
      _ when state.client != null => (
        LiveServiceState.transferring,
        runningText,
      ),
      _ => (LiveServiceState.connecting, connectingText),
    };
    return LiveStatus(
      title: title,
      count: 0,
      uploaded: 0,
      pending: 0,
      state: serviceState,
      text: text,
    );
  }

  void _report() {
    if (!_ready || isClosed) return;
    final status = _status();
    if (status == _reported) return;
    _reported = status;
    unawaited(_guard(() => _service.updateStatus(status)));
  }

  Future<void> _guard(Future<void> Function() call) async {
    try {
      await call();
    } on PlatformException {
      // The notification is best effort; the mode runs without it.
    }
  }

  QrSessionState _copy({
    Session? Function()? resumable,
    CameraClient? Function()? client,
    ClockSyncCubit? Function()? clockSync,
    bool? notificationsDenied,
  }) => QrSessionState(
    active: state.active,
    resumable: resumable == null ? state.resumable : resumable(),
    client: client == null ? state.client : client(),
    clockSync: clockSync == null ? state.clockSync : clockSync(),
    notificationsDenied: notificationsDenied ?? state.notificationsDenied,
  );

  void _emit(QrSessionState next) {
    if (!isClosed) emit(next);
  }

  @override
  Future<void> close() async {
    final active = _active;
    _active = false;
    _ready = false;
    _session++;
    final detaching = _detach();
    await _modeSubscription.cancel();
    await _connectSubscription.cancel();
    await _stopSubscription.cancel();
    if (active) {
      await _guard(_repository.stop);
      await _guard(_service.stop);
    }
    await detaching;
    return super.close();
  }
}
