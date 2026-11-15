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
import '../../usb/usb_camera_platform.dart';
import '../connect/connect_cubit.dart';
import '../connect/connection_supervisor.dart';
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
    this.userActionNeeded = false,
  });

  /// Retries have slowed down because the camera stayed away.
  final bool unreachable;

  /// The USB camera is back, but the user must allow access in the app.
  final bool userActionNeeded;

  @override
  List<Object?> get props => [...super.props, unreachable, userActionNeeded];
}

/// Runs a Live session: owns the camera connection while it lasts, ingests
/// new shots, reconnects until the user stops, and keeps the foreground
/// service's notification current.
class LiveTransferCubit extends Cubit<LiveTransferState> {
  LiveTransferCubit({
    required this._connect,
    required CameraConnector connector,
    required IdentityRepository identity,
    required CameraHostResolver hostResolver,
    required this._networkBinder,
    required this._service,
    required this._queue,
    required this._ingestorFactory,
    required this._claimsUsbVendor,
    this._usbWatcher = const NoUsbCameraWatcher(),
    DateTime Function()? clock,
    TimerFactory? timerFactory,
  }) : super(const LiveIdle()) {
    _supervisor = ConnectionSupervisor(
      connector: connector,
      identity: identity,
      hostResolver: hostResolver,
      networkBinder: _networkBinder,
      usbWatcher: _usbWatcher,
      validate: _prepare,
      onConnected: _onConnected,
      onDisconnected: (_) => _dropIngestor(),
      onReconnecting: _onReconnecting,
      releaseStale: _releaseStale,
      clock: clock,
      timerFactory: timerFactory,
    );
    _stopSubscription = _service.stopRequests.listen((_) => stop());
  }

  static const bindingOwner = 'live';
  static const initialReconnectDelay =
      ConnectionSupervisor.initialReconnectDelay;
  static const reconnectDelayFactor = ConnectionSupervisor.reconnectDelayFactor;
  static const maxReconnectDelay = ConnectionSupervisor.maxReconnectDelay;
  static const unreachableReconnectDelay =
      ConnectionSupervisor.unreachableReconnectDelay;

  /// Failing this long counts as the camera being gone.
  static const unreachableAfter = ConnectionSupervisor.unreachableAfter;

  static const connectingText = 'Connecting to the camera';
  static const transferringText = 'Live transfer';
  static const reconnectingText = 'Reconnecting to the camera';
  static const unreachableText = 'Camera not reachable';
  static const userActionText = 'Open Shutterlink to allow USB access';

