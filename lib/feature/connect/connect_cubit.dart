import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/camera_host_resolver.dart';
import '../../data/identity_repository.dart';
import '../../data/network_binder.dart';
import '../../data/ssdp_discovery.dart';
import '../../data/upload_worker.dart';
import '../../ptpip/camera_client.dart';
import '../../usb/usb_camera_platform.dart';
import 'connect_state.dart';
import 'connect_target.dart';
import 'connection_supervisor.dart';

export 'connect_target.dart';

typedef CameraConnector = Future<CameraClient> Function(ConnectTarget target);

typedef CameraDiscovery = Future<List<DiscoveredCamera>> Function();

/// Whether a registered camera profile claims this USB vendor, so its cable
/// may take over another connection.
typedef UsbVendorClaim = bool Function(int vendorId);

class ConnectCubit extends Cubit<ConnectState> {
  ConnectCubit({
    required this._connector,
    required this._identity,
    required this._hostResolver,
    required this._networkBinder,
    required this._claimsUsbVendor,
    this._usbWatcher = const NoUsbCameraWatcher(),
    CameraDiscovery? discovery,
    DateTime Function()? clock,
    TimerFactory? timerFactory,
  }) : _discovery = discovery ?? const SsdpDiscovery().discover,
       super(const ConnectIdle()) {
    _supervisor = ConnectionSupervisor(
      connector: _connector,
      identity: _identity,
      hostResolver: _hostResolver,
      networkBinder: _networkBinder,
      usbWatcher: _usbWatcher,
      onConnected: _onReconnected,
      onDisconnected: (_) {},
      onReconnecting: _onReconnecting,
      releaseStale: _releaseUnused,
      clock: clock,
      timerFactory: timerFactory,
    );
    _attachments = _usbWatcher.attached.listen(_onAttached);
    _detachments = _usbWatcher.detached.listen(_supervisor.usbDetached);
    _usbWatcher.start(usbWatchOwner);
  }

  static const bindingOwner = 'connect';

  /// Owner of the USB watch for the cubit's life, so a re-plug or a cable
  /// takeover is seen on every screen. It differs from the connect screen's
  /// owner, because owners with the same name count once.
  static const usbWatchOwner = 'connection';
  static const noWifiCode = 'no_wifi';
  static const noWifiMessage =
      "Not connected to Wi-Fi. Join the camera's Wi-Fi network first.";
  static const busyMessage =
      'The camera is busy with another connection. Close it and try again.';
  static const usbPermissionDeniedMessage =
      'USB access to the camera was denied.';
  static const usbPermissionNeededMessage =
      'Open Shutterlink and allow USB access to the camera.';

  final CameraConnector _connector;
  final IdentityRepository _identity;
  final CameraHostResolver _hostResolver;
  final NetworkBinder _networkBinder;
  final UsbVendorClaim _claimsUsbVendor;
  final UsbCameraWatcher _usbWatcher;
  final CameraDiscovery _discovery;
  late final ConnectionSupervisor _supervisor;
  late final StreamSubscription<UsbAttachment> _attachments;
  late final StreamSubscription<UsbCameraRef> _detachments;
  StreamSubscription<void>? _bindingLost;
  ConnectTarget? _handedOverTarget;

  /// The gateway of the Wi-Fi the last Wi-Fi connect bound to.
  String? _gateway;
  bool _holdNetwork = false;
  bool _watchingUsb = true;

  /// Bumped by every user action, after the supervisor stopped, so the last
  /// one wins and a late client from an earlier one is closed.
  int _attempt = 0;
  bool _usbAttempt = false;

  UsbCameraWatcher get usbWatcher => _usbWatcher;

  /// How the client last handed over was reached.
  ConnectTarget? get handedOverTarget => _handedOverTarget;

  bool _isCurrent(int attempt) => attempt == _attempt && !isClosed;

