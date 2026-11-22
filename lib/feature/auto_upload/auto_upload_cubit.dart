import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/download_history.dart';
import '../../data/live_service.dart';
import '../../data/settings_repository.dart';
import '../../ptpip/camera_client.dart';
import '../../upload/upload_queue.dart';
import '../connect/connect_cubit.dart';
import '../connect/connect_state.dart';
import '../live/live_ingestor.dart';
import '../mode/mode_cubit.dart';
import '../mode/operating_mode.dart';

typedef LiveIngestorFactory = LiveIngestor Function(
  CameraClient client,
  LiveBaseline baseline,
);

enum AutoUploadPhase {
  /// The mode is not active.
  idle,

  /// Waiting for the camera, or reading what is on its card.
  starting,

  /// New shots are uploaded.
  running,
}

/// A shot uploaded in this run, with the client it came from: its handle
/// means nothing to a later client.
class RecentShot extends Equatable {
  const RecentShot(this.object, this.client);

  final CameraObject object;
  final CameraClient client;

  @override
  List<Object?> get props => [object, client];
}

class AutoUploadState extends Equatable {
  const AutoUploadState({
    this.phase = AutoUploadPhase.idle,
    this.backlog,
    this.detected = 0,
    this.uploaded = 0,
    this.pending = 0,
    this.failed = 0,
    this.recent = const [],
    this.notificationsDenied = false,
  });

  final AutoUploadPhase phase;

  /// Photos already on the card that are not uploaded; set while the user
  /// has not said whether to upload them too.
  final int? backlog;

  /// New shots saved and queued since the mode was entered.
  final int detected;

  /// Uploads confirmed since the mode was entered.
  final int uploaded;

  /// Items in the queue not confirmed yet, as the upload indicator counts.
  final int pending;

  /// Items whose last attempt failed.
  final int failed;

  /// The newest shots first.
  final List<RecentShot> recent;

  /// The mode runs, but its notification is hidden.
  final bool notificationsDenied;

  AutoUploadState copyWith({
    AutoUploadPhase? phase,
    int? Function()? backlog,
    int? detected,
    int? uploaded,
    int? pending,
    int? failed,
    List<RecentShot>? recent,
    bool? notificationsDenied,
  }) => AutoUploadState(
    phase: phase ?? this.phase,
    backlog: backlog == null ? this.backlog : backlog(),
    detected: detected ?? this.detected,
    uploaded: uploaded ?? this.uploaded,
    pending: pending ?? this.pending,
    failed: failed ?? this.failed,
    recent: recent ?? this.recent,
    notificationsDenied: notificationsDenied ?? this.notificationsDenied,
  );

  @override
  List<Object?> get props => [
    phase,
    backlog,
    detected,
    uploaded,
    pending,
    failed,
    recent,
    notificationsDenied,
  ];
}

/// Runs Auto Upload while [ModeCubit] has it selected: new shots on the
/// connected camera go to the destination, in the background too, and a
/// reconnected camera catches up on what was shot meanwhile. The
/// connection itself belongs to [ConnectCubit].
class AutoUploadCubit extends Cubit<AutoUploadState> {
  AutoUploadCubit({
    required this._connect,
    required this._modes,
    required this._service,
    required this._queue,
    required this._ingestorFactory,
    required this._format,
  }) : super(const AutoUploadState()) {
    _modeSubscription = _modes.stream.listen(_onMode);
    _connectSubscription = _connect.stream.listen(_onConnection);
    _stopSubscription = _service.stopRequests.listen((_) => _onStopRequest());
    _onMode(_modes.state);
  }

  static const title = 'Auto Upload';
  static const recentLimit = 12;
  static const connectingText = 'Connecting to the camera';
  static const runningText = 'Waiting for new photos';
  static const reconnectingText = 'Reconnecting to the camera';
  static const unreachableText = 'Camera not reachable';
  static const userActionText = 'Open Shutterlink to allow USB access';
  static const notRespondingText = ConnectCubit.notRespondingMessage;

