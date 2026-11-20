import 'dart:async';

import 'package:clock/clock.dart' as clocks;
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/intervalometer_repository.dart';
import '../../data/live_service.dart';
import '../../remote/demo_remote.dart';
import '../../remote/remote_bluetooth.dart';
import '../../remote/shutter_remote.dart';
import 'interval_plan.dart';
import 'interval_presets.dart';
import 'interval_run.dart';
import 'intervalometer_text.dart';

class IntervalometerState extends Equatable {
  const IntervalometerState({
    this.bluetooth = BluetoothState.unknown,
    this.camera,
    this.link = RemoteLink.disconnected,
    this.plan = const IntervalPlan(),
    this.frameRate = IntervalPlan.defaultFrameRate,
    this.run,
    this.demo = false,
    this.notificationsDenied = false,
  });

  final BluetoothState bluetooth;

  /// The paired camera, or the demo camera.
  final RemoteCamera? camera;
  final RemoteLink link;
  final IntervalPlan plan;

  /// The frame rate the clip length is shown for.
  final int frameRate;

  /// The running or last run; null while setting up.
  final RunSnapshot? run;
  final bool demo;
  final bool notificationsDenied;

  bool get running => run?.active ?? false;

  bool get canStart =>
      camera != null && link == RemoteLink.connected && plan.isValid;

  IntervalPreset? get preset => IntervalPreset.of(plan);

  IntervalometerState copyWith({
    BluetoothState? bluetooth,
    RemoteCamera? camera,
    bool clearCamera = false,
    RemoteLink? link,
    IntervalPlan? plan,
    int? frameRate,
    RunSnapshot? run,
    bool clearRun = false,
    bool? demo,
    bool? notificationsDenied,
  }) => IntervalometerState(
    bluetooth: bluetooth ?? this.bluetooth,
    camera: clearCamera ? null : camera ?? this.camera,
    link: link ?? this.link,
    plan: plan ?? this.plan,
    frameRate: frameRate ?? this.frameRate,
    run: clearRun ? null : run ?? this.run,
    demo: demo ?? this.demo,
    notificationsDenied: notificationsDenied ?? this.notificationsDenied,
  );

  @override
  List<Object?> get props => [
    bluetooth,
    camera,
    link,
    plan,
    frameRate,
    run,
    demo,
    notificationsDenied,
  ];
}

/// Plans and runs time-lapses and long exposures over a Bluetooth remote.
/// Lives as long as the app, so a run goes on after leaving its screen.
class IntervalometerCubit extends Cubit<IntervalometerState> {
  IntervalometerCubit({
    required IntervalometerRepository repository,
    required RemoteBluetooth bluetooth,
    required LiveService service,
    this._demoBluetooth = const DemoRemoteBluetooth(),
    clocks.Clock? clock,
    void Function()? alarm,
  }) : _repository = repository,
       _bluetooth = bluetooth,
       _service = service,
       _clock = clock ?? clocks.clock,
       _alarm = alarm ?? _buzz,
       super(
         IntervalometerState(
           camera: repository.camera,
           plan: repository.plan,
           frameRate: repository.frameRate,
         ),
       ) {
    _bluetoothStates = bluetooth.states.listen(
      (bluetooth) => emit(state.copyWith(bluetooth: bluetooth)),
    );
    _stopRequests = service.stopRequests.listen((_) => unawaited(stop()));
  }

  final IntervalometerRepository _repository;
  final RemoteBluetooth _bluetooth;
  final RemoteBluetooth _demoBluetooth;
  final LiveService _service;
  final clocks.Clock _clock;
  final void Function() _alarm;

  late final StreamSubscription<BluetoothState> _bluetoothStates;
  late final StreamSubscription<void> _stopRequests;
  StreamSubscription<RemoteLink>? _links;
  StreamSubscription<RunSnapshot>? _snapshots;
  ShutterRemote? _remote;
  IntervalRun? _run;
  LiveStatus? _lastStatus;
  bool _screenOpen = false;
  bool _opening = false;

  /// The pairing sheet is open: the saved camera stays let go, or its
  /// reconnects would grab the camera while it waits to pair.
  bool _pairing = false;

  /// Start was tapped and the run is being set up.
  bool _starting = false;

  RemoteBluetooth get bluetooth => _bluetooth;

  /// Stands in for a camera, to try the intervalometer without one.
  RemoteBluetooth get demoBluetooth => _demoBluetooth;

  /// The screen opened: reconnects the paired camera.
  Future<void> opened() async {
    _screenOpen = true;
    await _reattach();
  }

  Future<void> _reattach() async {
    if (state.camera == null ||
        state.demo ||
        _remote != null ||
        _opening ||
        _pairing) {
      return;
    }
    _opening = true;
    try {
      if (!await _requestAccess()) return;
      // The screen may have closed, or a pairing attached, meanwhile.
      final camera = state.camera;
      if (!_screenOpen ||
          camera == null ||
          state.demo ||
          _remote != null ||
          _pairing) {
        return;
      }
      await _attach(_bluetooth.remoteFor(camera));
    } finally {
      _opening = false;
    }
  }

