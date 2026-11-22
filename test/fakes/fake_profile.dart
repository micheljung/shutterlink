import 'dart:async';

import 'package:shutterlink/ptp/camera_client.dart';
import 'package:shutterlink/ptp/camera_profile.dart';
import 'package:shutterlink/ptp/dataset.dart';
import 'package:shutterlink/ptp/ptp_constants.dart';
import 'package:shutterlink/ptp/ptp_session.dart';

/// A vendor profile that exists only in tests: it claims cameras whose
/// manufacturer is 'Fake' and announces whatever the test adds to [events].
class FakeProfile implements CameraProfile {
  final events = StreamController<ProfileEvent>.broadcast();

  @override
  String get id => 'fake';

  @override
  Set<int> get usbVendorIds => const {0xFA4E};

  @override
  bool matches(PtpDeviceInfo info) => info.manufacturer == 'Fake';

  @override
  Future<ProfileConnection> attach(
    PtpSession session,
    PtpDeviceInfo info,
    ProfileOptions options,
  ) async => _FakeProfileConnection(id, events.stream);
}

class _FakeProfileConnection implements ProfileConnection {
  _FakeProfileConnection(this.profileId, this.events);

  @override
  final String profileId;

  @override
  final Stream<ProfileEvent> events;

  @override
  CameraObjectKind? kindOf(int format) =>
      format == PtpObjectFormat.exifJpeg ? CameraObjectKind.jpeg : null;

  @override
  Future<DateTime?> fallbackCameraTime() async => null;

  @override
  RetryPolicy get deleteBusyRetry =>
      const RetryPolicy(attempts: 3, delay: Duration(milliseconds: 1));

  @override
  ReconnectPolicy? get reconnectPolicy => null;

  @override
  Future<void> detach() async {}
}