  /// Connects over Wi-Fi; a USB attempt or connection gives way.
  Future<void> connect() async {
    final previous = state;
    if (previous is ConnectConnecting && !previous.usb) return;
    if (previous is ConnectConnected && previous.target is! UsbTarget) return;
    _supervisor.stop();
    final attempt = ++_attempt;
    _usbAttempt = false;
    emit(const ConnectConnecting());
    if (previous is ConnectConnected) await previous.client.close();
    final String? boundGateway;
    try {
      boundGateway = await _networkBinder.acquireBinding(bindingOwner);
    } on PlatformException catch (error) {
      if (!_isCurrent(attempt)) return;
      _emitPlatformFailure(error);
      return;
    }
    if (!_isCurrent(attempt)) return _releaseStale();
    final String? override;
    final String gateway;
    try {
      override = _hostResolver.override;
      gateway = await _hostResolver.gateway(boundGateway: boundGateway);
    } on PlatformException catch (error) {
      if (!_isCurrent(attempt)) return _releaseStale();
      await _unbind();
      _emitPlatformFailure(error);
      return;
    }
    if (!_isCurrent(attempt)) return _releaseStale();
    _gateway = gateway;
    if (override != null) return _connectTo(attempt, override);
    await _connectTo(
      attempt,
      gateway,
      onUnreachable: (error) => _discoverAfter(attempt, gateway, error),
    );
  }

  /// Connects to [device] on the USB cable; Wi-Fi gives way.
  Future<void> connectUsb(UsbCameraRef device) async {
    final previous = state;
    _supervisor.stop();
    final attempt = ++_attempt;
    _usbAttempt = true;
    emit(ConnectConnecting(cameraName: device.name, usb: true));
    switch (previous) {
      case ConnectConnected(:final client, :final target):
        await client.close();
        // A Wi-Fi tap during the close holds the binding by now.
        if (target is! UsbTarget) await _releaseStale();
      case ConnectConnecting(usb: false) || ConnectChooseCamera():
        await _unbind();
      default:
    }
    if (!_isCurrent(attempt)) return;
    if (!_usbWatcher.hasPermission(device)) {
      final permission = await _usbWatcher.requestPermission(device);
      if (!_isCurrent(attempt)) return;
      switch (permission) {
        case UsbPermission.granted:
          break;
        case UsbPermission.denied:
          return emit(const ConnectFailed(usbPermissionDeniedMessage));
        case UsbPermission.userActionNeeded:
          return emit(const ConnectFailed(usbPermissionNeededMessage));
      }
    }
    final target = UsbTarget(device);
    final CameraClient client;
    try {
      client = await _connector(target);
    } on Exception catch (error) {
      if (_isCurrent(attempt)) {
        emit(ConnectFailed('Could not open the USB camera ($error).'));
      }
      return;
    }
    if (!_isCurrent(attempt)) {
      await client.close();
      return;
    }
    _connected(client, target);
  }

  void _connected(CameraClient client, ConnectTarget target) {
    emit(ConnectConnected(client, target: target));
    _supervise(client, target);
  }

  /// Keeps [client] connected, retrying [target] after a drop.
  void _supervise(CameraClient client, ConnectTarget? target) => unawaited(
    _supervisor.supervise(
      client,
      target,
      bindingOwner: bindingOwner,
      holdNetwork: _holdNetwork,
      gateway: target is UsbTarget ? null : _gateway,
    ),
  );

  void _onAttached(UsbAttachment attachment) {
    final device = attachment.device;
    final takesOver =
        !attachment.enumerated && _claimsUsbVendor(device.vendorId);
    switch (state) {
      case ConnectIdle() || ConnectFailed() || ConnectPairingRequired():
        unawaited(connectUsb(device));
      case ConnectConnecting(usb: false) || ConnectChooseCamera():
        if (takesOver) unawaited(connectUsb(device));
      case ConnectConnected() || ConnectReconnecting():
        if (_supervisor.target is UsbTarget) {
          _supervisor.usbAttached(device);
        } else if (takesOver) {
          unawaited(_takeOver(device));
        }
      case ConnectConnecting() || ConnectLiveOwned():
    }
  }

