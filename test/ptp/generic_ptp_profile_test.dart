import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptpip/ptpip.dart';

import '../ptpip/fake_camera.dart';

const _canonOperations = {
  CanonEosOperation.setRemoteMode,
  CanonEosOperation.setEventMode,
  CanonEosOperation.getEvent,
};

/// A camera that offers every operation, Canon's included, but is not one.
PtpDeviceInfo _nikon({
  List<int> properties = const [PtpDeviceProperty.dateTime],
}) => PtpDeviceInfo(
  standardVersion: 100,
  vendorExtensionId: 0x0A,
  vendorExtensionVersion: 100,
  vendorExtensionDesc: 'nikon.com: 1.0',
  functionalMode: 0,
  operationsSupported: FakeCamera.defaultOperations,
  eventsSupported: const [],
  devicePropertiesSupported: properties,
  captureFormats: const [],
  imageFormats: const [PtpObjectFormat.exifJpeg],
  manufacturer: 'Nikon',
  model: 'Z 6',
  deviceVersion: '1.0',
  serialNumber: '42',
);

void main() {
  late FakeCamera camera;
  PtpIpCameraClient? client;

  Future<PtpIpCameraClient> start(FakeCamera fake) async {
    camera = fake;
    await camera.start();
    return client = await connectTo(camera);
  }

  tearDown(() async {
    await client?.close();
    client = null;
    await camera.stop();
  });

  test('a camera no profile matches falls back to generic PTP', () async {
    final c = await start(FakeCamera(deviceInfo: _nikon()));
    expect(c.profileId, 'generic-ptp');
    expect(defaultProfileRegistry.claimsUsbVendor(0x04B0), isFalse);
    expect(defaultProfileRegistry.claimsUsbVendor(0x04A9), isTrue);
  });

  test('starts with OpenSession and GetDeviceInfo only, and never sends a '
      'Canon operation', () async {
    final c = await start(FakeCamera(deviceInfo: _nikon()));
    expect(camera.receivedOpcodes, [
      PtpOperation.openSession,
      PtpOperation.getDeviceInfo,
    ]);
    await Future<void>.delayed(testPollInterval * 3);
    await c.listPhotos();
    await c.close();
    expect(
      camera.receivedOpcodes.toSet().intersection(_canonOperations),
      isEmpty,
    );
  });

  test('reads the clock from the DateTime property only', () async {
    var c = await start(
      FakeCamera(
        deviceInfo: _nikon(),
        devicePropertyValues: {
          PtpDeviceProperty.dateTime: ptpStringValue('20261113T095830'),
        },
      ),
    );
    expect(await c.cameraTime(), DateTime(2026, 11, 13, 9, 58, 30));
    await c.close();
    await camera.stop();

    c = await start(FakeCamera(deviceInfo: _nikon(properties: const [])));
    expect(await c.cameraTime(), isNull);
  });

  test('shows JPEGs and hides formats it does not know', () async {
    final c = await start(FakeCamera(deviceInfo: _nikon()));
    expect((await c.listPhotos()).map((p) => p.handle), [
      FakeCamera.jpegHandle,
      FakeCamera.largeJpegHandle,
      FakeCamera.rootJpegHandle,
    ]);
    expect(await c.objectInfo(FakeCamera.rawHandle), isNull);
  });

  test('announces nothing', () async {
    final c = await start(FakeCamera(deviceInfo: _nikon()));
    final added = <int>[];
    var changes = 0;
    c.addedObjects.listen(added.add);
    c.storageChanged.listen((_) => changes++);
    camera
      ..addObject(
        FakeObject(
          handle: 0x30,
          format: PtpObjectFormat.exifJpeg,
          filename: 'IMG_0030.JPG',
          parent: FakeCamera.folderHandle,
        ),
      )
      ..queueEventRecord(storageChangedRecord(fakeStorageId));
    await Future<void>.delayed(testPollInterval * 3);
    expect(added, isEmpty);
    expect(changes, 0);
  });

  test('asks a busy camera again before deleting', () async {
    final c = await start(
      FakeCamera(deviceInfo: _nikon(), deleteBusyResponses: 2),
    );
    await c.delete(FakeCamera.jpegHandle);
    expect(
      camera.receivedOpcodes.where((op) => op == PtpOperation.deleteObject),
      hasLength(3),
    );
    expect(
      camera.objects.map((o) => o.handle),
      isNot(contains(FakeCamera.jpegHandle)),
    );
  });

  test('lists the newest DCIM folder for Live', () async {
    final c = await start(FakeCamera(deviceInfo: _nikon()));
    expect(await c.newestFolderHandles(), [
      FakeCamera.jpegHandle,
      FakeCamera.rawHandle,
      FakeCamera.videoHandle,
      FakeCamera.largeJpegHandle,
    ]);
  });
}
