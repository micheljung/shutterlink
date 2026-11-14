import 'dart:typed_data';

import '../ptp/camera_client.dart';
import '../ptp/camera_profile.dart';
import '../ptp/profile_registry.dart';
import '../ptp/ptp_camera_client.dart';
import '../ptp/ptp_session.dart';
import 'connection.dart';
import 'ptpip_transport.dart';

/// A [PtpCameraClient] over PTP/IP.
class PtpIpCameraClient extends PtpCameraClient {
  PtpIpCameraClient._(
    super.transport,
    super.session,
    super.ptpDeviceInfo,
    super.profile,
  );

  static const defaultEventPollInterval =
      ProfileOptions.defaultEventPollInterval;
  static const downloadChunkSize = ptpDownloadChunkSize;

  static Future<PtpIpCameraClient> connect({
    required String host,
    int port = ptpIpDefaultPort,
    required CameraIdentity identity,
    Duration timeout = ptpIpDefaultConnectTimeout,
    Duration pairingTimeout = ptpIpDefaultPairingTimeout,
    Duration responseTimeout = ptpDefaultResponseTimeout,
    Duration eventPollInterval = defaultEventPollInterval,
    PacketTap? packetTap,
    void Function(Uint8List data)? onEventData,
    ProfileRegistry registry = defaultProfileRegistry,
  }) async {
    final connection = await PtpIpConnection.open(
      host: host,
      port: port,
      identity: identity,
      timeout: timeout,
      pairingTimeout: pairingTimeout,
      tap: packetTap,
    );
    final transport = PtpIpTransport(connection);
    final (:session, :info, :profile) = await PtpCameraClient.bootstrap(
      transport,
      registry: registry,
      responseTimeout: responseTimeout,
      options: ProfileOptions(
        eventPollInterval: eventPollInterval,
        onEventData: onEventData,
      ),
    );
    return PtpIpCameraClient._(transport, session, info, profile);
  }
}
