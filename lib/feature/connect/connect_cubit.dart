import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/camera_host_resolver.dart';
import '../../data/identity_repository.dart';
import '../../data/network_binder.dart';
import '../../ptpip/camera_client.dart';
import 'connect_state.dart';

typedef CameraConnector = Future<CameraClient> Function(
  String host,
  CameraIdentity identity,
);

class ConnectCubit extends Cubit<ConnectState> {
  ConnectCubit({
    required this._connector,
    required this._identity,
    required this._hostResolver,
    required this._networkBinder,
  }) : super(const ConnectIdle());

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

  Future<void> connect() async {
    if (state is ConnectConnecting || state is ConnectConnected) return;
    emit(const ConnectConnecting());
    String? host;
    try {
      final gateway = await _networkBinder.bindToWifi();
      host = await _hostResolver.resolve(boundGateway: gateway);
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
      emit(
        ConnectFailed(
          error.code == noWifiCode ? noWifiMessage : '${error.message}',
        ),
      );
    } on Exception catch (error) {
      await _unbind();
      emit(ConnectFailed('Could not reach the camera at $host ($error).'));
    }
  }

  Future<void> disconnect() async {
    final current = state;
    if (current is! ConnectConnected) return;
    emit(const ConnectIdle());
    await current.client.close();
    await _unbind();
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
      await _networkBinder.unbind();
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
