import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptpip/ptpip.dart';

import 'fake_camera.dart';

const _detectionDeadline = Duration(seconds: 5);

void main() {
  late FakeCamera camera;
  PtpIpCameraClient? client;

  Future<PtpIpCameraClient> start(
    FakeCamera fake, {
    Duration eventPollInterval = testPollInterval,
  }) async {
    camera = fake;
    await camera.start();
    return client = await connectTo(
      camera,
      eventPollInterval: eventPollInterval,
    );
  }

  tearDown(() async {
    await client?.close();
    client = null;
    await camera.stop();
  });

  Uint8List contentOf(int handle) =>
      camera.objects.firstWhere((o) => o.handle == handle).content;

  Future<CameraObject> photo(PtpIpCameraClient c, int handle) async =>
      (await c.listPhotos()).firstWhere((o) => o.handle == handle);

  test('startup runs the EOS sequence and exposes DeviceInfo', () async {
    final c = await start(FakeCamera(pairedGuids: [pairedGuid]));
    expect(camera.receivedOpcodes.take(5), [
      PtpOperation.openSession,
      PtpOperation.getDeviceInfo,
      CanonEosOperation.setRemoteMode,
      CanonEosOperation.setEventMode,
      CanonEosOperation.getEvent,
    ]);
    expect(camera.receivedRequests[2].params, [CanonEosMode.remoteModeOn]);
    expect(camera.receivedRequests[3].params, [CanonEosMode.eventModeOn]);
    expect(c.deviceInfo.manufacturer, 'Canon Inc.');
    expect(c.deviceInfo.model, 'Canon EOS R');
    expect(c.deviceInfo.deviceVersion, '1-1.8.0');
    expect(c.deviceInfo.serialNumber, '123456789');
    expect(
      c.deviceInfo.operationsSupported,
      contains(CanonEosOperation.getEvent),
    );
    expect(c.ptpDeviceInfo.vendorExtensionDesc, isNotEmpty);
  });

  test('polls GetEvent and never sends CloseSession', () async {
    final c = await start(FakeCamera());
    await Future<void>.delayed(testPollInterval * 5);
    final polls = camera.receivedOpcodes
        .where((op) => op == CanonEosOperation.getEvent)
        .length;
    expect(polls, greaterThan(2));
    await c.close();
    await c.disconnected;
    expect(camera.receivedOpcodes, isNot(contains(PtpOperation.closeSession)));
    expect(camera.receivedOpcodes.last, CanonEosOperation.setRemoteMode);
    await c.close();
  });

  test('skips Canon operations a camera does not support', () async {
    await start(
      FakeCamera(
        supportedOperations: const [
          PtpOperation.openSession,
          PtpOperation.getDeviceInfo,
        ],
      ),
      eventPollInterval: const Duration(milliseconds: 10),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await client!.close();
    expect(camera.receivedOpcodes, [
      PtpOperation.openSession,
      PtpOperation.getDeviceInfo,
    ]);
  });

  test('unknown GUID throws PairingRequiredException', () async {
    camera = FakeCamera(pairedGuids: [pairedGuid]);
    await camera.start();
    await expectLater(
      connectTo(
        camera,
        identity: CameraIdentity(guid: Uint8List(ptpIpGuidSize), name: 'x'),
      ),
      throwsA(isA<PairingRequiredException>()),
    );
  });

  test('failing startup closes the connection', () async {
    camera = FakeCamera(openSessionCode: PtpResponseCode.generalError);
    await camera.start();
    await expectLater(connectTo(camera), throwsA(isA<PtpResponseException>()));
  });

  test('lists JPEG and CR3 recursively, skipping folders and video', () async {
    final c = await start(FakeCamera(maxFragmentSize: 9));
    final photos = await c.listPhotos();
    expect(photos.map((p) => p.handle), [
      FakeCamera.jpegHandle,
      FakeCamera.rawHandle,
      FakeCamera.largeJpegHandle,
      FakeCamera.rootJpegHandle,
    ]);
    final raw = photos.firstWhere((p) => p.handle == FakeCamera.rawHandle);
    expect(
      raw,
      CameraObject(
        handle: FakeCamera.rawHandle,
        storageId: fakeStorageId,
        filename: 'IMG_0001.CR3',
        size: FakeCamera.rawSize,
        captureDate: DateTime(2024, 1, 2, 3, 4, 5),
        kind: CameraObjectKind.raw,
      ),
    );
    final root = photos.last;
    expect(root.kind, CameraObjectKind.jpeg);
    expect(root.captureDate, isNull);
    final requests = camera.receivedRequests.where(
      (r) => r.opcode == PtpOperation.getObjectHandles,
    );
    expect(requests.first.params, [
      fakeStorageId,
      PtpHandle.anyFormat,
      PtpHandle.root,
    ]);
  });

  test('a camera ignoring the parent filter yields no duplicates', () async {
    final c = await start(
      FakeCamera(
        objects: [
          FakeObject(
            handle: 1,
            format: PtpObjectFormat.association,
            filename: 'DCIM',
          ),
          FakeObject(
            handle: 2,
            format: PtpObjectFormat.exifJpeg,
            filename: 'A.JPG',
          ),
        ],
      ),
    );
    final photos = await c.listPhotos();
    expect(photos.map((p) => p.handle), [2]);
  });

  test('thumbnail returns bytes, or null without one', () async {
    final c = await start(FakeCamera());
    final thumb = await c.thumbnail(FakeCamera.jpegHandle);
    expect(
      thumb,
      camera.objects
          .firstWhere((o) => o.handle == FakeCamera.jpegHandle)
          .thumbnail,
    );
    expect(await c.thumbnail(FakeCamera.rawHandle), isNull);
    expect(await c.thumbnail(0xDEAD), isNull);
  });

  test('objectInfo maps photos and rejects others', () async {
    final c = await start(FakeCamera());
    expect(
      await c.objectInfo(FakeCamera.rawHandle),
      await photo(c, FakeCamera.rawHandle),
    );
    expect(await c.objectInfo(FakeCamera.videoHandle), isNull);
    expect(await c.objectInfo(FakeCamera.folderHandle), isNull);
    expect(await c.objectInfo(0xDEAD), isNull);
  });

  test('a thumbnail cancelled before it starts sends nothing', () async {
    final c = await start(
      FakeCamera(responseDelay: const Duration(milliseconds: 10)),
      eventPollInterval: const Duration(hours: 1),
    );
    final busy = c.listPhotos();
    final token = CancelToken();
    final thumb = c.thumbnail(FakeCamera.jpegHandle, cancelToken: token);
    token.cancel();
    final cancelled = expectLater(
      thumb,
      throwsA(isA<TransferCancelledException>()),
    );
    await busy;
    await cancelled;
    expect(camera.receivedOpcodes, isNot(contains(PtpOperation.getThumb)));
  });

  test('a download started after 50 queued thumbnails finishes first, '
      'cancelled thumbnails never reach the camera', () async {
    final c = await start(
      FakeCamera(responseDelay: const Duration(milliseconds: 2)),
      eventPollInterval: const Duration(hours: 1),
    );
    final object = await photo(c, FakeCamera.largeJpegHandle);
    camera.receivedRequests.clear();
    final tokens = List.generate(50, (_) => CancelToken());
    final thumbs = [
      for (final token in tokens)
        c
            .thumbnail(FakeCamera.jpegHandle, cancelToken: token)
            .then<Object?>((bytes) => bytes, onError: (Object error) => error),
    ];
    for (var i = 1; i < tokens.length; i += 2) {
      tokens[i].cancel();
    }
    await c.download(object, (_) async {});
    final afterDownload = camera.receivedRequests.length;
    final results = await Future.wait(thumbs);

    final opcodes = camera.receivedRequests.map((r) => r.opcode).toList();
    final lastChunk = opcodes.lastIndexOf(PtpOperation.getPartialObject);
    final thumbsBeforeDownloadEnd = opcodes
        .take(lastChunk)
        .where((op) => op == PtpOperation.getThumb)
        .length;
    expect(thumbsBeforeDownloadEnd, lessThanOrEqualTo(1));
    expect(afterDownload, lessThan(camera.receivedRequests.length));
    expect(
      opcodes.where((op) => op == PtpOperation.getThumb),
      hasLength(tokens.length ~/ 2),
    );
    for (var i = 0; i < results.length; i++) {
      expect(
        results[i],
        i.isOdd ? isA<TransferCancelledException>() : isA<Uint8List>(),
      );
    }
  });

  test('chunked download is byte-identical in 1 MiB chunks', () async {
    final c = await start(FakeCamera(maxFragmentSize: 64 * 1024));
    final object = await photo(c, FakeCamera.largeJpegHandle);
    final chunks = <Uint8List>[];
    final progress = <int>[];
    await c.download(
      object,
      (chunk) async => chunks.add(chunk),
      onProgress: (received, total) {
        expect(total, FakeCamera.largeSize);
        progress.add(received);
      },
    );
    final expectedChunks =
        (FakeCamera.largeSize / PtpIpCameraClient.downloadChunkSize).ceil();
    expect(chunks, hasLength(expectedChunks));
    expect(chunks.first.length, PtpIpCameraClient.downloadChunkSize);
    expect(progress.last, FakeCamera.largeSize);
    final bytes = Uint8List.fromList([for (final c in chunks) ...c]);
    expect(bytes, contentOf(FakeCamera.largeJpegHandle));
    final partial = camera.receivedRequests.where(
      (r) => r.opcode == PtpOperation.getPartialObject,
    );
    expect(partial.map((r) => r.params[1]), [
      0,
      PtpIpCameraClient.downloadChunkSize,
      2 * PtpIpCameraClient.downloadChunkSize,
    ]);
  });

  test('download resumes from an offset', () async {
    final c = await start(FakeCamera());
    final object = await photo(c, FakeCamera.largeJpegHandle);
    const offset = PtpIpCameraClient.downloadChunkSize + 17;
    final builder = BytesBuilder();
    await c.download(
      object,
      (chunk) async => builder.add(chunk),
      offset: offset,
    );
    expect(
      builder.takeBytes(),
      contentOf(FakeCamera.largeJpegHandle).sublist(offset),
    );
  });

  test('download at or past the end does nothing', () async {
    final c = await start(FakeCamera());
    final object = await photo(c, FakeCamera.jpegHandle);
    var writes = 0;
    await c.download(
      object,
      (_) async => writes++,
      offset: FakeCamera.jpegSize,
    );
    expect(writes, 0);
  });

  test('cancel stops within one chunk', () async {
    final c = await start(FakeCamera());
    final object = await photo(c, FakeCamera.largeJpegHandle);
    final token = CancelToken();
    var writes = 0;
    await expectLater(
      c.download(object, (_) async {
        writes++;
        token.cancel();
      }, cancelToken: token),
      throwsA(isA<TransferCancelledException>()),
    );
    expect(writes, 1);
    expect(token.isCancelled, isTrue);
  });

  test('an empty chunk before the end is an error', () async {
    final c = await start(FakeCamera());
    final object = await photo(c, FakeCamera.jpegHandle);
    final lying = CameraObject(
      handle: object.handle,
      storageId: object.storageId,
      filename: object.filename,
      size: object.size + 1,
      captureDate: object.captureDate,
      kind: object.kind,
    );
    await expectLater(
      c.download(lying, (_) async {}, offset: object.size),
      throwsA(isA<PtpResponseException>()),
    );
  });

  test('connection drop mid-transfer is detected within 5 s', () async {
    final c = await start(
      FakeCamera(dropAfterPartialBytes: PtpIpCameraClient.downloadChunkSize),
    );
    final object = await photo(c, FakeCamera.largeJpegHandle);
    var received = 0;
    final stopwatch = Stopwatch()..start();
    await expectLater(
      c.download(object, (chunk) async => received += chunk.length),
      throwsA(isA<CameraDisconnectedException>()),
    );
    await c.disconnected.timeout(_detectionDeadline);
    expect(stopwatch.elapsed, lessThan(_detectionDeadline));
    expect(received, PtpIpCameraClient.downloadChunkSize);
  });

  test('a silent camera is detected within 5 s while idle', () async {
    final c = await start(FakeCamera());
    final stopwatch = Stopwatch()..start();
    camera.silent = true;
    await c.disconnected.timeout(_detectionDeadline);
    expect(stopwatch.elapsed, lessThan(_detectionDeadline));
    await expectLater(
      c.listPhotos(),
      throwsA(isA<CameraDisconnectedException>()),
    );
    await c.close();
  });

  test('a silent camera fails a running download', () async {
    final c = await start(
      FakeCamera(),
      eventPollInterval: const Duration(hours: 1),
    );
    final object = await photo(c, FakeCamera.largeJpegHandle);
    await expectLater(
      c.download(object, (_) async => camera.silent = true),
      throwsA(isA<CameraDisconnectedException>()),
    );
  });

  test('concurrent thumbnails and download are serialized', () async {
    final c = await start(
      FakeCamera(responseDelay: const Duration(milliseconds: 5)),
    );
    final object = await photo(c, FakeCamera.largeJpegHandle);
    final builder = BytesBuilder();
    final download = c.download(object, (chunk) async => builder.add(chunk));
    final thumbnails = Future.wait([
      c.thumbnail(FakeCamera.jpegHandle),
      c.thumbnail(FakeCamera.jpegHandle),
    ]);
    final listing = c.listPhotos();
    await download;
    expect(await thumbnails, everyElement(isNotNull));
    expect(await listing, hasLength(4));
    expect(builder.takeBytes(), contentOf(FakeCamera.largeJpegHandle));
    expect(camera.maxConcurrentRequests, 1);
  });
}
