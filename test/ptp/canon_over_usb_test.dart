import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptp/camera_profile.dart';
import 'package:shutterlink/ptp/canon/canon_constants.dart';
import 'package:shutterlink/ptp/ptp_camera_client.dart';
import 'package:shutterlink/usb/usb_camera_client.dart';
import 'package:shutterlink/usb/usb_pipe.dart';

import '../fakes/fake_ptp_device.dart';
import '../fakes/fake_usb_pipe.dart';
import '../ptpip/fake_camera.dart' show testPollInterval, testResponseTimeout;

const _detectionDeadline = Duration(seconds: 5);

/// The Canon profile behaves over USB as it does over PTP/IP
/// (test/ptpip/ptpip_camera_client_test.dart).
void main() {
  late FakePtpDevice device;

  Future<PtpCameraClient> connect(FakePtpDevice fake) async {
    device = fake;
    final client = await connectUsb(
      BulkLink(FakeUsbPipe(device)),
      responseTimeout: testResponseTimeout,
      options: const ProfileOptions(eventPollInterval: testPollInterval),
    );
    addTearDown(client.close);
    return client;
  }

  test('the default registry picks the Canon profile', () async {
    final client = await connect(FakePtpDevice());
    expect(client.profileId, 'canon-eos');
  });

  test('a storage change (0xC185) is announced without a handle', () async {
    final client = await connect(FakePtpDevice());
    final handles = <int>[];
    client.addedObjects.listen(handles.add);
    final changed = client.storageChanged.first.timeout(testPollInterval * 2);

    device.queueEventRecord(storageChangedRecord(fakeStorageId));

    await changed;
    expect(handles, isEmpty);
  });

  test('the camera time comes from 0xD113 in the initial dump', () async {
    // 2026-11-14 12:53:45 on the camera's clock, as the EOS R reports it.
    const seconds = 0x6af859d9;
    final reported = DateTime(2026, 11, 14, 12, 53, 45);
    final client = await connect(
      FakePtpDevice(
        initialDump: propertyChangedRecord(
          CanonEosProperty.cameraTime,
          seconds,
        ),
      ),
    );
    final time = (await client.cameraTime())!;
    expect(time.isUtc, isFalse);
    expect(time.difference(reported), greaterThanOrEqualTo(Duration.zero));
    expect(time.difference(reported), lessThan(_detectionDeadline));
  });
}