  Future<bool> _requestAccess() async {
    try {
      return await _bluetooth.requestAccess();
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// The screen closed: lets the camera go unless a run needs it.
  Future<void> closed() async {
    _screenOpen = false;
    await _release();
  }

  /// Lets the camera go once neither the screen nor a run needs it.
  Future<void> _release() async {
    if (state.running || _screenOpen) return;
    await _detach();
    if (!state.demo) return;
    // The demo ends with its screen; the paired camera is back next time.
    final paired = _repository.camera;
    emit(
      state.copyWith(
        camera: paired,
        clearCamera: paired == null,
        demo: false,
        clearRun: true,
      ),
    );
  }

  /// Lets the saved camera go while the pairing sheet looks for cameras.
  Future<void> suspendForPairing() async {
    debugPrint(
      '[Intervalometer] pairing sheet open (running ${state.running})',
    );
    if (state.running) return;
    _pairing = true;
    await _detach();
  }

  /// The pairing sheet closed without pairing: the saved camera is back.
  Future<void> resumeAfterPairing() async {
    debugPrint('[Intervalometer] pairing sheet closed without pairing');
    if (!_pairing) return;
    _pairing = false;
    await _reattach();
  }

  /// [remote] connected during pairing and is kept.
  Future<void> paired(RemoteCamera camera, ShutterRemote remote) async {
    debugPrint('[Intervalometer] paired ${camera.id}');
    _pairing = false;
    await _detach();
    final demo = camera == DemoRemoteBluetooth.camera;
    if (!demo) await _repository.setCamera(camera);
    emit(state.copyWith(camera: camera, demo: demo));
    await _attach(remote);
  }

  Future<void> forgetCamera() async {
    if (state.running) return;
    await _detach();
    await _repository.setCamera(null);
    emit(state.copyWith(clearCamera: true, demo: false));
  }

  Future<void> reconnect() async {
    final remote = _remote;
    if (remote != null) {
      await _connect(remote);
      return;
    }
    await _reattach();
  }

  Future<void> _attach(ShutterRemote remote) async {
    _remote = remote;
    await _links?.cancel();
    _links = remote.links.listen(_linkChanged);
    emit(state.copyWith(link: remote.link));
    await _connect(remote);
  }

  Future<void> _connect(ShutterRemote remote) async {
    try {
      await remote.connect();
    } on RemoteException {
      // The link shows disconnected; the screen offers to try again.
    }
  }

  Future<void> _detach() async {
    final remote = _remote;
    _remote = null;
    await _links?.cancel();
    _links = null;
    await remote?.disconnect();
    if (!isClosed) emit(state.copyWith(link: RemoteLink.disconnected));
  }

  void _linkChanged(RemoteLink link) {
    final lost =
        state.link == RemoteLink.connected && link != RemoteLink.connected;
    emit(state.copyWith(link: link));
    if (lost && state.running) _alarm();
    _updateService();
  }

  void setPlan(IntervalPlan plan) {
    if (state.running) return;
    emit(state.copyWith(plan: plan));
    unawaited(_repository.setPlan(plan));
  }

  void applyPreset(IntervalPreset preset) =>
      setPlan(preset.plan.copyWith(startDelay: state.plan.startDelay));

  void setFrameRate(int rate) {
    emit(state.copyWith(frameRate: rate));
    unawaited(_repository.setFrameRate(rate));
  }

  Future<void> start() async {
    final remote = _remote;
    if (remote == null || !state.canStart || state.running || _starting) {
      return;
    }
    _starting = true;
    try {
      final permitted = await _guard(_service.requestNotificationPermission);
      final run = _run = IntervalRun(
        plan: state.plan,
        remote: remote,
        clock: _clock,
      );
      _snapshots = run.snapshots.listen((snapshot) {
        emit(state.copyWith(run: snapshot));
        _updateService();
        if (!snapshot.active) unawaited(_finished());
      });
      emit(state.copyWith(notificationsDenied: !(permitted ?? false)));
      const status = LiveStatus(
        title: IntervalometerText.title,
        count: 0,
        uploaded: 0,
        pending: 0,
        state: LiveServiceState.connecting,
        text: IntervalometerText.startingNotification,
      );
      _lastStatus = status;
      await _guard(() => _service.start(status));
      run.start();
    } finally {
      _starting = false;
    }
  }

  /// The run goes on without the notification if the service fails.
  static Future<T?> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PlatformException {
      return null;
    }
  }

  void pause() => _run?.pause();

  void resume() => _run?.resume();

  Future<void> stop() async => _run?.stop();

  /// Back to the setup after a run ended.
  void dismissRun() {
    if (state.running) return;
    emit(state.copyWith(clearRun: true));
  }

  Future<void> _finished() async {
    final run = _run;
    final snapshots = _snapshots;
    _run = null;
    _snapshots = null;
    _lastStatus = null;
    await _guard(_service.stop);
    await snapshots?.cancel();
    await run?.dispose();
    // The screen was left during the run.
    await _release();
  }

  void _updateService() {
    final run = state.run;
    if (_lastStatus == null || run == null || !run.active) return;
    final status = LiveStatus(
      title: IntervalometerText.title,
      count: run.taken,
      uploaded: 0,
      pending: run.missed,
      state: state.link == RemoteLink.connected
          ? LiveServiceState.transferring
          : LiveServiceState.reconnecting,
      text: IntervalometerText.notification(
        run,
        link: state.link,
        now: _clock.now(),
      ),
    );
    if (status == _lastStatus) return;
    _lastStatus = status;
    unawaited(_guard(() => _service.updateStatus(status)));
  }

  static void _buzz() {
    unawaited(HapticFeedback.vibrate());
    unawaited(SystemSound.play(SystemSoundType.alert));
  }

  @override
  Future<void> close() async {
    await _bluetoothStates.cancel();
    await _stopRequests.cancel();
    await _snapshots?.cancel();
    await _run?.dispose();
    await _detach();
    return super.close();
  }
}
