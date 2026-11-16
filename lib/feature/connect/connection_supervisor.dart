import 'dart:async';

import 'package:flutter/services.dart';

import '../../data/camera_host_resolver.dart';
import '../../data/download_history.dart';
import '../../data/identity_repository.dart';
import '../../data/network_binder.dart';
import '../../data/ssdp_discovery.dart';
import '../../data/upload_worker.dart';
import '../../ptpip/camera_client.dart';
import '../../usb/usb_camera_platform.dart';
import 'connect_cubit.dart';

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
    required this._onReconnecting,
    required this._releaseStale,
    this._usbWatcher = const NoUsbCameraWatcher(),
    this._discovery,
    DateTime Function()? clock,
    TimerFactory? timerFactory,
  }) : _clock = clock ?? DateTime.now,
       _timerFactory = timerFactory ?? Timer.new;

  static const initialReconnectDelay = Duration(seconds: 2);
  static const reconnectDelayFactor = 2;
  static const maxReconnectDelay = Duration(seconds: 30);
  static const unreachableReconnectDelay = Duration(seconds: 60);

  /// Failing this long counts as the camera being gone.
  static const unreachableAfter = Duration(minutes: 10);

  /// Failed Wi-Fi retries before a camera found by discovery is looked for
  /// at a new address.
  static const rediscoverAfter = 3;

  final CameraConnector _connector;
  final IdentityRepository _identity;
  final CameraHostResolver _hostResolver;
  final NetworkBinder _networkBinder;
  final ConnectedCallback _onConnected;
  final ReconnectingCallback _onReconnecting;

  /// A binding acquired for a session that [stop] ended; the owner releases
  /// it once it no longer needs the binding owner's name.
  final Future<void> Function() _releaseStale;
  final UsbCameraWatcher _usbWatcher;
  final CameraDiscovery? _discovery;
  final DateTime Function() _clock;
  final TimerFactory _timerFactory;

  bool _running = false;
  int _session = 0;
  String _bindingOwner = '';
  bool _holdNetwork = false;

  /// The Wi-Fi gateway when supervision began; another one means the phone
  /// joined a different network.
  String? _gateway;

  /// The name discovery found the camera under; null when it was reached
  /// by its gateway or a set address, which are never looked for again.
  String? _discoveredName;

  /// The camera's identity, which a camera found again must match.
  String? _cameraKey;
  int _failedRetries = 0;

  /// How the camera is reached; null counts as Wi-Fi.
  ConnectTarget? _target;
  CameraClient? _client;

  /// Whether the USB target is on the cable; a gone camera needs no access.
  bool _usbPresent = true;
  bool _userActionNeeded = false;
  bool _permissionRequested = false;
  Timer? _retryTimer;
  Duration _reconnectDelay = initialReconnectDelay;
  DateTime? _failingSince;
  bool _unreachable = false;
  int? _reconnecting;

  CameraClient? get client => _client;

  ConnectTarget? get target => _target;

  /// Whether Wi-Fi retries keep the Wi-Fi up while the screen is off.
  set holdNetwork(bool hold) => _holdNetwork = hold;

  /// Keeps [client], or a camera reached through [target] when [client] is
  /// null, connected until [stop]. A Wi-Fi target binds as [bindingOwner],
  /// unless [gateway] says the owner is bound already and to which network.
  /// A Wi-Fi camera [discoveredName] names is looked for again when it
  /// stays away. Completes after the first attach or connection attempt.
  Future<void> supervise(
    CameraClient? client,
    ConnectTarget? target, {
    required String bindingOwner,
    bool holdNetwork = false,
    String? gateway,
    String? discoveredName,
  }) async {
    _reset();
    final session = ++_session;
    _running = true;
    _target = target;
    _bindingOwner = bindingOwner;
    _holdNetwork = holdNetwork;
    _gateway = gateway;
    _discoveredName = target is WifiTarget ? discoveredName : null;
    if (client == null) return _tryReconnect(session);
    _client = client;
    if (!target.usesCameraWifi || gateway != null) {
      _attach(client, reconnected: false);
      return;
    }
    String? bound;
    try {
      bound = await _networkBinder.acquireBinding(
        bindingOwner,
        holdNetwork: holdNetwork,
      );
    } on PlatformException {
      bound = null;
    }
    if (!_isCurrent(session)) return _staleBinding(bindingOwner);
    final resolved = await _gatewayOf(bound);
    if (!_isCurrent(session)) return;
    _gateway ??= resolved;
    _attach(client, reconnected: false);
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

  /// The held Wi-Fi was lost, which only a camera on Wi-Fi cares about.
  void bindingLost() {
    final client = _client;
    if (client == null || !_target.usesCameraWifi) return;
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
    _gateway = null;
    _discoveredName = null;
    _cameraKey = null;
    _failedRetries = 0;
    _reconnectDelay = initialReconnectDelay;
    _failingSince = null;
    _unreachable = false;
  }

  /// The supervisor owns [client] until a disconnect or [stop] takes it.
  void _attach(CameraClient client, {required bool reconnected}) {
    final previous = _client;
    _client = client;
    if (previous != null && previous != client) unawaited(previous.close());
    unawaited(client.disconnected.then((_) => _disconnected(client)));
    _cameraKey ??= cameraKeyOf(client.deviceInfo);
    _failedRetries = 0;
    _reconnectDelay = initialReconnectDelay;
    _failingSince = null;
    _unreachable = false;
    _userActionNeeded = false;
    _onConnected(client, _target, reconnected: reconnected);
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

  /// Retries the Wi-Fi camera where it was reached; without a target, at
  /// the resolved host.
  Future<bool> _reconnect(int session) async {
    final target = _target;
    if (target is UsbTarget) return _reconnectUsb(session, target.device);
    final owner = _bindingOwner;
    String? gateway;
    try {
      final bound = await _networkBinder.acquireBinding(
        owner,
        holdNetwork: _holdNetwork,
      );
      if (!_isCurrent(session)) {
        await _staleBinding(owner);
        return false;
      }
      gateway = await _gatewayOf(bound);
      final host = target is WifiTarget
          ? target.host
          : await _hostResolver.resolve(boundGateway: bound);
      final client = await _connector(
        WifiTarget(host, await _identity.identity()),
      );
      if (!_isCurrent(session)) {
        await client.close();
        return false;
      }
      _gateway ??= gateway;
      _attach(client, reconnected: true);
      return true;
    } on Exception {
      if (!_isCurrent(session)) return false;
    }
    if (++_failedRetries >= rediscoverAfter && _discoveredName != null) {
      _failedRetries = 0;
      if (await _rediscover(session)) return true;
      if (!_isCurrent(session)) return false;
    }
    final known = _gateway;
    if (gateway != null && known != null && gateway != known) {
      _unreachable = true;
    }
    return false;
  }

  /// Looks for the camera under its discovered name at another address,
  /// and keeps it there if it is the same camera.
  Future<bool> _rediscover(int session) async {
    final discovery = _discovery;
    final target = _target;
    final name = _discoveredName;
    final key = _cameraKey;
    if (discovery == null ||
        target is! WifiTarget ||
        name == null ||
        key == null) {
      return false;
    }
    List<DiscoveredCamera> cameras;
    try {
      await _networkBinder.acquireMulticastLock();
      cameras = await discovery();
    } on Exception {
      cameras = const [];
    } finally {
      try {
        await _networkBinder.releaseMulticastLock();
      } on PlatformException {
        // The lock goes with the process anyway.
      }
    }
    for (final camera in cameras) {
      if (camera.name != name || camera.host == target.host) continue;
      if (!_isCurrent(session)) return false;
      final moved = WifiTarget(camera.host, target.identity);
      final CameraClient client;
      try {
        client = await _connector(moved);
      } on Exception {
        continue;
      }
      if (!_isCurrent(session) || cameraKeyOf(client.deviceInfo) != key) {
        await client.close();
        if (!_isCurrent(session)) return false;
        continue;
      }
      _target = moved;
      _attach(client, reconnected: true);
      return true;
    }
    return false;
  }

  /// The gateway of the bound Wi-Fi, or null when it cannot be looked up.
  Future<String?> _gatewayOf(String? bound) async {
    try {
      return await _hostResolver.gateway(boundGateway: bound);
    } on PlatformException {
      return null;
    }
  }

  /// A binding acquired for an ended session: a session now running over
  /// Wi-Fi under the same owner keeps it, a USB one has no use for it, and
  /// after [stop] the owner decides.
  Future<void> _staleBinding(String owner) async {
    if (!_running) return _releaseStale();
    if (_target.usesCameraWifi && owner == _bindingOwner) return;
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
      _attach(client, reconnected: true);
      return true;
    } on Exception {
      return false;
    }
  }
}
