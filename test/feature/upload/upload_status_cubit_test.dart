import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/feature/upload/upload_status_cubit.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/network_policy.dart';
import 'package:shutterlink/upload/storage_backend.dart';
import 'package:shutterlink/upload/upload_queue.dart';

import '../../upload/upload_fakes.dart';

void main() {
  const destination = Destination(
    type: DestinationType.webdav,
    endpoint: 'https://a.example.com/dav',
    keepLocalCopy: false,
  );
  late Directory root;
  late FakeStorageServer server;
  late FakeMediaSaver media;
  late UploadQueue queue;
  late UploadStatusCubit cubit;

  Future<void> start(NetworkStatus network) async {
    queue = UploadQueue(
      repository: UploadQueueRepository.inDirectory(root),
      stagingDirectory: Directory(p.join(root.path, 'staging')),
      mediaSaver: media,
      backendFactory: (_, {required allowMetered}) async => server.backend(),
      destination: destination,
      initialNetwork: network,
      timerFactory: FakeTimers().create,
    );
    await queue.start();
    cubit = UploadStatusCubit(queue);
  }

  Future<void> add(String name) async {
    final file = File(p.join(root.path, name))
      ..writeAsBytesSync(utf8.encode(name));
    await queue.add(
      id: name,
      file: file,
      filename: name,
      kind: CameraObjectKind.jpeg,
      captureDate: DateTime(2026, 11, 13),
    );
    await pumpEventQueue();
    await queue.idle;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('status');
    server = FakeStorageServer();
    media = FakeMediaSaver();
  });

  tearDown(() async {
    await cubit.close();
    await queue.idle;
    await queue.close();
    await root.delete(recursive: true);
  });

  test('shows pending items and why they wait', () async {
    await start(NetworkStatus.offline);
    expect(cubit.state, const UploadStatusState());

    await add('IMG_0001.JPG');

    expect(cubit.state.pending, 1);
    expect(cubit.state.waitReason, WaitReason.network);
    expect(cubit.state.progress, isNull);
  });

  test('shows failures and retries on request', () async {
    server
      ..failUploads = 1
      ..failure = const StorageException('Unauthorized', retryable: false);
    await start(const NetworkStatus.unrestricted());

    await add('IMG_0001.JPG');
    expect(cubit.state.failed.single.lastError, 'Unauthorized');
    expect(cubit.state.waitReason, WaitReason.attention);

    await cubit.retryNow();
    await pumpEventQueue();
    await queue.idle;
    expect(cubit.state.pending, 0);
    expect(cubit.state.completed, 1);
    expect(cubit.state.failed, isEmpty);
  });

  test('shows the active upload with progress', () async {
    final states = <UploadStatusState>[];
    await start(const NetworkStatus.unrestricted());
    final subscription = cubit.stream.listen(states.add);

    await add('IMG_0001.JPG');

    final uploading = states.lastWhere((state) => state.uploadingFile != null);
    expect(uploading.uploadingFile, 'IMG_0001.JPG');
    expect(uploading.progress, 1);
    expect(uploading.waitReason, isNull);
    await subscription.cancel();
  });

  test('counts kept copies and removes them on request', () async {
    await start(const NetworkStatus.unrestricted());
    media.ownershipLost.add('content://media/1');

    await add('IMG_0001.JPG');
    expect(cubit.state.keptCopies, 1);
    expect(cubit.state.pending, 0);

    expect(await cubit.removeKeptCopies(), 1);
    await pumpEventQueue();
    expect(cubit.state.keptCopies, 0);
  });
}
