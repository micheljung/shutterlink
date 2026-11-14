import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptp/camera_client.dart';
import 'package:shutterlink/ptp/ptp_camera_client.dart';
import 'package:shutterlink/ptp/ptp_constants.dart';

import '../fakes/fake_ptp_device.dart';

typedef OpenFakeClient = Future<(CameraClient, FakePtpDevice)> Function();

/// What every transport must deliver to a [CameraClient] driven by
/// `FakeProfile`, run against the same [FakePtpDevice].
void cameraClientContract(String name, OpenFakeClient open) {
  group('$name camera client contract', () {
    late CameraClient client;
    late FakePtpDevice device;

    setUp(() async {
      (client, device) = await open();
    });

    tearDown(() => client.close());

    Uint8List contentOf(int handle) =>
        device.objects.firstWhere((o) => o.handle == handle).content;

    Future<CameraObject> photo(int handle) async =>
        (await client.listPhotos()).firstWhere((o) => o.handle == handle);

    Future<Uint8List> download(
      CameraObject object, {
      int offset = 0,
      CancelToken? cancelToken,
    }) async {
      final bytes = BytesBuilder(copy: false);
      await client.download(
        object,
        (chunk) async {
          bytes.add(chunk);
          cancelToken?.cancel();
        },
        offset: offset,
        cancelToken: cancelToken,
      );
      return bytes.takeBytes();
    }

    int count(int opcode) =>
        device.receivedOpcodes.where((op) => op == opcode).length;

    test('is driven by the fake profile', () {
      expect((client as PtpCameraClient).profileId, 'fake');
    });

    test('lists the photos the profile knows, and the newest folder', () async {
      expect((await client.listPhotos()).map((p) => p.handle), [
        FakePtpDevice.jpegHandle,
        FakePtpDevice.largeJpegHandle,
      ]);
      expect(await client.newestFolderHandles(), [
        FakePtpDevice.jpegHandle,
        FakePtpDevice.rawHandle,
        FakePtpDevice.videoHandle,
        FakePtpDevice.largeJpegHandle,
      ]);
    });

    test('objectInfo maps a photo and rejects an unknown handle', () async {
      expect(
        await client.objectInfo(FakePtpDevice.jpegHandle),
        await photo(FakePtpDevice.jpegHandle),
      );
      expect(await client.objectInfo(0xDEAD), isNull);
    });

    test('a thumbnail waits behind a running download', () async {
      final object = await photo(FakePtpDevice.largeJpegHandle);
      final downloaded = download(object);
      final thumbnail = client.thumbnail(FakePtpDevice.jpegHandle);

      expect(await thumbnail, isNotEmpty);
      expect(await downloaded, contentOf(FakePtpDevice.largeJpegHandle));
      expect(
        device.receivedOpcodes.indexOf(PtpOperation.getThumb),
        greaterThan(
          device.receivedOpcodes.lastIndexOf(PtpOperation.getPartialObject),
        ),
      );
    });

    test('downloads more than 64 KiB from an offset', () async {
      const offset = 1000;
      final object = await photo(FakePtpDevice.largeJpegHandle);
      expect(
        await download(object, offset: offset),
        Uint8List.sublistView(contentOf(object.handle), offset),
      );
    });

    test('a cancelled download stops after the chunk in flight', () async {
      final object = await photo(FakePtpDevice.largeJpegHandle);
      await expectLater(
        download(object, cancelToken: CancelToken()),
        throwsA(isA<TransferCancelledException>()),
      );
      expect(count(PtpOperation.getPartialObject), 1);
    });

    group('delete', () {
      test('removes the file', () async {
        await client.delete(FakePtpDevice.jpegHandle);
        expect(
          device.objects.map((o) => o.handle),
          isNot(contains(FakePtpDevice.jpegHandle)),
        );
      });

      test('counts a gone handle as deleted', () async {
        await client.delete(0xDEAD);
      });

      test('asks a busy camera again', () async {
        device.deleteBusyResponses = 1;
        await client.delete(FakePtpDevice.jpegHandle);
        expect(count(PtpOperation.deleteObject), 2);
      });

      test('reports a refusal', () async {
        device.deleteDeniedCode = PtpResponseCode.accessDenied;
        await expectLater(
          client.delete(FakePtpDevice.jpegHandle),
          throwsA(isA<DeleteDeniedException>()),
        );
      });
    });

    test('a drop mid-download fails it and disconnects', () async {
      device.dropAfterPartialBytes = ptpDownloadChunkSize;
      final object = await photo(FakePtpDevice.largeJpegHandle);
      await expectLater(
        download(object),
        throwsA(isA<CameraDisconnectedException>()),
      );
      expect(count(PtpOperation.getPartialObject), 2);
      await client.disconnected;
    });
  });
}
