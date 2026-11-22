import 'camera_client.dart';
import 'camera_profile.dart';
import 'dataset.dart';
import 'ptp_constants.dart';
import 'ptp_session.dart';

/// Standard PTP only, for cameras no vendor profile claims. New shots are
/// found by re-scanning folders, and only JPEGs are shown.
class GenericPtpProfile implements CameraProfile {
  const GenericPtpProfile();

  @override
  String get id => 'generic-ptp';

  @override
  Set<int> get usbVendorIds => const {};

  @override
  bool matches(PtpDeviceInfo info) => true;

  @override
  Future<ProfileConnection> attach(
    PtpSession session,
    PtpDeviceInfo info,
    ProfileOptions options,
  ) async => _GenericConnection(id);
}

class _GenericConnection implements ProfileConnection {
  _GenericConnection(this.profileId);

  @override
  final String profileId;

  @override
  Stream<ProfileEvent> get events => const Stream.empty();

  @override
  CameraObjectKind? kindOf(int format) => switch (format) {
    PtpObjectFormat.exifJpeg || PtpObjectFormat.jfif => CameraObjectKind.jpeg,
    _ => null,
  };

  @override
  Future<DateTime?> fallbackCameraTime() async => null;

  @override
  RetryPolicy get deleteBusyRetry =>
      const RetryPolicy(attempts: 3, delay: Duration(milliseconds: 200));

  @override
  ReconnectPolicy? get reconnectPolicy => null;

  @override
  Future<void> detach() async {}
}
