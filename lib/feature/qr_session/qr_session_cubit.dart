import 'dart:async';

import 'package:clock/clock.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/live_service.dart';
import '../../data/session_repository.dart';
import '../../data/settings_repository.dart';
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
    this.autoResumed = false,
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

  /// The mode came back by itself with the Session that was cut off when
  /// the camera or the app went away.
  final bool autoResumed;

  @override
  List<Object?> get props => [
    active,
    resumable,
    client,
    clockSync,
    notificationsDenied,
    autoResumed,
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

  /// A Session cut off longer ago than this is not resumed by itself, so
  /// a camera connected much later sends nothing to old guests unasked.
  static const autoResumeWithin = Duration(minutes: 30);

  /// How often a running mode notes that it is alive, which dates a cut-off
  /// found at the next start.
  static const aliveInterval = Duration(minutes: 1);

  final ConnectCubit _connect;
  final ModeCubit _modes;
  final LiveService _service;
  final SessionsDependencies _sessions;
  final Clock _clock;
  late final Future<void> _cleanup;

  /// The last leave, which an enter right after it waits for, so the
  /// window it closes is not taken for an open one.
  Future<void> _leaving = Future.value();
  late final StreamSubscription<OperatingMode?> _modeSubscription;
  late final StreamSubscription<ConnectState> _connectSubscription;
  late final StreamSubscription<void> _stopSubscription;
  SessionCollector? _collector;

  /// The client collected from, or being attached; null while the camera
  /// reconnects.
  CameraClient? _client;
  bool _active = false;

  /// Set once the service runs; connection changes wait for it.
  bool _ready = false;
  int _session = 0;
  LiveStatus? _reported;
  Timer? _alive;
  StreamSubscription<void>? _windowChanges;

  /// The Session cut off by a lost camera or a killed app, and when; it is
  /// resumed once the camera connects again.
  String? _interruptedId;
  DateTime? _interruptedAt;

  SessionRepository get _repository => _sessions.repository;

  SettingsRepository get _settings => _sessions.settings;

  /// Opens a new window of the offered Session.
  Future<void> resume() async {
    final resumable = state.resumable;
    if (resumable == null || !_active) return;
    _emit(_copy(resumable: () => null, autoResumed: false));
    await _openWindow(() async {
      try {
        await _repository.reactivate(resumable.id);
      } on ReactivationBlockedException {
        await _repository.start();
      }
    });
  }

  /// Starts a new Session instead of the offered one.
  Future<void> startNew() async {
    if (!_active) return;
    _emit(_copy(resumable: () => null, autoResumed: false));
    await _openWindow(_repository.start);
  }

  /// A window that fails to open leaves the mode running with none open;
  /// the screen then offers to open one again.
  Future<void> _openWindow(Future<void> Function() open) async {
    try {
      await open();
    } on Exception {
      // Shown as no open window.
    }
  }

  /// A window left open by a crash or a kill collects nothing any more. It
  /// is closed, and resumed once the camera connects, if QR Session ran it
  /// until recently.
  Future<void> _closeLeftoverWindow() async {
    try {
      final active = await _repository.active();
      final aliveAt = _settings.qrSessionAliveAt;
      if (active != null) {
        if (aliveAt != null) {
          _interruptedId = active.id;
          _interruptedAt = aliveAt;
        }
        await _repository.stop();
      }
      if (aliveAt != null) await _settings.setQrSessionAliveAt(null);
    } on Exception {
      // Leaving the mode stops it again.
    }
    if (!isClosed) _resumeInterrupted(_connect.state);
  }

  /// Brings QR Session back with the cut-off Session once a camera is
  /// connected again, unless too much time has passed or the user picked
  /// another mode meanwhile.
  void _resumeInterrupted(ConnectState connection) {
    final at = _interruptedAt;
    if (_interruptedId == null || at == null || _active) return;
    if (_now().difference(at) > autoResumeWithin || _modes.state != null) {
      _interruptedId = null;
      _interruptedAt = null;
      return;
    }
    if (connection is ConnectConnected) _modes.select(OperatingMode.qrSession);
  }

  DateTime _now() => _clock.now().toUtc();

  void _onMode(OperatingMode? mode) {
    if (isClosed) return;
    if (mode == OperatingMode.qrSession && !_active) {
      unawaited(_enter());
    } else if (mode != OperatingMode.qrSession && _active) {
      _leaving = _leave(connectionLost: _modes.leftForConnectionLoss);
    } else if (mode != null && mode != OperatingMode.qrSession) {
      _interruptedId = null;
      _interruptedAt = null;
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
    await _leaving;
    if (!_isCurrent(session)) return;
    final interrupted = _interruptedId;
    _interruptedId = null;
    _interruptedAt = null;
    if (interrupted != null) {
      try {
        await _repository.reactivate(interrupted);
        if (_isCurrent(session)) _emit(_copy(autoResumed: true));
      } on Object {
        // Offered below, but not started unasked.
      }
    }
    await _openWindow(() async {
      if (await _repository.active() != null) return;
      final resumable = await _resumable();
      if (!_isCurrent(session)) return;
      if (resumable == null) {
        // The user didn't pick the mode; the screen offers a new Session.
        if (interrupted != null) return;
        await _repository.start();
      } else {
        _emit(_copy(resumable: () => resumable));
      }
    });
    if (!_isCurrent(session)) return;
    final permitted = await _notificationsPermitted();
    if (!_isCurrent(session)) return;
    _emit(_copy(notificationsDenied: permitted ? null : true));
    final status = _reported = _status();
    await _guard(() => _service.start(status));
    if (!_isCurrent(session)) return;
    unawaited(_connect.setHoldNetwork(true));
    _ready = true;
    _markAlive();
    _alive = Timer.periodic(aliveInterval, (_) => _markAlive());
    _windowChanges = _repository.changes.listen((_) => _markAlive());
    _onConnection(_connect.state);
  }

  /// Notes that the mode runs while a window is open, so a window found
  /// open at the next start is known to have been cut off just now.
  void _markAlive() => unawaited(
    _guardRepository(() async {
      final open = await _repository.active() != null;
      if (!_active) return;
      if (!open && state.autoResumed) _emit(_copy(autoResumed: false));
      await _settings.setQrSessionAliveAt(open ? _now() : null);
    }),
  );

  Future<void> _guardRepository(Future<void> Function() call) async {
    try {
      await call();
    } on Exception {
      // Only an automatic resume after a kill depends on it.
    }
  }

  Future<Session?> _activeSession() async {
    try {
      return await _repository.active();
    } on Exception {
      return null;
    }
  }

  /// The newest Session that may still get a new window.
  Future<Session?> _resumable() async {
    final now = _clock.now().toUtc();
    final sessions = await _repository.all();
    return sessions.reversed
        .where((session) => session.canReactivateAt(now))
        .firstOrNull;
  }

  /// A lost camera keeps the open Session to resume; the user leaving
  /// does not.
  Future<void> _leave({required bool connectionLost}) async {
    _active = false;
    _ready = false;
    _session++;
    _reported = null;
    _client = null;
    _alive?.cancel();
    _alive = null;
    unawaited(_windowChanges?.cancel());
    _windowChanges = null;
    final detaching = _detach();
    _emit(const QrSessionState());
    unawaited(_connect.setHoldNetwork(false));
    if (connectionLost) {
      final active = await _activeSession();
      _interruptedId = active?.id;
      _interruptedAt = active == null ? null : _now();
    } else {
      _interruptedId = null;
      _interruptedAt = null;
    }
    await _guardRepository(() => _settings.setQrSessionAliveAt(null));
    await _guard(_repository.stop);
    await _guard(_service.stop);
    await detaching;
  }

  void _onConnection(ConnectState connection) {
    if (isClosed) return;
    if (!_active) return _resumeInterrupted(connection);
    if (!_ready) return;
    switch (connection) {
      case ConnectConnected(:final client) when client != _client:
        unawaited(_attach(client, _session));
      case ConnectReconnecting():
        _client = null;
        unawaited(_detach());
      default:
    }
    _report();
  }

  /// New shots are looked for beyond the newest folder as it is now. A
  /// failed read closes the client, so the camera reconnects and tries
  /// again.
  Future<void> _attach(CameraClient client, int session) async {
    _client = client;
    unawaited(_detach());
    final Set<int> baseline;
    try {
      baseline = (await client.newestFolderHandles()).toSet();
    } on Exception {
      if (_isCurrent(session) && _client == client) {
        unawaited(client.close());
      }
      return;
    }
    if (!_isCurrent(session) || _client != client) return;
    final clockSync = _sessions.createClockSync(client);
    unawaited(clockSync.start());
    final collector = _collector = _sessions.createCollector(
      client,
      clockSync,
      baseline: baseline,
    )..start();
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
    bool? autoResumed,
  }) => QrSessionState(
    active: state.active,
    resumable: resumable == null ? state.resumable : resumable(),
    client: client == null ? state.client : client(),
    clockSync: clockSync == null ? state.clockSync : clockSync(),
    notificationsDenied: notificationsDenied ?? state.notificationsDenied,
    autoResumed: autoResumed ?? state.autoResumed,
  );

  void _emit(QrSessionState next) {
    if (!isClosed) emit(next);
  }

  @override
  Future<void> close() async {
    final active = _active;
    _alive?.cancel();
    await _windowChanges?.cancel();
    _active = false;
    _ready = false;
    _session++;
    _client = null;
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