  final ConnectCubit _connect;
  final ModeCubit _modes;
  final LiveService _service;
  final UploadQueue _queue;
  final LiveIngestorFactory _ingestorFactory;
  final DownloadFormat Function() _format;
  late final StreamSubscription<OperatingMode?> _modeSubscription;
  late final StreamSubscription<ConnectState> _connectSubscription;
  late final StreamSubscription<void> _stopSubscription;
  StreamSubscription<UploadQueueSnapshot>? _snapshotSubscription;
  StreamSubscription<CameraObject>? _ingestedSubscription;
  LiveIngestor? _ingestor;

  /// The client shots are taken from; null while the camera reconnects.
  CameraClient? _client;

  /// The card at entry, or nothing once the user wants it uploaded too.
  LiveBaseline? _baseline;
  bool _active = false;

  /// Set once the service runs; connection changes wait for it.
  bool _ready = false;
  int _session = 0;
  int _completedBefore = 0;
  LiveStatus? _reported;

  static String photosText(int count) =>
      count == 1 ? '1 new photo' : '$count new photos';

  /// Answers the backlog question: [upload] also sends the photos that were
  /// on the card before, otherwise only new shots go.
  void uploadBacklog({required bool upload}) {
    if (state.backlog == null || isClosed) return;
    _emit(state.copyWith(backlog: () => null));
    if (!upload) return;
    _baseline = const LiveBaseline(keys: {});
    final client = _client;
    if (client == null) return;
    _startIngestor(client, const LiveBaseline(keys: {}));
    unawaited(_ingestor?.catchUp());
  }

  void _onMode(OperatingMode? mode) {
    if (isClosed) return;
    if (mode == OperatingMode.autoUpload && !_active) {
      unawaited(_enter());
    } else if (mode != OperatingMode.autoUpload && _active) {
      unawaited(_leave());
    }
  }

  /// The notification's Stop leaves the mode, with the camera connected.
  /// With no mode open, a leftover service stops; another mode's Stop is
  /// that mode's to handle.
  void _onStopRequest() {
    if (_active) return _modes.leave();
    if (_modes.state == null) unawaited(_guard(_service.stop));
  }

  Future<void> _enter() async {
    _active = true;
    final session = ++_session;
    _completedBefore = _queue.snapshot.completed;
    _emit(_withQueue(const AutoUploadState(phase: AutoUploadPhase.starting)));
    final permitted = await _notificationsPermitted();
    if (!_isCurrent(session)) return;
    _emit(state.copyWith(notificationsDenied: !permitted));
    final status = _reported = _status();
    await _guard(() => _service.start(status));
    if (!_isCurrent(session)) return;
    _snapshotSubscription = _queue.snapshots.listen((_) {
      _emit(_withQueue(state));
      _report();
    });
    unawaited(_connect.setHoldNetwork(true));
    _ready = true;
    _onConnection(_connect.state);
  }

  Future<void> _leave() async {
    _active = false;
    _ready = false;
    _session++;
    _client = null;
    _baseline = null;
    _reported = null;
    final ingestor = _dropIngestor();
    unawaited(_snapshotSubscription?.cancel());
    _snapshotSubscription = null;
    unawaited(_connect.setHoldNetwork(false));
    _emit(const AutoUploadState());
    await _guard(_service.stop);
    await ingestor;
  }

  void _onConnection(ConnectState connection) {
    if (!_ready || isClosed) return;
    switch (connection) {
      case ConnectConnected(:final client) when client != _client:
        unawaited(_attach(client, _session));
      case ConnectReconnecting():
        _client = null;
        unawaited(_dropIngestor());
      default:
    }
    _report();
  }

