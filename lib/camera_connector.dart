import 'feature/connect/connect_cubit.dart';
import 'ptpip/ptpip_camera_client.dart';
import 'usb/usb_camera_client.dart';
import 'usb/usb_camera_platform.dart';

/// Connects over Wi-Fi (PTP/IP) or over [usb], depending on the target.
CameraConnector cameraConnector({required UsbCameraPlatform usb}) =>
    (target) async => switch (target) {
      WifiTarget(:final host, :final identity) =>
        await PtpIpCameraClient.connect(host: host, identity: identity),
      UsbTarget(:final device) => await connectUsb(await usb.open(device)),
    };
