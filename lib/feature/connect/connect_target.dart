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
