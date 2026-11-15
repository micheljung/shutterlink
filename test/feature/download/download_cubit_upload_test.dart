import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/download/download_cubit.dart';
import 'package:shutterlink/feature/download/download_state.dart';
import 'package:shutterlink/feature/gallery/photo_group.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/upload_queue.dart';

import '../../fakes/fake_camera_client.dart';
import '../../upload/upload_fakes.dart';

void main() {
  const destination = Destination(
    type: DestinationType.webdav,
    endpoint: 'https://a.example.com/dav',
  );
  final date = DateTime(2026, 11, 13, 10);
  final jpeg = cameraObject(1, 'IMG_0001.JPG', captureDate: date);
  final raw = cameraObject(2, 'IMG_0001.CR3', captureDate: date);

  late Directory root;
  late Directory work;
  late FakeStorageServer server;
  late FakeMediaSaver media;
  late RecordingPhotoSaver saver;
  late DownloadHistoryRepository history;
  late UploadQueue queue;
  late DownloadCubit cubit;

  Future<void> setUpQueue(Destination? target) async {
    queue = UploadQueue(
      repository: UploadQueueRepository.inDirectory(root),
      stagingDirectory: Directory(p.join(root.path, 'staging')),
      mediaSaver: media,
      backendFactory: (_, {required allowMetered}) async => server.backend(),
      destination: target,
    );
    await queue.start();
    cubit = DownloadCubit(
      saver: saver,
      workDirectory: work,
      history: history,
      uploadQueue: queue,
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('download_upload');
    work = Directory(p.join(root.path, 'work'));
    server = FakeStorageServer();
    media = FakeMediaSaver();
    saver = RecordingPhotoSaver();
    history = DownloadHistoryRepository(
      File(p.join(root.path, DownloadHistoryRepository.fileName)),
    );
  });

  tearDown(() async {
    await cubit.close();
    await queue.idle;
    await queue.close();
    await root.delete(recursive: true);
  });

  test('a plain download with a destination only saves to the phone', () async {
    await setUpQueue(destination);
    final client = FakeCameraClient([jpeg, raw]);

    await cubit.start(client, groupPhotos([jpeg, raw]), DownloadFormat.both);
    await queue.idle;

    expect(cubit.state.status, DownloadStatus.completed);
    expect(saver.saved, [(jpeg: 'IMG_0001.JPG', raw: 'IMG_0001.CR3')]);
    expect(media.calls, isEmpty);
    expect(server.files, isEmpty);
    expect(await queue.contains(_entryKey(client, jpeg)), isFalse);
    final cameraKey = cameraKeyOf(client.deviceInfo);
    expect(await history.contains(cameraKey, jpeg), isTrue);
    expect(await history.contains(cameraKey, raw), isTrue);
  });

  test('download + upload saves the pair once, then only uploads', () async {
    await setUpQueue(destination);
    final client = FakeCameraClient([jpeg, raw]);

    await cubit.start(
      client,
      groupPhotos([jpeg, raw]),
      DownloadFormat.both,
      alsoUpload: true,
    );
    await queue.idle;

    expect(cubit.state.status, DownloadStatus.completed);
    expect(cubit.state.saved, hasLength(1));
    expect(saver.saved, [(jpeg: 'IMG_0001.JPG', raw: 'IMG_0001.CR3')]);
    expect(media.calls, isEmpty, reason: 'the queue never saves or deletes');
    expect(server.files.keys.toSet(), {
      '2026-11-13/IMG_0001.JPG',
      '2026-11-13/IMG_0001.CR3',
    });
    expect(server.files['2026-11-13/IMG_0001.CR3'], contentFor(raw));
    final cameraKey = cameraKeyOf(client.deviceInfo);
    expect(await history.contains(cameraKey, jpeg), isTrue);
    expect(await history.contains(cameraKey, raw), isTrue);
    expect(work.existsSync() ? work.listSync(recursive: true) : [], isEmpty);
  });

  test('download + upload without a destination only saves', () async {
    await setUpQueue(null);

    await cubit.start(
      FakeCameraClient([jpeg]),
      groupPhotos([jpeg]),
      DownloadFormat.jpeg,
      alsoUpload: true,
    );

    expect(saver.saved, hasLength(1));
    expect(media.calls, isEmpty);
    expect(server.files, isEmpty);
  });

  test(
    'a failed phone save reports the photo as failed and uploads nothing',
    () async {
      await setUpQueue(destination);
      saver.failFor = {'IMG_0001.JPG'};

      await cubit.start(
        FakeCameraClient([jpeg]),
        groupPhotos([jpeg]),
        DownloadFormat.jpeg,
        alsoUpload: true,
      );
      await queue.idle;

      expect(
        cubit.state.failed.single.reason,
        DownloadFailureReason.saveFailed,
      );
      expect(server.files, isEmpty);
      expect(
        await history.contains(
          cameraKeyOf(FakeCameraClient([]).deviceInfo),
          jpeg,
        ),
        isFalse,
      );
    },
  );
}

String _entryKey(FakeCameraClient client, CameraObject object) =>
    DownloadHistoryRepository.entryKey(cameraKeyOf(client.deviceInfo), object);
