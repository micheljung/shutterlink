import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptp/camera_profile.dart';
import 'package:shutterlink/ptp/dataset.dart';
import 'package:shutterlink/ptp/generic_ptp_profile.dart';
import 'package:shutterlink/ptp/profile_registry.dart';
import 'package:shutterlink/ptp/ptp_session.dart';

class _ByManufacturer implements CameraProfile {
  const _ByManufacturer(
    this.id,
    this.manufacturer, {
    this.usbVendorIds = const {},
  });

  @override
  final String id;
  final String manufacturer;

  @override
  final Set<int> usbVendorIds;

  @override
  bool matches(PtpDeviceInfo info) => info.manufacturer == manufacturer;

  @override
  Future<ProfileConnection> attach(
    PtpSession session,
    PtpDeviceInfo info,
    ProfileOptions options,
  ) => throw UnimplementedError();
}

PtpDeviceInfo _info({
  String manufacturer = 'Nikon',
  int vendorExtensionId = 0x0A,
}) => PtpDeviceInfo(
  standardVersion: 100,
  vendorExtensionId: vendorExtensionId,
  vendorExtensionVersion: 100,
  vendorExtensionDesc: '',
  functionalMode: 0,
  operationsSupported: const [],
  eventsSupported: const [],
  devicePropertiesSupported: const [],
  captureFormats: const [],
  imageFormats: const [],
  manufacturer: manufacturer,
  model: '$manufacturer camera',
  deviceVersion: '1',
  serialNumber: '1',
);

void main() {
  const first = _ByManufacturer('first', 'Acme', usbVendorIds: {0x1234});
  const second = _ByManufacturer('second', 'Acme');
  const other = _ByManufacturer('other', 'Other');

  test('the first matching profile wins, in registry order', () {
    expect(
      const ProfileRegistry([other, first, second])
          .select(_info(manufacturer: 'Acme')),
      first,
    );
    expect(
      const ProfileRegistry([other, second, first])
          .select(_info(manufacturer: 'Acme')),
      second,
    );
  });

  test('a camera no profile matches gets the fallback', () {
    expect(
      const ProfileRegistry([first]).select(_info()),
      isA<GenericPtpProfile>(),
    );
    expect(
      const ProfileRegistry([first], fallback: other).select(_info()),
      other,
    );
  });

  test('only registered profiles claim USB vendors', () {
    const registry = ProfileRegistry([
      first,
    ], fallback: _ByManufacturer('fallback', '', usbVendorIds: {0x5678}));
    expect(registry.claimsUsbVendor(0x1234), isTrue);
    expect(registry.claimsUsbVendor(0x5678), isFalse);
  });

  test('the default registry picks Canon by vendor extension or name', () {
    expect(
      defaultProfileRegistry.select(_info(vendorExtensionId: 0x0B)).id,
      'canon-eos',
    );
    expect(
      defaultProfileRegistry.select(_info(manufacturer: 'Canon Inc.')).id,
      'canon-eos',
    );
    expect(defaultProfileRegistry.select(_info()).id, 'generic-ptp');
    expect(defaultProfileRegistry.claimsUsbVendor(0x04A9), isTrue);
    expect(defaultProfileRegistry.claimsUsbVendor(0x04B0), isFalse);
  });
}