  final ConnectCubit _connect;
  final NetworkBinder _networkBinder;
  final LiveService _service;
  final UploadQueue _queue;
  final LiveIngestorFactory _ingestorFactory;
  final UsbVendorClaim _claimsUsbVendor;
  final UsbCameraWatcher _usbWatcher;
  late final ConnectionSupervisor _supervisor;
  late final StreamSubscription<void> _stopSubscription;
  final _subscriptions = <StreamSubscription<Object?>>[];
  StreamSubscription<Object?>? _ingestedSubscription;
  StreamSubscription<void>? _bindingLostSubscription;
  bool _watchingUsb = false;
  LiveIngestor? _ingestor;
  LiveBaseline? _baseline;
  int _uploadedBefore = 0;
  int _session = 0;
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
      ..add(_queue.snapshots.listen((_) => _report()))
      ..add(_usbWatcher.attached.listen(_onUsbAttached))
      ..add(_usbWatcher.detached.listen(_supervisor.usbDetached));
    _usbWatcher.start(bindingOwner);
    _watchingUsb = true;
    final client = _connect.handOver(bindingOwner);
    final target = _connect.handedOverTarget;
    if (target is! UsbTarget) {
      _bindingLostSubscription = _networkBinder.bindingLost.listen(
        (_) => _supervisor.bindingLost(),
      );
    }
    await _supervisor.supervise(
      client,
      target,
      bindingOwner: bindingOwner,
      holdNetwork: true,
    );
  }

  /// Ends Live. A connected camera goes back to the gallery.
  Future<void> stop() {
    if (isClosed) return Future.value();
    return _stopping ??= _stop().whenComplete(() => _stopping = null);
  }

  Future<void> _stop() async {
    if (state is LiveIdle) return _guard(_service.stop);
    _session++;
    final client = _supervisor.client;
    final target = _supervisor.target;
    _supervisor.stop();
    await _teardown();
    _emit(const LiveIdle());
    await _guard(_service.stop);
    if (client != null &&
        _connect.takeBack(client, owner: bindingOwner, target: target)) {
      return;
    }
    _connect.takeBack(null, owner: bindingOwner);
    try {
      await client?.close();
    } on Exception {
      // The connection is gone either way; the binding must still go.
    }
    if (target is! UsbTarget) await _release();
  }

  bool _isCurrent(int session) => session == _session && !isClosed;

  Future<bool> _notificationsPermitted() async {
    try {
      return await _service.requestNotificationPermission();
    } on PlatformException {
      return false;
    }
  }

  /// Reads the card's baseline and starts ingesting from [client]. A failed
  /// read makes the supervisor close the client and retry.
  Future<bool> _prepare(CameraClient client) async {
    final known = _baseline;
    final LiveBaseline baseline;
    try {
      baseline = known == null
          ? _baseline = await LiveIngestor.baselineOf(client)
          : LiveBaseline(keys: known.keys);
    } on Exception {
      return false;
    }
    if (_supervisor.client != client) return false;
    unawaited(_ingestor?.close());
    final ingestor = _ingestor = _ingestorFactory(client, baseline);
    await _ingestedSubscription?.cancel();
    _ingestedSubscription = null;
    if (_supervisor.client != client) {
      unawaited(ingestor.close());
      return false;
    }
    _ingestedSubscription = ingestor.ingested.listen((_) {
      _emit(_withIngested(state.ingested + 1));
      _report();
    });
    ingestor.start();
    return true;
  }

  /// A reconnected camera catches up on what was shot meanwhile.
  void _onConnected(
    CameraClient client,
    ConnectTarget? target, {
    required bool reconnected,
  }) {
    _emit(
      LiveTransferring(
        ingested: state.ingested,
        notificationsDenied: state.notificationsDenied,
      ),
    );
    _report();
    if (reconnected) unawaited(_ingestor?.catchUp());
  }

  void _dropIngestor() {
    final ingestor = _ingestor;
    _ingestor = null;
    unawaited(ingestor?.close());
  }

  void _onReconnecting({
    required bool unreachable,
    required bool userActionNeeded,
    required bool usb,
  }) {
    _emit(
      LiveReconnecting(
        ingested: state.ingested,
        notificationsDenied: state.notificationsDenied,
        unreachable: unreachable,
        userActionNeeded: userActionNeeded,
      ),
    );
    _report();
  }

  /// A matching camera back on the cable reconnects at once. A claimed
  /// vendor's camera plugged in while Live runs over Wi-Fi takes over.
  void _onUsbAttached(UsbAttachment attachment) {
    if (state is LiveIdle || isClosed) return;
    final device = attachment.device;
    if (_supervisor.target is UsbTarget) {
      return _supervisor.usbAttached(device);
    }
    if (attachment.enumerated || !_claimsUsbVendor(device.vendorId)) return;
    final client = _supervisor.client;
    _supervisor.stop();
    unawaited(_bindingLostSubscription?.cancel());
    _bindingLostSubscription = null;
    if (client != null) {
      _dropIngestor();
      _onReconnecting(unreachable: false, userActionNeeded: false, usb: true);
      unawaited(client.close());
    }
    unawaited(_release());
    unawaited(
      _supervisor.supervise(
        null,
        UsbTarget(device),
        bindingOwner: bindingOwner,
      ),
    );
  }

  /// Asks for USB access again, from the app in the foreground, where the
  /// system dialog can be answered.
  void allowUsbAccess() {
    if (state is! LiveReconnecting) return;
    _supervisor.allowUsbAccess();
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
    LiveReconnecting(
      :final notificationsDenied,
      :final unreachable,
      :final userActionNeeded,
    ) =>
      LiveReconnecting(
        ingested: ingested,
        notificationsDenied: notificationsDenied,
        unreachable: unreachable,
        userActionNeeded: userActionNeeded,
      ),
  };

  LiveStatus _status() {
    final snapshot = _queue.snapshot;
    final (serviceState, text) = switch (state) {
      LiveIdle() ||
      LiveConnecting() => (LiveServiceState.connecting, connectingText),
      LiveTransferring() => (LiveServiceState.transferring, transferringText),
      LiveReconnecting(userActionNeeded: true) => (
        LiveServiceState.reconnecting,
        userActionText,
      ),
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
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _bindingLostSubscription?.cancel();
    _bindingLostSubscription = null;
    if (_watchingUsb) {
      _watchingUsb = false;
      _usbWatcher.stop(bindingOwner);
    }
    await _ingestedSubscription?.cancel();
    _ingestedSubscription = null;
    final ingestor = _ingestor;
    _ingestor = null;
    await ingestor?.close();
    _baseline = null;
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
    final client = _supervisor.client;
    _supervisor.stop();
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
