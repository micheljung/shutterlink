import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/camera_host_resolver.dart';
import '../../data/identity_repository.dart';
import '../../data/network_binder.dart';
import '../../data/ssdp_discovery.dart';
import '../../ptpip/camera_client.dart';
import 'connect_state.dart';

typedef CameraConnector = Future<CameraClient> Function(
  String host,
  CameraIdentity identity,
);

typedef CameraDiscovery = Future<List<DiscoveredCamera>> Function();

class ConnectCubit extends Cubit<ConnectState> {
  ConnectCubit({
    required this._connector,
    required this._identity,
    required this._hostResolver,
    required this._networkBinder,
    CameraDiscovery? discovery,
  }) : _discovery = discovery ?? const SsdpDiscovery().discover,
       super(const ConnectIdle());

  static const bindingOwner = 'connect';
  static const noWifiCode = 'no_wifi';
  static const noWifiMessage =
      "Not connected to Wi-Fi. Join the camera's Wi-Fi network first.";
  static const disconnectedMessage = 'The camera disconnected.';
  static const busyMessage =
      'The camera is busy with another connection. Close it and try again.';

  final CameraConnector _connector;
  final IdentityRepository _identity;
  final CameraHostResolver _hostResolver;
  final NetworkBinder _networkBinder;
  final CameraDiscovery _discovery;
  CameraClient? _handedOver;

  Future<void> connect() async {
    if (state is ConnectConnecting || state is ConnectConnected) return;
    emit(const ConnectConnecting());
    final String? override;
    final String gateway;
    try {
      final boundGateway = await _networkBinder.acquireBinding(bindingOwner);
      override = _hostResolver.override;
      gateway = await _hostResolver.gateway(boundGateway: boundGateway);
    } on PlatformException catch (error) {
      _emitPlatformFailure(error);
      return;
    }
    if (override != null) return _connectTo(override);
    await _connectTo(
      gateway,
      onUnreachable: (error) => _discoverAfter(gateway, error),
    );
  }

  Future<void> chooseCamera(DiscoveredCamera camera) async {
    if (state is! ConnectChooseCamera) return;
    emit(ConnectConnecting(cameraName: camera.name));
    await _connectTo(camera.host);
  }

  Future<void> cancelChoice() async {
    if (state is! ConnectChooseCamera) return;
    await _unbind();
    emit(const ConnectIdle());
  }

  Future<void> _connectTo(
    String host, {
    Future<void> Function(Exception error)? onUnreachable,
  }) async {
    try {
      final client = await _connector(host, await _identity.identity());
      if (isClosed) {
        await client.close();
        return;
      }
      emit(ConnectConnected(client));
      unawaited(_watchDisconnect(client));
    } on PairingRequiredException {
      await _unbind();
      emit(const ConnectPairingRequired());
    } on CameraBusyException {
      await _unbind();
      emit(const ConnectFailed(busyMessage));
    } on PlatformException catch (error) {
      _emitPlatformFailure(error);
    } on Exception catch (error) {
      if (onUnreachable != null &&
          error is CameraDisconnectedException &&
          error.cause is SocketException) {
        return onUnreachable(error);
      }
      await _failUnreachable(host, error);
    }
  }

  Future<void> _discoverAfter(String gateway, Exception error) async {
    var cameras = const <DiscoveredCamera>[];
    try {
      await _networkBinder.acquireMulticastLock();
      cameras = await _discovery();
    } on Exception {
      cameras = const [];
    } finally {
      await _releaseMulticastLock();
    }
    if (isClosed) return;
    switch (cameras) {
      case []:
        await _failUnreachable(gateway, error);
      case [final camera]:
        emit(ConnectConnecting(cameraName: camera.name));
        await _connectTo(camera.host);
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
    await _unbind();
  }

  /// Gives the connected client and the Wi-Fi binding to [owner]. Returns
  /// null when no camera is connected.
  CameraClient? handOver(String owner) {
    final current = state;
    if (current is! ConnectConnected) return null;
    _networkBinder.transferBinding(bindingOwner, owner);
    _handedOver = current.client;
    emit(const ConnectLiveOwned());
    return current.client;
  }

  /// Takes back a live [client] and [owner]'s binding; without a client the
  /// owner releases its binding itself. Returns whether [client] was taken.
  bool takeBack(CameraClient? client, {required String owner}) {
    if (isClosed || state is! ConnectLiveOwned) return false;
    final handedOver = _handedOver;
    _handedOver = null;
    if (client == null) {
      emit(const ConnectIdle());
      return false;
    }
    _networkBinder.transferBinding(owner, bindingOwner);
    emit(ConnectConnected(client));
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
    await _unbind();
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
    await super.close();
    if (current is ConnectConnected) await current.client.close();
  }
}
