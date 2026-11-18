import '../../ptpip/camera_client.dart';
import '../../usb/usb_camera_platform.dart';

/// Where a camera connection goes.
sealed class ConnectTarget {
  const ConnectTarget();
}

/// The camera's Wi-Fi access point, paired with [identity].
final class WifiTarget extends ConnectTarget {
  const WifiTarget(this.host, this.identity);

  final String host;
  final CameraIdentity identity;
}

/// A camera on the USB cable. No network binding, discovery or identity.
final class UsbTarget extends ConnectTarget {
  const UsbTarget(this.device);

  final UsbCameraRef device;
}

/// A pretend camera that shoots with the phone's camera, to try the app
/// without a camera. No network, and nothing to reconnect.
final class DemoTarget extends ConnectTarget {
  const DemoTarget();
}

extension ConnectTargetNetwork on ConnectTarget? {
  /// Whether the connection runs over the camera's Wi-Fi, which the app
  /// binds to. Without a target it does.
  bool get usesCameraWifi => switch (this) {
    WifiTarget() || null => true,
    UsbTarget() || DemoTarget() => false,
  };
}
