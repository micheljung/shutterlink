import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptp/canon/canon_eos_profile.dart';
import 'package:shutterlink/ptpip/ptpip.dart';

import '../ptpip/fake_camera.dart';

const _fastRetry = Duration(milliseconds: 1);

void main() {
  late FakeCamera camera;
  PtpIpCameraClient? client;

  Future<PtpIpCameraClient> start(
    FakeCamera fake, {
    CanonEosProfile profile = const CanonEosProfile(),
  }) async {
    camera = fake;
    await camera.start();
    return client = await PtpIpCameraClient.connect(
      host: InternetAddress.loopbackIPv4.address,
      port: camera.port,
      identity: pairedIdentity,
      responseTimeout: testResponseTimeout,
      eventPollInterval: testPollInterval,
      registry: ProfileRegistry([profile]),
    );
  }

  tearDown(() async {
    await client?.close();
    client = null;
    await camera.stop();
  });

  test('a model override replaces the default quirks', () async {
    final c = await start(
      FakeCamera(deleteBusyResponses: 4),
      profile: const CanonEosProfile(
        modelQuirks: {
          'Canon EOS R': CanonEosQuirks(
            deleteBusyAttempts: 5,
            deleteBusyDelay: _fastRetry,
          ),
        },
      ),
    );
    await c.delete(FakeCamera.jpegHandle);
    expect(
      camera.receivedOpcodes.where((op) => op == PtpOperation.deleteObject),
      hasLength(5),
    );
  });

  test('other models keep the default quirks', () async {
    final c = await start(
      FakeCamera(deleteBusyResponses: 4),
      profile: const CanonEosProfile(
        modelQuirks: {'Canon EOS R5': CanonEosQuirks(deleteBusyAttempts: 5)},
      ),
    );
    await expectLater(
      c.delete(FakeCamera.jpegHandle),
      throwsA(isA<PtpResponseException>()),
    );
    expect(
      camera.receivedOpcodes.where((op) => op == PtpOperation.deleteObject),
      hasLength(3),
    );
  });

  test('skips the modes a camera does not support, also on close', () async {
    final c = await start(
      FakeCamera(
        supportedOperations: const [
          PtpOperation.openSession,
          PtpOperation.getDeviceInfo,
          CanonEosOperation.getEvent,
        ],
      ),
    );
    await Future<void>.delayed(testPollInterval * 3);
    await c.close();
    expect(camera.receivedOpcodes.toSet(), {
      PtpOperation.openSession,
      PtpOperation.getDeviceInfo,
      CanonEosOperation.getEvent,
    });
  });

  test('matches by vendor extension or manufacturer, nothing else', () {
    PtpDeviceInfo info(int vendorExtensionId, String manufacturer) =>
        PtpDeviceInfo(
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
          model: '',
          deviceVersion: '',
          serialNumber: '',
        );
    const profile = CanonEosProfile();
    expect(profile.matches(info(0x0B, '')), isTrue);
    expect(profile.matches(info(0, 'Canon Inc.')), isTrue);
    expect(profile.matches(info(0x0A, 'Nikon')), isFalse);
    expect(profile.usbVendorIds, {0x04A9});
  });
}
