import 'camera_profile.dart';
import 'canon/canon_eos_profile.dart';
import 'dataset.dart';
import 'generic_ptp_profile.dart';

const defaultProfileRegistry = ProfileRegistry([CanonEosProfile()]);

class ProfileRegistry {
  const ProfileRegistry(
    this.profiles, {
    this.fallback = const GenericPtpProfile(),
  });

  /// Tried in order; the first match wins.
  final List<CameraProfile> profiles;
  final CameraProfile fallback;

  CameraProfile select(PtpDeviceInfo info) => profiles.firstWhere(
    (profile) => profile.matches(info),
    orElse: () => fallback,
  );

  /// Whether a registered profile, not the fallback, claims this vendor.
  bool claimsUsbVendor(int vendorId) =>
      profiles.any((profile) => profile.usbVendorIds.contains(vendorId));
}
