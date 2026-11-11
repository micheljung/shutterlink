import 'dart:async';
import 'dart:io';

import 'package:eos_transfer/data/settings_repository.dart';
import 'package:eos_transfer/feature/download/download_cubit.dart';
import 'package:eos_transfer/feature/download/download_state.dart';
import 'package:eos_transfer/feature/gallery/photo_group.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fakes/fake_camera_client.dart';

void main() {
  late Directory root;
  late Directory work;
  late RecordingPhotoSaver saver;
  late DownloadCubit cubit;

  final pairJpeg = cameraObject(1, 'IMG_0001.JPG', size: 10);
  final pairRaw = cameraObject(2, 'IMG_0001.CR3', size: 13);
  final lone = cameraObject(3, 'IMG_0002.JPG', size: 9);
  final rawOnly = cameraObject(4, 'IMG_0003.CR3', size: 6);
  final objects = [pairJpeg, pairRaw, lone, rawOnly];

  List<PhotoGroup> groups() => groupPhotos(objects);

  List<File> workFiles() => work.existsSync()
      ? work.listSync(recursive: true).whereType<File>().toList()
      : [];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('download');
    work = Directory('${root.path}/work');
    saver = RecordingPhotoSaver();
    cubit = DownloadCubit(saver: saver, workDirectory: work);
  });

  tearDown(() async {
    await cubit.close();
    await root.delete(recursive: true);
  });

  test('downloads groups sequentially with byte-identical content', () async {
    final client = FakeCameraClient(objects);

    await cubit.start(client, groups(), DownloadFormat.both);

    expect(cubit.state.status, DownloadStatus.completed);
    expect(saver.saved, [
      (jpeg: null, raw: 'IMG_0003.CR3'),
      (jpeg: 'IMG_0002.JPG', raw: null),
      (jpeg: 'IMG_0001.JPG', raw: 'IMG_0001.CR3'),
    ]);
    for (final object in objects) {
      expect(saver.savedBytes[object.filename], contentFor(object));
    }
    expect(cubit.state.saved, hasLength(3));
    expect(cubit.state.overallProgress, 1);
    expect(workFiles(), isEmpty);
  });

  test('skips groups lacking the requested format', () async {
    final client = FakeCameraClient(objects);

    await cubit.start(client, groups(), DownloadFormat.jpeg);

    expect(saver.saved, [
      (jpeg: 'IMG_0002.JPG', raw: null),
      (jpeg: 'IMG_0001.JPG', raw: null),
    ]);
    expect(cubit.state.skipped.single.raw, rawOnly);
    expect(client.requestedOffsets.keys, [lone.handle, pairJpeg.handle]);
  });

  test('cancel stops the queue and deletes the partial file', () async {
    final client = FakeCameraClient(objects)..chunkGate = Completer<void>();

    final run = cubit.start(client, groups(), DownloadFormat.both);
    await cubit.stream.firstWhere((state) => state.fileReceived > 0);
    expect(workFiles(), isNotEmpty);

    await cubit.cancel();
    client.chunkGate!.complete();
    await run;

    expect(cubit.state.status, DownloadStatus.cancelled);
    expect(saver.saved, isEmpty);
    expect(workFiles(), isEmpty);
  });

  test('disconnect pauses and resume continues from the file offset', () async {
    final groupList = groupPhotos([lone, rawOnly]);
    final firstSession = FakeCameraClient([
      lone,
      rawOnly,
    ], disconnectAfterChunks: 3);

    await cubit.start(firstSession, groupList, DownloadFormat.both);

    expect(cubit.state.status, DownloadStatus.paused);
    expect(cubit.state.error, DownloadCubit.disconnectedMessage);
    expect(saver.saved, hasLength(1));
    final partial = workFiles().single;
    expect(partial.lengthSync(), fakeChunkSize);

    final secondSession = FakeCameraClient([lone, rawOnly]);
    await cubit.resume(secondSession);

    expect(cubit.state.status, DownloadStatus.completed);
    expect(secondSession.requestedOffsets, {
      lone.handle: [fakeChunkSize],
    });
    expect(saver.savedBytes['IMG_0003.CR3'], contentFor(rawOnly));
    expect(saver.savedBytes['IMG_0002.JPG'], contentFor(lone));
    expect(workFiles(), isEmpty);
  });

  test('cancel while resume checks photos stops the queue', () async {
    await cubit.start(
      FakeCameraClient([lone, rawOnly], disconnectAfterChunks: 3),
      groupPhotos([lone, rawOnly]),
      DownloadFormat.both,
    );
    final reconnected = FakeCameraClient([lone, rawOnly])
      ..objectInfoGate = Completer<void>();

    final resuming = cubit.resume(reconnected);
    await cubit.cancel();
    reconnected.objectInfoGate!.complete();
    await resuming;

    expect(cubit.state.status, DownloadStatus.cancelled);
    expect(reconnected.requestedOffsets, isEmpty);
    expect(workFiles(), isEmpty);
  });

  test('a failing group is reported and the queue continues', () async {
    saver.failFor = {'IMG_0002.JPG'};

    await cubit.start(FakeCameraClient(objects), groups(), DownloadFormat.both);

    expect(cubit.state.status, DownloadStatus.completed);
    expect(
      cubit.state.failed.single,
      DownloadFailure(
        groupPhotos([lone]).single,
        DownloadFailureReason.saveFailed,
      ),
    );
    expect(cubit.state.saved, hasLength(2));
    expect(workFiles(), isEmpty);
  });

  test('cancelling a paused queue discards kept files', () async {
    await cubit.start(
      FakeCameraClient(objects, disconnectAfterChunks: 1),
      groups(),
      DownloadFormat.both,
    );
    expect(cubit.state.status, DownloadStatus.paused);
    expect(workFiles(), isNotEmpty);

    await cubit.cancel();

    expect(cubit.state.status, DownloadStatus.cancelled);
    expect(workFiles(), isEmpty);
  });

  test('resume is ignored unless paused', () async {
    final client = FakeCameraClient(objects);

    await cubit.resume(client);

    expect(cubit.state.status, DownloadStatus.idle);
    expect(client.requestedOffsets, isEmpty);
  });

  test('overall progress grows monotonically to completion', () async {
    final client = FakeCameraClient(objects);
    final progress = <double>[];
    final subscription = cubit.stream.listen(
      (state) => progress.add(state.overallProgress),
    );

    await cubit.start(client, groups(), DownloadFormat.both);
    await subscription.cancel();

    expect(progress, orderedEquals([...progress]..sort()));
    expect(progress.last, 1);
  });

  test('a completed file of a paused group is not refetched', () async {
    final pair = groupPhotos([pairJpeg, pairRaw]);
    final first = FakeCameraClient(objects, disconnectAfterChunks: 4);
    await cubit.start(first, pair, DownloadFormat.both);
    expect(cubit.state.status, DownloadStatus.paused);

    final second = FakeCameraClient(objects);
    await cubit.resume(second);

    expect(second.requestedOffsets.containsKey(pairJpeg.handle), isFalse);
    expect(saver.savedBytes['IMG_0001.CR3'], contentFor(pairRaw));
    expect(saver.savedBytes['IMG_0001.JPG'], contentFor(pairJpeg));
  });

  test('resume never counts a finished file twice', () async {
    final pair = groupPhotos([pairJpeg, pairRaw]);
    await cubit.start(
      FakeCameraClient(objects, disconnectAfterChunks: 4),
      pair,
      DownloadFormat.both,
    );
    final states = <DownloadState>[];
    final subscription = cubit.stream.listen(states.add);

    await cubit.resume(FakeCameraClient(objects));
    await subscription.cancel();

    for (final state in states) {
      expect(state.completedBytes, lessThanOrEqualTo(state.totalBytes));
      expect(state.overallProgress, lessThanOrEqualTo(1));
    }
    expect(states.last.overallProgress, 1);
  });

  for (final (description, current) in [
    ('was deleted', null),
    ('changed size', cameraObject(3, 'IMG_0002.JPG', size: 11)),
    ('was renamed', cameraObject(3, 'IMG_9999.JPG', size: 9)),
    (
      'changed capture date',
      cameraObject(3, 'IMG_0002.JPG', size: 9, captureDate: DateTime(2026)),
    ),
  ]) {
    test(
      'resume fails a group whose photo $description on the camera',
      () async {
        await cubit.start(
          FakeCameraClient([lone, rawOnly], disconnectAfterChunks: 3),
          groupPhotos([lone, rawOnly]),
          DownloadFormat.both,
        );
        expect(workFiles(), isNotEmpty);

        final reconnected = FakeCameraClient([lone, rawOnly])
          ..objectInfoOverrides = {lone.handle: current};
        await cubit.resume(reconnected);

        expect(cubit.state.status, DownloadStatus.completed);
        expect(
          cubit.state.failed.single.reason,
          DownloadFailureReason.photoChanged,
        );
        expect(cubit.state.failed.single.group.jpeg, lone);
        expect(reconnected.requestedOffsets, isEmpty);
        expect(saver.savedBytes.keys, ['IMG_0003.CR3']);
        expect(workFiles(), isEmpty);
      },
    );
  }
}