  /// Reads the card on the first client, and catches up on a later one. A
  /// failed read closes the client, so the camera reconnects and tries
  /// again.
  Future<void> _attach(CameraClient client, int session) async {
    _client = client;
    unawaited(_dropIngestor());
    final known = _baseline;
    if (known != null) {
      // Handles may be renumbered per session; only the keys carry over.
      _startIngestor(client, LiveBaseline(keys: known.keys));
      _emit(state.copyWith(phase: AutoUploadPhase.running));
      _report();
      unawaited(_ingestor?.catchUp());
      return;
    }
    final LiveBaseline baseline;
    final int backlog;
    try {
      final photos = await client.listPhotos();
      final cameraKey = cameraKeyOf(client.deviceInfo);
      baseline = LiveBaseline.of(cameraKey, photos);
      backlog = await LiveIngestor.backlogOf(
        photos,
        cameraKey: cameraKey,
        format: _format(),
        queue: _queue,
      );
    } on Exception {
      if (_isCurrent(session) && _client == client) {
        unawaited(client.close());
      }
      return;
    }
    if (!_isCurrent(session) || _client != client) return;
    _baseline = baseline;
    _startIngestor(client, baseline);
    _emit(
      state.copyWith(
        phase: AutoUploadPhase.running,
        backlog: () => backlog > 0 ? backlog : null,
      ),
    );
    _report();
  }

  void _startIngestor(CameraClient client, LiveBaseline baseline) {
    unawaited(_dropIngestor());
    final ingestor = _ingestor = _ingestorFactory(client, baseline);
    _ingestedSubscription = ingestor.ingested.listen((object) {
      _emit(
        state.copyWith(
          detected: state.detected + 1,
          recent: [
            RecentShot(object, client),
            ...state.recent,
          ].take(recentLimit).toList(),
        ),
      );
      _report();
    });
    ingestor.start();
  }

  /// Stops ingesting at once; the returned future waits for an ingest
  /// that is already running.
  Future<void> _dropIngestor() async {
    final closing = _ingestor?.close();
    final cancelling = _ingestedSubscription?.cancel();
    _ingestor = null;
    _ingestedSubscription = null;
    await cancelling;
    await closing;
  }

  bool _isCurrent(int session) => session == _session && !isClosed;

  Future<bool> _notificationsPermitted() async {
    try {
      return await _service.requestNotificationPermission();
    } on PlatformException {
      return false;
    }
  }

  AutoUploadState _withQueue(AutoUploadState next) {
    final snapshot = _queue.snapshot;
    final open = snapshot.items.where((item) => !item.state.isUploaded);
    return next.copyWith(
      uploaded: snapshot.completed - _completedBefore,
      pending: open.length,
      failed: open.where((item) => item.lastError != null).length,
    );
  }

  LiveStatus _status() {
    final (serviceState, text) = switch (_connect.state) {
      ConnectReconnecting(userActionNeeded: true) => (
        LiveServiceState.reconnecting,
        userActionText,
      ),
      ConnectReconnecting(notResponding: true) => (
        LiveServiceState.reconnecting,
        notRespondingText,
      ),
      ConnectReconnecting(unreachable: true) => (
        LiveServiceState.unreachable,
        unreachableText,
      ),
      ConnectReconnecting() => (
        LiveServiceState.reconnecting,
        reconnectingText,
      ),
      _ when state.phase == AutoUploadPhase.running => (
        LiveServiceState.transferring,
        runningText,
      ),
      _ => (LiveServiceState.connecting, connectingText),
    };
    return LiveStatus(
      title: title,
      count: state.detected,
      uploaded: state.uploaded,
      pending: state.pending,
      state: serviceState,
      text:
          '$text · ${photosText(state.detected)} · '
          '${state.uploaded} uploaded · ${state.pending} waiting',
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

  void _emit(AutoUploadState next) {
    if (!isClosed) emit(next);
  }

  @override
  Future<void> close() async {
    final active = _active;
    if (active) {
      _active = false;
      _ready = false;
      _session++;
    }
    final ingestor = _dropIngestor();
    await _modeSubscription.cancel();
    await _connectSubscription.cancel();
    await _stopSubscription.cancel();
    await _snapshotSubscription?.cancel();
    if (active) await _guard(_service.stop);
    await ingestor;
    return super.close();
  }
}
