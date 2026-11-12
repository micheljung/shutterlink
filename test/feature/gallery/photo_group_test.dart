import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/download/download_plan.dart';
import 'package:shutterlink/feature/gallery/photo_group.dart';

import '../../fakes/fake_camera_client.dart';

void main() {
  final morning = DateTime(2026, 5, 1, 9);
  final noon = DateTime(2026, 5, 1, 12);

  group('groupPhotos', () {
    test('pairs JPEG and CR3 with the same base name into one group', () {
      final jpeg = cameraObject(1, 'IMG_0001.JPG', captureDate: morning);
      final raw = cameraObject(2, 'IMG_0001.CR3', captureDate: morning);
      final lone = cameraObject(3, 'IMG_0002.CR3', captureDate: noon);

      final groups = groupPhotos([jpeg, raw, lone]);

      expect(groups, hasLength(2));
      final pair = groups.singleWhere((group) => group.baseName == 'IMG_0001');
      expect(pair.jpeg, jpeg);
      expect(pair.raw, raw);
      expect(groups.first.raw, lone);
      expect(groups.first.jpeg, isNull);
    });

    test('sorts newest first and falls back to the handle', () {
      final groups = groupPhotos([
        cameraObject(1, 'IMG_0001.JPG', captureDate: morning),
        cameraObject(2, 'IMG_0002.JPG'),
        cameraObject(3, 'IMG_0003.JPG', captureDate: noon),
        cameraObject(4, 'IMG_0004.JPG'),
      ]);

      expect(groups.map((group) => group.baseName), [
        'IMG_0003',
        'IMG_0001',
        'IMG_0004',
        'IMG_0002',
      ]);
    });

    test('keeps equal file names on different cards apart', () {
      final groups = groupPhotos([
        cameraObject(1, 'IMG_0001.JPG', storageId: 1),
        cameraObject(2, 'IMG_0001.JPG', storageId: 2),
      ]);

      expect(groups, hasLength(2));
    });

    test('keeps a repeated file name of the same kind as its own group', () {
      final groups = groupPhotos([
        cameraObject(1, 'IMG_0001.JPG'),
        cameraObject(2, 'IMG_0001.JPG'),
      ]);

      expect(groups, hasLength(2));
    });
  });

  group('format selection', () {
    final pair = groupPhotos([
      cameraObject(1, 'IMG_0001.JPG'),
      cameraObject(2, 'IMG_0001.CR3'),
    ]).single;
    final jpegOnly = groupPhotos([cameraObject(3, 'IMG_0002.JPG')]).single;
    final rawOnly = groupPhotos([cameraObject(4, 'IMG_0003.CR3')]).single;

    test('filesFor picks the requested formats', () {
      expect(pair.filesFor(DownloadFormat.jpeg), [pair.jpeg]);
      expect(pair.filesFor(DownloadFormat.raw), [pair.raw]);
      expect(pair.filesFor(DownloadFormat.both), [pair.jpeg, pair.raw]);
      expect(rawOnly.filesFor(DownloadFormat.both), [rawOnly.raw]);
    });

    test('planDownload skips groups lacking the requested format', () {
      final groups = [pair, jpegOnly, rawOnly];

      final jpegPlan = planDownload(
        groups,
        DownloadFormat.jpeg,
        isDownloaded: (_) => false,
      );
      expect(jpegPlan.tasks.map((task) => task.group), [pair, jpegOnly]);
      expect(jpegPlan.skipped, [rawOnly]);

      final rawPlan = planDownload(
        groups,
        DownloadFormat.raw,
        isDownloaded: (_) => false,
      );
      expect(rawPlan.tasks.map((task) => task.group), [pair, rawOnly]);
      expect(rawPlan.skipped, [jpegOnly]);

      final bothPlan = planDownload(
        groups,
        DownloadFormat.both,
        isDownloaded: (_) => false,
      );
      expect(bothPlan.tasks, hasLength(3));
      expect(bothPlan.skipped, isEmpty);
    });
  });
}
