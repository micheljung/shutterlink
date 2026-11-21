import 'dart:typed_data';

import 'camera_client.dart';
import 'dataset.dart';
import 'ptp_session.dart';

/// Vendor behaviour on top of standard PTP, chosen from the DeviceInfo.
abstract interface class CameraProfile {
  String get id;

  /// USB vendor IDs this profile claims, so a cable to such a camera may take
  /// over an existing connection.
  Set<int> get usbVendorIds;

  bool matches(PtpDeviceInfo info);

  /// Runs the vendor handshake after GetDeviceInfo and starts event delivery.
  Future<ProfileConnection> attach(
    PtpSession session,
    PtpDeviceInfo info,
    ProfileOptions options,
  );
}

/// One attached profile, valid for the PTP session it was attached to.
abstract interface class ProfileConnection {
  String get profileId;

  /// Buffered until listened to; it ends when the session does.
  Stream<ProfileEvent> get events;

  CameraObjectKind? kindOf(int format);

  /// The camera clock when the standard DateTime property gives none.
  Future<DateTime?> fallbackCameraTime();

  RetryPolicy get deleteBusyRetry;

  /// Null keeps the supervisor's own backoff.
  ReconnectPolicy? get reconnectPolicy;

  /// Stops event delivery and runs the vendor goodbye, if any.
  Future<void> detach();
}

class ProfileOptions {
  const ProfileOptions({
    this.eventPollInterval = defaultEventPollInterval,
    this.onEventData,
  });

  static const defaultEventPollInterval = Duration(seconds: 1);

  final Duration eventPollInterval;

  /// Raw vendor event data, for diagnostics.
  final void Function(Uint8List data)? onEventData;
}

class RetryPolicy {
  const RetryPolicy({required this.attempts, required this.delay});

  final int attempts;
  final Duration delay;
}

sealed class ProfileEvent {
  const ProfileEvent();
}

class ObjectAdded extends ProfileEvent {
  const ObjectAdded(this.handle);

  final int handle;
}

class ObjectRemoved extends ProfileEvent {
  const ObjectRemoved(this.handle);

  final int handle;
}

/// The card changed without the camera naming the object.
class StorageChanged extends ProfileEvent {
  const StorageChanged();
}
