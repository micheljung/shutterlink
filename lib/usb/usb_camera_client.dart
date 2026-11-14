import '../ptp/camera_profile.dart';
import '../ptp/profile_registry.dart';
import '../ptp/ptp_camera_client.dart';
import '../ptp/ptp_session.dart';
import '../ptp/ptp_transport.dart';
import 'usb_bulk_transport.dart';
import 'usb_passthrough_transport.dart';
import 'usb_pipe.dart';

/// Connects to a camera over an opened USB link. Unlike Wi-Fi there is no
/// network binding, host discovery or pairing identity.
Future<PtpCameraClient> connectUsb(
  UsbCameraLink link, {
  ProfileRegistry registry = defaultProfileRegistry,
  ProfileOptions options = const ProfileOptions(),
  Duration responseTimeout = ptpDefaultResponseTimeout,
}) async {
  final PtpTransport transport = switch (link) {
    BulkLink(:final pipe) => await UsbBulkTransport.open(pipe),
    PassthroughLink(:final passthrough) => UsbPassthroughTransport(passthrough),
  };
  return PtpCameraClient.open(
    transport,
    registry: registry,
    responseTimeout: responseTimeout,
    options: options,
  );
}
