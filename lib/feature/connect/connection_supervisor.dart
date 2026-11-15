import 'dart:async';

import 'package:flutter/services.dart';

import '../../data/camera_host_resolver.dart';
import '../../data/identity_repository.dart';
import '../../data/network_binder.dart';
import '../../data/upload_worker.dart';
import '../../ptpip/camera_client.dart';
import '../../usb/usb_camera_platform.dart';
import 'connect_cubit.dart';

/// Decides whether a freshly reached client may be used; the supervisor
/// closes a rejected client that is still its own and tries again.
typedef ClientValidator = Future<bool> Function(CameraClient client);

/// [reconnected] is false only for the client handed to `supervise`.
typedef ConnectedCallback = void Function(
  CameraClient client,
  ConnectTarget? target, {
  required bool reconnected,
});

typedef ReconnectingCallback = void Function({
  required bool unreachable,
  required bool userActionNeeded,
  required bool usb,
});

/// Keeps a camera connection alive over Wi-Fi or USB: it notices drops,
/// retries with a backoff that depends on the transport, and reports each
/// new client. It never subscribes to USB or binding events; its owner
/// forwards them, and owns whatever it builds on a client.
class ConnectionSupervisor {
  ConnectionSupervisor({
    required this._connector,
    required this._identity,
    required this._hostResolver,
    required this._networkBinder,
    required this._onConnected,
    required this._onDisconnected,
    required this._onReconnecting,
    required this._releaseStale,
    ClientValidator? validate,
    this._usbWatcher = const NoUsbCameraWatcher(),
    DateTime Function()? clock,
    TimerFactory? timerFactory,
  }) : _validate = validate ?? _accept,
       _clock = clock ?? DateTime.now,
       _timerFactory = timerFactory ?? Timer.new;

  static const initialReconnectDelay = Duration(seconds: 2);
  static const reconnectDelayFactor = 2;
  static const maxReconnectDelay = Duration(seconds: 30);
  static const unreachableReconnectDelay = Duration(seconds: 60);

  /// Failing this long counts as the camera being gone.
  static const unreachableAfter = Duration(minutes: 10);

  final CameraConnector _connector;
  final IdentityRepository _identity;
  final CameraHostResolver _hostResolver;
  final NetworkBinder _networkBinder;
  final ConnectedCallback _onConnected;

  /// The current client was lost; the owner drops what it built on it.
  final void Function(CameraClient client) _onDisconnected;
  final ReconnectingCallback _onReconnecting;

  /// A binding acquired for a session that [stop] ended; the owner releases
  /// it once it no longer needs the binding owner's name.
  final Future<void> Function() _releaseStale;
  final ClientValidator _validate;
  final UsbCameraWatcher _usbWatcher;
  final DateTime Function() _clock;
  final TimerFactory _timerFactory;

  bool _running = false;
  int _session = 0;
  String _bindingOwner = '';
  bool _holdNetwork = false;

  /// How the camera is reached; null counts as Wi-Fi.
  ConnectTarget? _target;
  CameraClient? _client;

  /// Whether the USB target is on the cable; a gone camera needs no access.
  bool _usbPresent = true;
  bool _userActionNeeded = false;
  bool _permissionRequested = false;
  String? _cameraHost;
  Timer? _retryTimer;
  Duration _reconnectDelay = initialReconnectDelay;
  DateTime? _failingSince;
  bool _unreachable = false;
  int? _reconnecting;

  static Future<bool> _accept(CameraClient client) async => true;

  CameraClient? get client => _client;

  ConnectTarget? get target => _target;

  /// Keeps [client], or a camera reached through [target] when [client] is
  /// null, connected until [stop]. A Wi-Fi target binds as [bindingOwner].
  /// Completes after the first attach or connection attempt.
  Future<void> supervise(
    CameraClient? client,
    ConnectTarget? target, {
    required String bindingOwner,
    bool holdNetwork = false,
  }) async {
    _reset();
    final session = ++_session;
    _running = true;
    _target = target;
    _bindingOwner = bindingOwner;
    _holdNetwork = holdNetwork;
    if (client == null) return _tryReconnect(session);
    _client = client;
    if (target is UsbTarget) {
      if (!await _attach(client, reconnected: false)) {
        _scheduleReconnect(session);
      }
      return;
    }
    String? gateway;
    try {
      gateway = await _networkBinder.acquireBinding(
        bindingOwner,
        holdNetwork: holdNetwork,
      );
    } on PlatformException {
      gateway = null;
    }
    if (!_isCurrent(session)) return _staleBinding(bindingOwner);
    _cameraHost = await _hostResolver.resolve(boundGateway: gateway);
    if (!_isCurrent(session)) return;
    if (!await _attach(client, reconnected: false)) {
      _scheduleReconnect(session);
    }
  }

  /// Stops retrying. The current client stays open and is forgotten; a
  /// retry still running closes its own late client and reports nothing.
  void stop() {
    _session++;
    _running = false;
    _reset();
  }

