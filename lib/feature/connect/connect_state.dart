import 'package:equatable/equatable.dart';

import '../../data/ssdp_discovery.dart';
import '../../ptpip/camera_client.dart';
import 'connect_target.dart';

sealed class ConnectState extends Equatable {
  const ConnectState();

  @override
  List<Object?> get props => [];
}

class ConnectIdle extends ConnectState {
  const ConnectIdle();
}

class ConnectConnecting extends ConnectState {
  const ConnectConnecting({this.cameraName, this.usb = false});

  final String? cameraName;

  /// Connecting over the USB cable rather than Wi-Fi.
  final bool usb;

  @override
  List<Object?> get props => [cameraName, usb];
}

class ConnectChooseCamera extends ConnectState {
  const ConnectChooseCamera(this.cameras);

  final List<DiscoveredCamera> cameras;

  @override
  List<Object?> get props => [cameras];
}

class ConnectConnected extends ConnectState {
  const ConnectConnected(this.client, {this.target});

  final CameraClient client;

  /// How [client] was reached; equality ignores it.
  final ConnectTarget? target;

  @override
  List<Object?> get props => [client];
}

/// The camera dropped; the connection is being re-established in place.
class ConnectReconnecting extends ConnectState {
  const ConnectReconnecting({
    this.unreachable = false,
    this.userActionNeeded = false,
    this.usb = false,
  });

  /// Retries have slowed down because the camera stayed away.
  final bool unreachable;

  /// The USB camera is back, but the user must allow access in the app.
  final bool userActionNeeded;

  /// Reconnecting over the USB cable rather than Wi-Fi.
  final bool usb;

  @override
  List<Object?> get props => [unreachable, userActionNeeded, usb];
}

/// Live transfer owns the camera connection and the Wi-Fi binding.
class ConnectLiveOwned extends ConnectState {
  const ConnectLiveOwned();
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
