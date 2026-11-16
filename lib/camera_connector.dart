import 'demo/demo_camera_client.dart';
import 'feature/connect/connect_cubit.dart';
import 'ptpip/ptpip_camera_client.dart';
import 'usb/usb_camera_client.dart';
import 'usb/usb_camera_platform.dart';

/// Connects over Wi-Fi (PTP/IP), over [usb], or to the demo camera,
/// depending on the target.
CameraConnector cameraConnector({required UsbCameraPlatform usb}) =>
    (target) async => switch (target) {
      WifiTarget(:final host, :final identity) =>
        await PtpIpCameraClient.connect(host: host, identity: identity),
      UsbTarget(:final device) => await connectUsb(await usb.open(device)),
      DemoTarget(:final photos) => await DemoCameraClient.open(photos),
    };
