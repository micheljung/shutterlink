import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptpip/ptpip.dart';

import '../fakes/fake_profile.dart';
import '../ptpip/fake_camera.dart';
import 'camera_client_contract.dart';

final _fakeInfo = PtpDeviceInfo(
  standardVersion: 100,
  vendorExtensionId: 0,
  vendorExtensionVersion: 0,
  vendorExtensionDesc: '',
  functionalMode: 0,
  operationsSupported: FakeCamera.defaultOperations,
  eventsSupported: const [],
  devicePropertiesSupported: const [],
  captureFormats: const [],
  imageFormats: const [PtpObjectFormat.exifJpeg],
  manufacturer: 'Fake',
  model: 'Fake One',
  deviceVersion: '1',
  serialNumber: '1',
);

Future<(PtpCameraClient, FakeCamera)> _openOverPtpIp(
  FakeProfile profile,
) async {
  final camera = FakeCamera(deviceInfo: _fakeInfo);
  await camera.start();
  addTearDown(camera.stop);
  final connection = await PtpIpConnection.open(
    host: InternetAddress.loopbackIPv4.address,
    port: camera.port,
    identity: pairedIdentity,
  );
  final client = await PtpCameraClient.open(
    PtpIpTransport(connection),
    registry: ProfileRegistry([profile]),
    responseTimeout: testResponseTimeout,
  );
  return (client, camera);
}

void main() {
  cameraClientContract('PTP/IP', () async {
    final (client, camera) = await _openOverPtpIp(FakeProfile());
    return (client, camera.device);
  });

  test('profile events reach the client', () async {
    final profile = FakeProfile();
    final (client, _) = await _openOverPtpIp(profile);
    addTearDown(client.close);
    final added = client.addedObjects.first;
    final changed = client.storageChanged.first;

    profile.events
      ..add(const ObjectAdded(FakeCamera.jpegHandle))
      ..add(const StorageChanged());

    expect(await added, FakeCamera.jpegHandle);
    await changed;
  });
}
