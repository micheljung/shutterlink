import 'package:equatable/equatable.dart';

import '../../ptpip/camera_client.dart';

sealed class ConnectState extends Equatable {
  const ConnectState();

  @override
  List<Object?> get props => [];
}

class ConnectIdle extends ConnectState {
  const ConnectIdle();
}

class ConnectConnecting extends ConnectState {
  const ConnectConnecting();
}

class ConnectConnected extends ConnectState {
  const ConnectConnected(this.client);

  final CameraClient client;

  @override
  List<Object?> get props => [client];
}

class ConnectPairingRequired extends ConnectState {
  const ConnectPairingRequired();
}

class ConnectFailed extends ConnectState {
  const ConnectFailed(this.message);

  final String message;

  @override
  List<Object?> get props => [message];
}
