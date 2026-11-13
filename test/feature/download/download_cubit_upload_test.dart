import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/download/download_cubit.dart';
import 'package:shutterlink/feature/download/download_state.dart';
import 'package:shutterlink/feature/gallery/photo_group.dart';
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

  test('with a destination, downloads go through the queue', () async {
    await setUpQueue(destination);
    final client = FakeCameraClient([jpeg, raw]);

    await cubit.start(client, groupPhotos([jpeg, raw]), DownloadFormat.both);
    await queue.idle;

    expect(cubit.state.status, DownloadStatus.completed);
    expect(cubit.state.saved, hasLength(1));
    expect(saver.saved, isEmpty);
    expect(media.published, hasLength(2));
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

  test('without a destination, the gallery saver is used', () async {
    await setUpQueue(null);

    await cubit.start(
      FakeCameraClient([jpeg]),
      groupPhotos([jpeg]),
      DownloadFormat.jpeg,
    );

    expect(saver.saved, hasLength(1));
    expect(media.calls, isEmpty);
  });

  test('a failed gallery save reports the photo as failed', () async {
    await setUpQueue(destination);
    media.failFinish = 1;

    await cubit.start(
      FakeCameraClient([jpeg]),
      groupPhotos([jpeg]),
      DownloadFormat.jpeg,
    );

    expect(cubit.state.failed.single.reason, DownloadFailureReason.saveFailed);
    expect(
      await history.contains(
        cameraKeyOf(FakeCameraClient([]).deviceInfo),
        jpeg,
      ),
      isFalse,
    );
  });
}