  /// Swaps a Wi-Fi camera for the one on the cable, without leaving the
  /// connected screens.
  Future<void> _takeOver(UsbCameraRef device) async {
    final current = state;
    final client = current is ConnectConnected
        ? current.client
        : _supervisor.client;
    _supervisor.stop();
    final attempt = ++_attempt;
    _usbAttempt = true;
    emit(const ConnectReconnecting(usb: true));
    unawaited(client?.close());
    await _unbind();
    if (!_isCurrent(attempt)) return;
    await _supervisor.supervise(
      null,
      UsbTarget(device),
      bindingOwner: bindingOwner,
    );
  }

  /// A supervised camera came back, maybe over another transport.
  void _onReconnected(
    CameraClient client,
    ConnectTarget? target, {
    required bool reconnected,
  }) {
    if (reconnected && !isClosed) {
      emit(ConnectConnected(client, target: target));
    }
  }

  void _onReconnecting({
    required bool unreachable,
    required bool userActionNeeded,
    required bool usb,
  }) {
    if (isClosed) return;
    emit(
      ConnectReconnecting(
        unreachable: unreachable,
        userActionNeeded: userActionNeeded,
        usb: usb,
      ),
    );
  }

  /// Asks for USB access again, from the app in the foreground, where the
  /// system dialog can be answered.
  void allowUsbAccess() {
    if (state is ConnectReconnecting) _supervisor.allowUsbAccess();
  }

  /// Gives up reconnecting and returns to the connect screen. The USB watch
  /// stays.
  Future<void> abortReconnect() async {
    if (state is! ConnectReconnecting) return;
    final usb = _supervisor.target is UsbTarget;
    _supervisor.stop();
    _attempt++;
    emit(const ConnectIdle());
    if (!usb) await _unbind();
  }

  /// Keeps the Wi-Fi up while the screen is off or mobile data is in use,
  /// for a mode that runs in the background. Clearing it keeps the native
  /// hold until the binding ends; a USB camera needs no hold.
  Future<void> setHoldNetwork(bool hold) async {
    _holdNetwork = hold;
    _supervisor.holdNetwork = hold;
    if (!hold) return;
    _bindingLost ??= _networkBinder.bindingLost.listen(
      (_) => _supervisor.bindingLost(),
    );
    final current = state;
    if (current is! ConnectConnected || current.target is UsbTarget) return;
    try {
      await _networkBinder.acquireBinding(bindingOwner, holdNetwork: true);
    } on PlatformException {
      return;
    }
  }

  /// In the background without a camera, the cable needs no watching.
  void appPaused() {
    final idle = switch (state) {
      ConnectIdle() || ConnectFailed() || ConnectPairingRequired() => true,
      _ => false,
    };
    if (!idle || !_watchingUsb || isClosed) return;
    _watchingUsb = false;
    _usbWatcher.stop(usbWatchOwner);
  }

  void appResumed() {
    if (_watchingUsb || isClosed) return;
    _watchingUsb = true;
    _usbWatcher.start(usbWatchOwner);
  }

  Future<void> chooseCamera(DiscoveredCamera camera) async {
    if (state is! ConnectChooseCamera) return;
    _supervisor.stop();
    emit(ConnectConnecting(cameraName: camera.name));
    await _connectTo(_attempt, camera.host);
  }

  Future<void> cancelChoice() async {
    if (state is! ConnectChooseCamera) return;
    await _unbind();
    emit(const ConnectIdle());
  }

  Future<void> _connectTo(
    int attempt,
    String host, {
    Future<void> Function(Exception error)? onUnreachable,
  }) async {
    try {
      final target = WifiTarget(host, await _identity.identity());
      final client = await _connector(target);
      if (!_isCurrent(attempt)) {
        await client.close();
        await _releaseStale();
        return;
      }
      _connected(client, target);
    } on Exception catch (error) {
      if (!_isCurrent(attempt)) return _releaseStale();
      switch (error) {
        case PairingRequiredException():
          await _unbind();
          emit(const ConnectPairingRequired());
        case CameraBusyException():
          await _unbind();
          emit(const ConnectFailed(busyMessage));
        case PlatformException():
          await _unbind();
          _emitPlatformFailure(error);
        case CameraDisconnectedException(cause: SocketException())
            when onUnreachable != null:
          return onUnreachable(error);
        default:
          await _failUnreachable(host, error);
      }
    }
  }

