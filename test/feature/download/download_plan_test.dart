import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/download/download_plan.dart';
import 'package:shutterlink/feature/gallery/photo_group.dart';

import '../../fakes/fake_camera_client.dart';

void main() {
  final pairJpeg = cameraObject(1, 'IMG_0001.JPG');
  final pairRaw = cameraObject(2, 'IMG_0001.CR3');
  final lone = cameraObject(3, 'IMG_0002.JPG');
  final rawOnly = cameraObject(4, 'IMG_0003.CR3');
  final pair = groupPhotos([pairJpeg, pairRaw]).single;
  final jpegOnly = groupPhotos([lone]).single;
  final rawGroup = groupPhotos([rawOnly]).single;
  final groups = [pair, jpegOnly, rawGroup];

  test('fully recorded groups are already downloaded, not tasks', () {
    final plan = planDownload(
      groups,
      DownloadFormat.jpeg,
      isDownloaded: {pairJpeg}.contains,
    );

    expect(plan.tasks, [
      DownloadTask(group: jpegOnly, files: [lone]),
    ]);
    expect(plan.alreadyDownloaded, [pair]);
    expect(plan.skipped, [rawGroup]);
  });

  test('a partly recorded pair downloads only the missing file', () {
    final plan = planDownload(
      groups,
      DownloadFormat.both,
      isDownloaded: {pairJpeg, lone}.contains,
    );

    expect(plan.tasks, [
      DownloadTask(group: pair, files: [pairRaw]),
      DownloadTask(group: rawGroup, files: [rawOnly]),
    ]);
    expect(plan.alreadyDownloaded, [jpegOnly]);
    expect(plan.skipped, isEmpty);
  });

  test('a group lacking the format is skipped, not already downloaded', () {
    final plan = planDownload(
      [rawGroup],
      DownloadFormat.jpeg,
      isDownloaded: (_) => true,
    );

    expect(plan.skipped, [rawGroup]);
    expect(plan.alreadyDownloaded, isEmpty);
  });
}