  /// A camera on the cable again: the supervised one retries at once.
  void usbAttached(UsbCameraRef device) {
    final target = _target;
    if (!_running || target is! UsbTarget || device != target.device) return;
    _target = UsbTarget(device);
    _usbPresent = true;
    _permissionRequested = false;
    if (_client == null) _retryNow();
  }

  void usbDetached(UsbCameraRef device) {
    final target = _target;
    if (target is UsbTarget && target.device == device) {
      _usbPresent = false;
      _userActionNeeded = false;
    }
  }

  /// Asks for USB access again, from the app in the foreground, where the
  /// system dialog can be answered.
  void allowUsbAccess() {
    if (!_running || _target is! UsbTarget) return;
    _permissionRequested = false;
    _retryNow();
  }

  /// The held Wi-Fi was lost, which a USB camera does not care about.
  void bindingLost() {
    final client = _client;
    if (client == null || _target is UsbTarget) return;
    _disconnected(client);
    unawaited(client.close());
  }

  bool _isCurrent(int session) => _running && session == _session;

  void _reset() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _client = null;
    _target = null;
    _usbPresent = true;
    _userActionNeeded = false;
    _permissionRequested = false;
    _cameraHost = null;
    _reconnectDelay = initialReconnectDelay;
    _failingSince = null;
    _unreachable = false;
  }

  /// The supervisor owns [client] until a disconnect or [stop] takes it.
  Future<bool> _attach(CameraClient client, {required bool reconnected}) async {
    final previous = _client;
    _client = client;
    if (previous != null && previous != client) unawaited(previous.close());
    if (!await _validate(client)) {
      if (_client != client) return false;
      _client = null;
      await client.close();
      return false;
    }
    if (_client != client) return false;
    unawaited(client.disconnected.then((_) => _disconnected(client)));
    _reconnectDelay = initialReconnectDelay;
    _failingSince = null;
    _unreachable = false;
    _userActionNeeded = false;
    _onConnected(client, _target, reconnected: reconnected);
    return true;
  }

  void _retryNow() {
    _reconnectDelay = initialReconnectDelay;
    _failingSince = null;
    _unreachable = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    unawaited(_tryReconnect(_session));
  }

  void _disconnected(CameraClient client) {
    if (client != _client) return;
    _client = null;
    _onDisconnected(client);
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
    _emitReconnecting();
    _retryTimer = _timerFactory(
      _nextDelay(),
      () => unawaited(_tryReconnect(session)),
    );
  }

  void _emitReconnecting() => _onReconnecting(
    unreachable: _unreachable,
    userActionNeeded: _userActionNeeded,
    usb: _target is UsbTarget,
  );

  Duration _nextDelay() {
    // Waiting for the user to allow USB access: look again soon.
    if (_userActionNeeded) return initialReconnectDelay;
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
    final target = _target;
    if (target is UsbTarget) return _reconnectUsb(session, target.device);
    final owner = _bindingOwner;
    String? host;
    try {
      final gateway = await _networkBinder.acquireBinding(
        owner,
        holdNetwork: _holdNetwork,
      );
      if (!_isCurrent(session)) {
        await _staleBinding(owner);
        return false;
      }
      host = await _hostResolver.resolve(boundGateway: gateway);
      final client = await _connector(
        WifiTarget(host, await _identity.identity()),
      );
      if (!_isCurrent(session)) {
        await client.close();
        return false;
      }
      _cameraHost ??= host;
      if (await _attach(client, reconnected: true)) return true;
    } on Exception {
      if (!_isCurrent(session)) return false;
    }
    final cameraHost = _cameraHost;
    if (host != null && cameraHost != null && host != cameraHost) {
      _unreachable = true;
    }
    return false;
  }

  /// A binding acquired for an ended session: a session now running over
  /// Wi-Fi under the same owner keeps it, a USB one has no use for it, and
  /// after [stop] the owner decides.
  Future<void> _staleBinding(String owner) async {
    if (!_running) return _releaseStale();
    if (_target is! UsbTarget && owner == _bindingOwner) return;
    try {
      await _networkBinder.releaseBinding(owner);
    } on PlatformException {
      return;
    }
  }

  /// Asks for USB access once per plug-in; until it is granted, reports
  /// that the user must act and keeps looking.
  Future<bool> _reconnectUsb(int session, UsbCameraRef device) async {
    if (!_usbPresent) return false;
    try {
      if (!_usbWatcher.hasPermission(device)) {
        _userActionNeeded = true;
        _emitReconnecting();
        if (_permissionRequested) return false;
        _permissionRequested = true;
        final permission = await _usbWatcher.requestPermission(device);
        if (!_isCurrent(session) || permission != UsbPermission.granted) {
          return false;
        }
      }
      _userActionNeeded = false;
      final client = await _connector(UsbTarget(device));
      if (!_isCurrent(session)) {
        await client.close();
        return false;
      }
      return await _attach(client, reconnected: true);
    } on Exception {
      return false;
    }
  }
}