  /// Drops the Wi-Fi binding of an attempt that lost, unless a newer Wi-Fi
  /// attempt holds it now.
  Future<void> _releaseStale() async {
    if (isClosed || _usbAttempt) await _unbind();
  }

  /// Drops a binding a stopped retry acquired, unless a Wi-Fi connection or
  /// attempt holds it now.
  Future<void> _releaseUnused() async {
    final inUse = switch (state) {
      ConnectConnecting(usb: false) || ConnectChooseCamera() => true,
      ConnectConnected(:final target) => target is! UsbTarget,
      ConnectReconnecting(:final usb) => !usb,
      _ => false,
    };
    if (isClosed || !inUse) await _unbind();
  }

  Future<void> _discoverAfter(
    int attempt,
    String gateway,
    Exception error,
  ) async {
    var cameras = const <DiscoveredCamera>[];
    try {
      await _networkBinder.acquireMulticastLock();
      cameras = await _discovery();
    } on Exception {
      cameras = const [];
    } finally {
      await _releaseMulticastLock();
    }
    if (!_isCurrent(attempt)) return _releaseStale();
    switch (cameras) {
      case []:
        await _failUnreachable(gateway, error);
      case [final camera]:
        emit(ConnectConnecting(cameraName: camera.name));
        await _connectTo(attempt, camera.host);
      default:
        emit(ConnectChooseCamera(cameras));
    }
  }

  Future<void> _failUnreachable(String host, Exception error) async {
    await _unbind();
    emit(ConnectFailed('Could not reach the camera at $host ($error).'));
  }

  void _emitPlatformFailure(PlatformException error) => emit(
    ConnectFailed(
      error.code == noWifiCode ? noWifiMessage : '${error.message}',
    ),
  );

  Future<void> disconnect() async {
    final current = state;
    if (current is! ConnectConnected) return;
    _supervisor.stop();
    _attempt++;
    emit(const ConnectIdle());
    await current.client.close();
    if (current.target is! UsbTarget) await _unbind();
  }

  /// Gives the connected client and the Wi-Fi binding to [owner]. Returns
  /// null when no camera is connected; [handedOverTarget] says how it was
  /// reached.
  CameraClient? handOver(String owner) {
    final current = state;
    if (current is! ConnectConnected) return null;
    _supervisor.stop();
    final target = _handedOverTarget = current.target;
    if (target is! UsbTarget) {
      _networkBinder.transferBinding(bindingOwner, owner);
    }
    emit(const ConnectLiveOwned());
    return current.client;
  }

  /// Takes back a live [client], reached through [target], and [owner]'s
  /// Wi-Fi binding; without a client the owner releases its binding itself.
  /// [client] is supervised as reached through [target], which may differ
  /// from the target handed over. Returns whether [client] was taken.
  bool takeBack(
    CameraClient? client, {
    required String owner,
    ConnectTarget? target,
  }) {
    if (isClosed || state is! ConnectLiveOwned) return false;
    _handedOverTarget = null;
    if (client == null) {
      emit(const ConnectIdle());
      return false;
    }
    if (target is! UsbTarget) {
      _networkBinder.transferBinding(owner, bindingOwner);
    }
    emit(ConnectConnected(client, target: target));
    _supervise(client, target);
    return true;
  }

  Future<void> _unbind() async {
    try {
      await _networkBinder.releaseBinding(bindingOwner);
    } on PlatformException {
      return;
    }
  }

  Future<void> _releaseMulticastLock() async {
    try {
      await _networkBinder.releaseMulticastLock();
    } on PlatformException {
      return;
    }
  }

  @override
  Future<void> close() async {
    _supervisor.stop();
    _attempt++;
    final current = state;
    await _attachments.cancel();
    await _detachments.cancel();
    await _bindingLost?.cancel();
    await super.close();
    if (current is ConnectConnected) await current.client.close();
    if (_watchingUsb) {
      _watchingUsb = false;
      _usbWatcher.stop(usbWatchOwner);
    }
  }
}
