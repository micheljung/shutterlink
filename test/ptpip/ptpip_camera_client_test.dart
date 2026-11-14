import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptpip/ptpip.dart';

import 'fake_camera.dart';

const _detectionDeadline = Duration(seconds: 5);
final _eventDeadline = testPollInterval * 2;
const _newShotHandle = 0x30;
const _nextShotHandle = 0x31;
const _newFolderHandle = 0x12;
const _miscFolderHandle = 0x13;
const _miscShotHandle = 0x32;
const _overrunRecord = [64, 0, 0, 0, 1, 0, 0, 0];

FakeObject _shot(int handle, {int parent = FakeCamera.folderHandle}) =>
    FakeObject(
      handle: handle,
      format: PtpObjectFormat.exifJpeg,
      filename: 'IMG_${handle.toRadixString(16)}.JPG',
      parent: parent,
      content: patternBytes(10, seed: handle),
    );

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

  group('cameraTime', () {
    Map<int, Uint8List> clock(String value) => {
      PtpDeviceProperty.dateTime: ptpStringValue(value),
    };

    test('reads a local wall-clock time without a zone', () async {
      final c = await start(
        FakeCamera(devicePropertyValues: clock('20261113T095830.5')),
      );
      expect(await c.cameraTime(), DateTime(2026, 11, 13, 9, 58, 30, 500));
      final request = camera.receivedRequests.last;
      expect(request.opcode, PtpOperation.getDevicePropValue);
      expect(request.params, [PtpDeviceProperty.dateTime]);
    });

    test('reads a time with a zone as UTC', () async {
      final c = await start(
        FakeCamera(devicePropertyValues: clock('20261113T105830+0100')),
      );
      expect(await c.cameraTime(), DateTime.utc(2026, 11, 13, 9, 58, 30));
    });

    test('is null without GetDevicePropValue support', () async {
      final c = await start(
        FakeCamera(
          devicePropertyValues: clock('20261113T095830'),
          supportedOperations: FakeCamera.defaultOperations
              .where((op) => op != PtpOperation.getDevicePropValue)
              .toList(),
        ),
      );
      expect(await c.cameraTime(), isNull);
      expect(
        camera.receivedOpcodes,
        isNot(contains(PtpOperation.getDevicePropValue)),
      );
    });

    test('is null without the DateTime property', () async {
      final c = await start(FakeCamera());
      expect(await c.cameraTime(), isNull);
      expect(
        camera.receivedOpcodes,
        isNot(contains(PtpOperation.getDevicePropValue)),
      );
    });

    test('is null when the camera answers with an error', () async {
      final c = await start(
        FakeCamera(
          devicePropertyValues: clock('20261113T095830'),
          devicePropValueCode: PtpResponseCode.deviceBusy,
        ),
      );
      expect(await c.cameraTime(), isNull);
    });

    group('Canon camera-time property', () {
      // 2026-11-14 12:53:45 on the camera's clock, as the EOS R reports it.
      const seconds = 0x6af859d9;
      final reported = DateTime(2026, 11, 14, 12, 53, 45);

      test('is read from the initial event dump', () async {
        final c = await start(
          FakeCamera(
            initialDump: propertyChangedRecord(
              CanonEosProperty.cameraTime,
              seconds,
            ),
          ),
        );
        final time = (await c.cameraTime())!;
        expect(time.isUtc, isFalse);
        expect(time.difference(reported), greaterThanOrEqualTo(Duration.zero));
        expect(time.difference(reported), lessThan(_detectionDeadline));
      });

      test('advances with time since it arrived', () async {
        final c = await start(
          FakeCamera(
            initialDump: propertyChangedRecord(
              CanonEosProperty.cameraTime,
              seconds,
            ),
          ),
        );
        final first = (await c.cameraTime())!;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final second = (await c.cameraTime())!;
        expect(
          second.difference(first),
          greaterThanOrEqualTo(const Duration(milliseconds: 50)),
        );
      });

      test('follows a later change from polling', () async {
        final c = await start(FakeCamera());
        expect(await c.cameraTime(), isNull);
        camera.queueEventRecord(
          propertyChangedRecord(CanonEosProperty.cameraTime, seconds),
        );
        final deadline = DateTime.now().add(_detectionDeadline);
        while (await c.cameraTime() == null &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(testPollInterval);
        }
        expect(
          (await c.cameraTime())!.difference(reported),
          lessThan(_detectionDeadline),
        );
      });

      test('is not used when the DateTime property answers', () async {
        final c = await start(
          FakeCamera(
            devicePropertyValues: clock('20261113T095830'),
            initialDump: propertyChangedRecord(
              CanonEosProperty.cameraTime,
              seconds,
            ),
          ),
        );
        expect(await c.cameraTime(), DateTime(2026, 11, 13, 9, 58, 30));
      });

      test('ignores other properties', () async {
        final c = await start(
          FakeCamera(initialDump: propertyChangedRecord(0xD11B, seconds)),
        );
        expect(await c.cameraTime(), isNull);
      });
    });

    test('is null for a truncated or unparseable value', () async {
      final c = await start(
        FakeCamera(
          devicePropertyValues: {PtpDeviceProperty.dateTime: Uint8List(0)},
        ),
      );
      expect(await c.cameraTime(), isNull);
      camera.devicePropertyValues[PtpDeviceProperty.dateTime] = ptpStringValue(
        'garbage',
      );
      expect(await c.cameraTime(), isNull);
    });
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

  group('delete', () {
    test('is offered when the camera supports DeleteObject', () async {
      expect((await start(FakeCamera())).canDelete, isTrue);
    });

    test('is not offered without DeleteObject', () async {
      final c = await start(
        FakeCamera(
          supportedOperations: [
            for (final op in FakeCamera.defaultOperations)
              if (op != PtpOperation.deleteObject) op,
          ],
        ),
      );
      expect(c.canDelete, isFalse);
    });

    test('removes the file from the card', () async {
      final c = await start(FakeCamera());
      await c.delete(FakeCamera.rawHandle);

      final request = camera.receivedRequests.lastWhere(
        (r) => r.opcode == PtpOperation.deleteObject,
      );
      expect(request.params, [FakeCamera.rawHandle, PtpHandle.anyFormat]);
      expect(
        (await c.listPhotos()).map((p) => p.handle),
        isNot(contains(FakeCamera.rawHandle)),
      );
    });

    test('a file that is already gone counts as deleted', () async {
      final c = await start(FakeCamera());
      await c.delete(0xDEAD);
    });

    for (final code in [
      PtpResponseCode.objectWriteProtected,
      PtpResponseCode.storeReadOnly,
      PtpResponseCode.accessDenied,
    ]) {
      test(
        'a refusal 0x${code.toRadixString(16)} is reported as denied',
        () async {
          final c = await start(FakeCamera(deleteDeniedCode: code));
          await expectLater(
            c.delete(FakeCamera.jpegHandle),
            throwsA(
              isA<DeleteDeniedException>().having(
                (e) => e.responseCode,
                'responseCode',
                code,
              ),
            ),
          );
          expect(
            (await c.listPhotos()).map((p) => p.handle),
            contains(FakeCamera.jpegHandle),
          );
        },
      );
    }

    test('a busy camera is asked again', () async {
      final c = await start(FakeCamera(deleteBusyResponses: 2));
      await c.delete(FakeCamera.jpegHandle);
      expect(
        (await c.listPhotos()).map((p) => p.handle),
        isNot(contains(FakeCamera.jpegHandle)),
      );
    });

    test('a camera that stays busy fails the delete', () async {
      final c = await start(FakeCamera(deleteBusyResponses: 3));
      await expectLater(
        c.delete(FakeCamera.jpegHandle),
        throwsA(
          isA<PtpResponseException>().having(
            (e) => e.responseCode,
            'responseCode',
            PtpResponseCode.deviceBusy,
          ),
        ),
      );
    });

    test('other errors stay response errors', () async {
      final c = await start(
        FakeCamera(deleteDeniedCode: PtpResponseCode.generalError),
      );
      await expectLater(
        c.delete(FakeCamera.jpegHandle),
        throwsA(isA<PtpResponseException>()),
      );
    });

    test('drops the cached info of the handle', () async {
      final c = await start(FakeCamera());
      await c.listPhotos();
      await c.delete(FakeCamera.jpegHandle);
      camera.objects.add(_shot(FakeCamera.jpegHandle));
      camera.receivedRequests.clear();

      await c.listPhotos();

      expect(
        camera.receivedRequests.where(
          (r) => r.opcode == PtpOperation.getObjectInfo,
        ),
        [
          isA<CommandRequest>().having((r) => r.params, 'params', [
            FakeCamera.jpegHandle,
          ]),
        ],
      );
    });
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

  group('object info cache', () {
    const folderCount = 3;
    const perFolder = 84;
    const firstFolderHandle = 0x100;
    const firstPhotoHandle = 0x1000;
    const addedHandle = 0x2000;
    const totalObjects = folderCount + folderCount * perFolder;

    List<FakeObject> manyObjects() => [
      for (var f = 0; f < folderCount; f++) ...[
        FakeObject(
          handle: firstFolderHandle + f,
          format: PtpObjectFormat.association,
          filename: 'FOLDER$f',
        ),
        for (var i = 0; i < perFolder; i++)
          _shot(
            firstPhotoHandle + f * perFolder + i,
            parent: firstFolderHandle + f,
          ),
      ],
    ];

    int count(int opcode) =>
        camera.receivedOpcodes.where((o) => o == opcode).length;

    test('a relisting of unchanged handles sends no GetObjectInfo', () async {
      final c = await start(FakeCamera(objects: manyObjects()));
      final first = await c.listPhotos();
      expect(count(PtpOperation.getObjectInfo), totalObjects);
      camera.receivedOpcodes.clear();

      expect(await c.listPhotos(), first);
      expect(count(PtpOperation.getObjectInfo), 0);
      expect(count(PtpOperation.getObjectHandles), 1 + folderCount);
    });

    test('new handles are fetched once, deleted ones disappear', () async {
      final c = await start(
        FakeCamera(objects: manyObjects()),
        eventPollInterval: const Duration(hours: 1),
      );
      await c.listPhotos();
      camera
        ..objects.add(_shot(addedHandle, parent: firstFolderHandle))
        ..objects.add(_shot(addedHandle + 1, parent: firstFolderHandle + 1))
        ..receivedOpcodes.clear();

      final photos = await c.listPhotos();
      expect(photos, hasLength(folderCount * perFolder + 2));
      expect(count(PtpOperation.getObjectInfo), 2);

      camera.objects.removeWhere((o) => o.handle == firstPhotoHandle);
      final remaining = await c.listPhotos();
      expect(remaining.map((p) => p.handle), isNot(contains(firstPhotoHandle)));
      expect(remaining, hasLength(photos.length - 1));
    });

    test('a file still being written is fetched again', () async {
      final c = await start(FakeCamera(objects: manyObjects()));
      final writing = FakeObject(
        handle: addedHandle,
        format: PtpObjectFormat.exifJpeg,
        filename: 'IMG_NEW.JPG',
        parent: firstFolderHandle,
      );
      camera.objects.add(writing);
      expect((await photo(c, addedHandle)).size, 0);

      camera.objects
        ..remove(writing)
        ..add(_shot(addedHandle, parent: firstFolderHandle));
      expect((await photo(c, addedHandle)).size, isPositive);
    });

    test('a removal event drops the cached info of a reused handle', () async {
      final c = await start(FakeCamera(objects: manyObjects()));
      await c.listPhotos();
      camera.removeObject(firstPhotoHandle);
      await Future<void>.delayed(_eventDeadline);
      camera.objects.add(
        FakeObject(
          handle: firstPhotoHandle,
          format: PtpObjectFormat.exifJpeg,
          filename: 'IMG_REUSED.JPG',
          parent: firstFolderHandle,
          content: patternBytes(1),
        ),
      );

      expect((await photo(c, firstPhotoHandle)).filename, 'IMG_REUSED.JPG');
    });
  });

  test('a new object on the camera is announced within two polls', () async {
    final c = await start(FakeCamera());
    final added = c.addedObjects.first.timeout(_eventDeadline);

    camera.addObject(_shot(_newShotHandle));

    expect(await added, _newShotHandle);
  });

  test(
    '64-bit adds and transfer requests are announced, folders not',
    () async {
      final c = await start(FakeCamera());
      final handles = <int>[];
      c.addedObjects.listen(handles.add);

      camera
        ..addObject(
          FakeObject(
            handle: _newFolderHandle,
            format: PtpObjectFormat.association,
            filename: '101CANON',
            parent: FakeCamera.dcimHandle,
          ),
        )
        ..addObject(_shot(_newShotHandle), sixtyFourBit: true)
        ..queueEventRecord(transferRequestRecord(_shot(_nextShotHandle)));
      await Future<void>.delayed(_eventDeadline);

      expect(handles, [_newShotHandle, _nextShotHandle]);
    },
  );

  test('a storage change is announced without a handle', () async {
    final c = await start(FakeCamera());
    final handles = <int>[];
    c.addedObjects.listen(handles.add);
    final changed = c.storageChanged.first.timeout(_eventDeadline);

    camera.queueEventRecord(storageChangedRecord(0x00020001));

    await changed;
    expect(handles, isEmpty);
  });

  test('the initial event dump is not announced', () async {
    final c = await start(
      FakeCamera(initialDump: objectAddedRecord(_shot(FakeCamera.jpegHandle))),
    );
    final handles = <int>[];
    c.addedObjects.listen(handles.add);
    await Future<void>.delayed(_eventDeadline);

    expect(camera.getEventCount, greaterThan(1));
    expect(handles, isEmpty);
  });

  test('malformed event data is dropped and polling goes on', () async {
    final c = await start(
      FakeCamera(eventDataOverride: Uint8List.fromList(_overrunRecord)),
    );
    final handles = <int>[];
    c.addedObjects.listen(handles.add);
    camera.queueEventRecord(objectAddedRecord(_shot(_newShotHandle)));
    final polls = camera.getEventCount;
    await Future<void>.delayed(_eventDeadline);

    expect(camera.getEventCount, greaterThan(polls));
    expect(handles, isEmpty);
    expect(await c.listPhotos(), isNotEmpty);

    camera.eventDataOverride = null;
    await Future<void>.delayed(_eventDeadline);
    expect(handles, [_newShotHandle]);
  });

  test('addedObjects closes on disconnect and on close', () async {
    final c = await start(FakeCamera());
    final dropped = expectLater(c.addedObjects, emitsDone);
    final storageDropped = expectLater(c.storageChanged, emitsDone);
    camera.dropConnection();
    await dropped;
    await storageDropped;

    final other = await connectTo(camera);
    final closed = expectLater(other.addedObjects, emitsDone);
    await other.close();
    await closed;
  });

  test('newestFolderHandles lists the newest DCIM folder', () async {
    final c = await start(FakeCamera());
    expect(await c.newestFolderHandles(), [
      FakeCamera.jpegHandle,
      FakeCamera.rawHandle,
      FakeCamera.videoHandle,
      FakeCamera.largeJpegHandle,
    ]);

    camera.objects.addAll([
      FakeObject(
        handle: _newFolderHandle,
        format: PtpObjectFormat.association,
        filename: '101CANON',
        parent: FakeCamera.dcimHandle,
      ),
      _shot(_newShotHandle, parent: _newFolderHandle),
    ]);
    expect(await c.newestFolderHandles(), [_newShotHandle]);
  });

  test('newestFolderHandles ignores non-DCF folders', () async {
    final c = await start(FakeCamera());
    camera.objects.addAll([
      FakeObject(
        handle: _miscFolderHandle,
        format: PtpObjectFormat.association,
        filename: 'CANONMSC',
        parent: FakeCamera.dcimHandle,
      ),
      _shot(_miscShotHandle, parent: _miscFolderHandle),
      FakeObject(
        handle: _newFolderHandle,
        format: PtpObjectFormat.association,
        filename: '101_PANA',
        parent: FakeCamera.dcimHandle,
      ),
      _shot(_newShotHandle, parent: _newFolderHandle),
    ]);
    expect(await c.newestFolderHandles(), [_newShotHandle]);
  });

  test('newestFolderHandles is empty without a DCIM folder', () async {
    final c = await start(FakeCamera(objects: [_shot(_newShotHandle)]));
    expect(await c.newestFolderHandles(), isEmpty);
  });
}
