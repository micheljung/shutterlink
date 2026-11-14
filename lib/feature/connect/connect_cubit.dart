import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/camera_host_resolver.dart';
import '../../data/identity_repository.dart';
import '../../data/network_binder.dart';
import '../../data/ssdp_discovery.dart';
import '../../ptpip/camera_client.dart';
import '../../usb/usb_camera_platform.dart';
import 'connect_state.dart';
import 'connect_target.dart';

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
  }) : _discovery = discovery ?? const SsdpDiscovery().discover,
       super(const ConnectIdle()) {
    _attachments = _usbWatcher.attached.listen(_onAttached);
  }

  static const bindingOwner = 'connect';
  static const noWifiCode = 'no_wifi';
  static const noWifiMessage =
      "Not connected to Wi-Fi. Join the camera's Wi-Fi network first.";
  static const disconnectedMessage = 'The camera disconnected.';
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
  late final StreamSubscription<UsbAttachment> _attachments;
  CameraClient? _handedOver;
  ConnectTarget? _handedOverTarget;

  /// Bumped by every connect, so the last one wins and a late client from
  /// an earlier one is closed.
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
    final attempt = ++_attempt;
    _usbAttempt = true;
    emit(ConnectConnecting(cameraName: device.name, usb: true));
    switch (previous) {
      case ConnectConnected(:final client, :final target):
        await client.close();
        if (target is! UsbTarget) await _unbind();
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
    emit(ConnectConnected(client, target: target));
    unawaited(_watchDisconnect(client));
  }

  void _onAttached(UsbAttachment attachment) {
    final takesOver =
        !attachment.enumerated && _claimsUsbVendor(attachment.device.vendorId);
    final connects = switch (state) {
      ConnectIdle() || ConnectFailed() || ConnectPairingRequired() => true,
      ConnectConnecting(usb: false) || ConnectChooseCamera() => takesOver,
      ConnectConnected(:final target) => target is! UsbTarget && takesOver,
      ConnectConnecting() || ConnectLiveOwned() => false,
    };
    if (connects) unawaited(connectUsb(attachment.device));
  }

  Future<void> chooseCamera(DiscoveredCamera camera) async {
    if (state is! ConnectChooseCamera) return;
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
      emit(ConnectConnected(client, target: target));
      unawaited(_watchDisconnect(client));
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
    final target = _handedOverTarget = current.target;
    if (target is! UsbTarget) {
      _networkBinder.transferBinding(bindingOwner, owner);
    }
    _handedOver = current.client;
    emit(const ConnectLiveOwned());
    return current.client;
  }

  /// Takes back a live [client], reached through [target], and [owner]'s
  /// Wi-Fi binding; without a client the owner releases its binding itself.
  /// Returns whether [client] was taken.
  bool takeBack(
    CameraClient? client, {
    required String owner,
    ConnectTarget? target,
  }) {
    if (isClosed || state is! ConnectLiveOwned) return false;
    final handedOver = _handedOver;
    _handedOver = null;
    _handedOverTarget = null;
    if (client == null) {
      emit(const ConnectIdle());
      return false;
    }
    if (target is! UsbTarget) {
      _networkBinder.transferBinding(owner, bindingOwner);
    }
    emit(ConnectConnected(client, target: target));
    if (client != handedOver) unawaited(_watchDisconnect(client));
    return true;
  }

  Future<void> _watchDisconnect(CameraClient client) async {
    await client.disconnected;
    final current = state;
    if (isClosed || current is! ConnectConnected || current.client != client) {
      return;
    }
    emit(const ConnectFailed(disconnectedMessage));
    if (current.target is! UsbTarget) await _unbind();
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
    final current = state;
    await _attachments.cancel();
    await super.close();
    if (current is ConnectConnected) await current.client.close();
  }
}
