import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/demo/demo_camera_client.dart';
import 'package:shutterlink/feature/download/download_cubit.dart';
import 'package:shutterlink/feature/download/download_state.dart';
import 'package:shutterlink/feature/gallery/photo_group.dart';
import 'package:shutterlink/ptp/ptp_constants.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

import '../fakes/exif_jpeg.dart';
import '../fakes/fake_camera_client.dart';

/// Before reading, before decoding and after encoding.
const _thumbnailCancelChecks = 3;

/// Cancelled once it was asked [checks] times.
class _CancelAfter extends CancelToken {
  _CancelAfter(this.checks);

  int checks;

  @override
  bool get isCancelled => checks-- <= 0;
}

void main() {
  const largeSize = DemoCameraClient.chunkSize * 2 + 100;
  final modified = DateTime(2026, 11, 14, 9, 30);
  late Directory directory;
  late File small;
  late File large;
  late DemoCameraClient client;

  File photo(String name, int size) {
    final file = File(p.join(directory.path, name))
      ..writeAsBytesSync(List.generate(size, (i) => i % 251))
      ..setLastModifiedSync(modified);
    return file;
  }

  Future<void> writeImage(File file, int width, int height) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xFF336699), ui.BlendMode.src);
    final image = await recorder.endRecording().toImage(width, height);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    file.writeAsBytesSync(png!.buffer.asUint8List());
  }

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('shutterlink_demo');
    small = photo('IMG_0001.JPG', 10);
    large = photo('IMG_0002.jpg', largeSize);
    client = await DemoCameraClient.open([small, large]);
  });

  tearDown(() async {
    await client.close();
    directory.deleteSync(recursive: true);
  });

  Future<(Uint8List, List<int>)> download(
    CameraObject object, {
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    final bytes = BytesBuilder(copy: false);
    final progress = <int>[];
    await client.download(
      object,
      (chunk) async {
        bytes.add(chunk);
        cancelToken?.cancel();
      },
      offset: offset,
      onProgress: (received, total) {
        expect(total, object.size);
        progress.add(received);
      },
      cancelToken: cancelToken,
    );
    return (bytes.takeBytes(), progress);
  }

  test('is a demo camera holding the picked photos', () async {
    expect(client.deviceInfo.model, DemoCameraClient.model);
    expect(client.canDelete, isTrue);
    expect(await client.listPhotos(), [
      CameraObject(
        handle: 1,
        storageId: DemoCameraClient.storageId,
        filename: 'IMG_0001.JPG',
        size: 10,
        captureDate: modified,
        kind: CameraObjectKind.jpeg,
      ),
      CameraObject(
        handle: 2,
        storageId: DemoCameraClient.storageId,
        filename: 'IMG_0002.jpg',
        size: largeSize,
        captureDate: modified,
        kind: CameraObjectKind.jpeg,
      ),
    ]);
    expect(await client.newestFolderHandles(), [1, 2]);
    expect(await client.objectInfo(2), (await client.listPhotos()).last);
    expect(await client.objectInfo(3), isNull);
    expect(await client.cameraTime(), isNotNull);
  });

  test('downloads a photo byte-identical, in chunks', () async {
    final object = (await client.objectInfo(2))!;

    final (bytes, progress) = await download(object);

    expect(bytes, large.readAsBytesSync());
    expect(progress, [
      DemoCameraClient.chunkSize,
      DemoCameraClient.chunkSize * 2,
      largeSize,
    ]);
  });

  test('resumes a download at the offset', () async {
    final object = (await client.objectInfo(2))!;
    const offset = DemoCameraClient.chunkSize + 7;

    final (bytes, progress) = await download(object, offset: offset);

    expect(bytes, large.readAsBytesSync().sublist(offset));
    expect(progress.last, largeSize);
  });

  test('cancel stops a download after the chunk in flight', () async {
    final object = (await client.objectInfo(2))!;
    final cancelToken = CancelToken();
    var chunks = 0;

    await expectLater(
      client.download(object, (_) async {
        chunks++;
        cancelToken.cancel();
      }, cancelToken: cancelToken),
      throwsA(isA<TransferCancelledException>()),
    );
    expect(chunks, 1);
  });

  test('a photo that ends early fails the download', () async {
    final object = (await client.objectInfo(2))!;
    large.writeAsBytesSync([1, 2, 3]);

    await expectLater(download(object), throwsA(isA<FileSystemException>()));
  });

  test('downloads save the originals and are remembered', () async {
    final saver = RecordingPhotoSaver();
    final history = DownloadHistoryRepository(
      File(p.join(directory.path, DownloadHistoryRepository.fileName)),
    );
    final downloads = DownloadCubit(
      saver: saver,
      workDirectory: Directory(p.join(directory.path, 'work')),
      history: history,
    );
    addTearDown(downloads.close);
    final groups = groupPhotos(await client.listPhotos());

    await downloads.start(client, groups, DownloadFormat.jpeg);
    downloads.dismiss();
    await downloads.start(client, groups, DownloadFormat.jpeg);

    expect(saver.savedBytes, {
      'IMG_0001.JPG': small.readAsBytesSync(),
      'IMG_0002.jpg': large.readAsBytesSync(),
    });
    expect(saver.saved, hasLength(2));
    expect(downloads.state.status, DownloadStatus.completed);
    expect(downloads.state.alreadyDownloaded, hasLength(2));
  });

  test('deleting takes the photo off the card, never off the phone', () async {
    final changes = <void>[];
    client.storageChanged.listen(changes.add);
    final object = (await client.objectInfo(1))!;

    await client.delete(1);
    await client.delete(1);
    await pumpEventQueue();

    expect((await client.listPhotos()).map((o) => o.handle), [2]);
    expect(await client.objectInfo(1), isNull);
    expect(changes, hasLength(1));
    expect(small.existsSync(), isTrue);
    await expectLater(
      download(object),
      throwsA(
        isA<PtpResponseException>().having(
          (e) => e.responseCode,
          'responseCode',
          PtpResponseCode.invalidObjectHandle,
        ),
      ),
    );
    expect(await client.thumbnail(1), isNull);
  });

  test('close ends the connection and its event streams', () async {
    final storageDone = client.storageChanged.isEmpty;
    final addedDone = client.addedObjects.isEmpty;

    await client.close();

    await expectLater(client.disconnected, completes);
    expect(await storageDone, isTrue);
    expect(await addedDone, isTrue);
  });

  test('a photo that is no image has no thumbnail', () async {
    expect(await client.thumbnail(1), isNull);
  });

  testWidgets('a thumbnail is the photo scaled down, as PNG', (tester) async {
    const width = 640;
    const height = 480;
    final thumbnail = await tester.runAsync(() async {
      await writeImage(small, width, height);
      return client.thumbnail(1);
    });

    final codec = await tester.runAsync(
      () => ui.instantiateImageCodec(thumbnail!),
    );
    final frame = await tester.runAsync(codec!.getNextFrame);
    expect(frame!.image.width, DemoCameraClient.thumbnailWidth);
    expect(
      frame.image.height,
      DemoCameraClient.thumbnailWidth * height ~/ width,
    );
    frame.image.dispose();
    codec.dispose();
  });

  testWidgets('a thumbnail cancelled at any step is dropped', (tester) async {
    await tester.runAsync(() => writeImage(small, 1, 1));

    for (var checks = 0; checks < _thumbnailCancelChecks; checks++) {
      final thumbnail = await tester.runAsync(
        () => client.thumbnail(1, cancelToken: _CancelAfter(checks)),
      );
      expect(thumbnail, isNull, reason: 'cancelled after $checks checks');
    }
    expect(
      await tester.runAsync(
        () => client.thumbnail(
          1,
          cancelToken: _CancelAfter(_thumbnailCancelChecks),
        ),
      ),
      isNotNull,
    );
  });

  test('a photo with EXIF is dated when it was shot', () async {
    final shot = File(p.join(directory.path, 'IMG_0003.JPG'))
      ..writeAsBytesSync(exifJpeg(original: '2026:10:01 12:34:56'));
    final dated = await DemoCameraClient.open([shot]);
    addTearDown(dated.close);

    expect(
      (await dated.listPhotos()).single.captureDate,
      DateTime(2026, 10, 1, 12, 34, 56),
    );
  });
}
