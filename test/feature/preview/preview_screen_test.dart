import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/data/exif.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/download/download_cubit.dart';
import 'package:shutterlink/feature/download/download_state.dart';
import 'package:shutterlink/feature/gallery/gallery_cubit.dart';
import 'package:shutterlink/feature/gallery/thumbnail_cache.dart';
import 'package:shutterlink/feature/gallery/thumbnail_tile.dart';
import 'package:shutterlink/feature/preview/full_image_load.dart';
import 'package:shutterlink/feature/preview/full_image_loader.dart';
import 'package:shutterlink/feature/preview/preview_screen.dart';
import 'package:shutterlink/feature/settings/settings_cubit.dart';

import '../../fakes/exif_jpeg.dart';
import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_cr3.dart';
import '../../fakes/test_app.dart';

const _pollInterval = Duration(milliseconds: 5);
const _maxPolls = 2000;
const _transition = Duration(seconds: 1);
const _swipe = Offset(-400, 0);
const _swipeSpeed = 1000.0;

void main() {
  final start = DateTime(2026, 6, 14, 12);
  final cr3 = fakeCr3();
  final objects = [
    cameraObject(1, 'IMG_0001.JPG', captureDate: start),
    cameraObject(2, 'IMG_0001.CR3', captureDate: start),
    cameraObject(
      3,
      'IMG_0002.JPG',
      captureDate: start.subtract(const Duration(minutes: 1)),
    ),
    cameraObject(
      4,
      'IMG_0003.CR3',
      size: cr3.length,
      captureDate: start.subtract(const Duration(minutes: 2)),
    ),
  ];

  Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < _maxPolls && !condition(); i++) {
      await tester.runAsync(() => Future<void>.delayed(_pollInterval));
      await tester.pump();
    }
    await tester.pump();
    expect(condition(), isTrue);
  }

  late RecordingPhotoSaver saver;

  Future<FakeCameraClient> pumpGallery(
    WidgetTester tester, {
    FakeCameraClient? camera,
    bool keepThumbnails = false,
  }) async {
    final client =
        camera ?? (FakeCameraClient(objects)..contentOverrides[4] = cr3);
    final dependencies = await testDependencies(
      (_) async => client,
      thumbnailCache: MemoryThumbnailCache(keep: keepThumbnails),
    );
    saver = dependencies.photoSaver as RecordingPhotoSaver;
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await connectAndBrowse(tester);
    return client;
  }

  Finder tileOf(String baseName) => find.byWidgetPredicate(
    (widget) => widget is ThumbnailTile && widget.group.baseName == baseName,
  );

  Future<void> openPreview(WidgetTester tester, String baseName) async {
    await tester.tap(
      find.descendant(
        of: tileOf(baseName),
        matching: find.bySemanticsLabel('Preview'),
      ),
    );
    await tester.pump();
    await tester.pump(_transition);
  }

  Finder title(String text) =>
      find.descendant(of: find.byType(AppBar), matching: find.text(text));

  Future<void> swipe(WidgetTester tester) async {
    await tester.fling(find.byType(PageView), _swipe, _swipeSpeed);
    await tester.pump();
    await tester.pump(_transition);
  }

  Uint8List? shownBytes(WidgetTester tester) {
    final image = tester.widget<Image>(
      find
          .descendant(
            of: find.byType(PreviewScreen),
            matching: find.byType(Image),
          )
          .first,
    );
    var provider = image.image;
    if (provider is ResizeImage) provider = provider.imageProvider;
    return (provider as MemoryImage).bytes;
  }

  testWidgets('the preview icon opens the photo and swipes in gallery order', (
    tester,
  ) async {
    await pumpGallery(tester);

    await openPreview(tester, 'IMG_0001');
    expect(find.byType(PreviewScreen), findsOneWidget);
    expect(title('IMG_0001'), findsOneWidget);

    await swipe(tester);
    expect(title('IMG_0002'), findsOneWidget);

    await swipe(tester);
    expect(title('IMG_0003'), findsOneWidget);
  });

  testWidgets('selecting in the preview is reflected in the gallery', (
    tester,
  ) async {
    await pumpGallery(tester);

    await openPreview(tester, 'IMG_0002');
    await tester.tap(find.byTooltip('Select'));
    await tester.pump();
    expect(find.byTooltip('Deselect'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('1 selected'), findsOneWidget);
    expect(
      find.descendant(
        of: tileOf('IMG_0002'),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );
  });

  Future<void> deleteShown(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Delete from camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
  }

  testWidgets('deleting in the preview shows the next photo', (tester) async {
    final client = await pumpGallery(tester);

    await openPreview(tester, 'IMG_0002');
    await deleteShown(tester);

    expect(client.deleted, [3]);
    expect(title('IMG_0003'), findsOneWidget);
    expect(find.text('Deleted 1 photo.'), findsOneWidget);
  });

  testWidgets('deleting the last photo shows the one before', (tester) async {
    final client = await pumpGallery(tester);

    await openPreview(tester, 'IMG_0003');
    await deleteShown(tester);

    expect(client.deleted, [4]);
    expect(title('IMG_0002'), findsOneWidget);
  });

  testWidgets('deleting the only photo closes the preview', (tester) async {
    final client = await pumpGallery(tester);
    final gallery = tester
        .element(find.byType(ThumbnailTile).first)
        .read<GalleryCubit>();
    await tester.runAsync(
      () => gallery.delete(
        gallery.state.groups.where((g) => g.baseName != 'IMG_0002').toList(),
      ),
    );
    await tester.pumpAndSettle();

    await openPreview(tester, 'IMG_0002');
    await deleteShown(tester);

    expect(client.objects, hasLength(0));
    expect(find.byType(PreviewScreen), findsNothing);
    expect(find.text('No photos on the card.'), findsOneWidget);
  });

  testWidgets('the preview shows the downloaded JPEG', (tester) async {
    final client = await pumpGallery(tester);

    await openPreview(tester, 'IMG_0001');
    await tester.pumpAndSettle();

    expect(client.requestedOffsets, {
      1: [0],
    });
    expect(shownBytes(tester), contentFor(objects[0]));
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('the preview shows the embedded preview of a RAW-only shot', (
    tester,
  ) async {
    final client = await pumpGallery(tester);

    await openPreview(tester, 'IMG_0003');
    await tester.pumpAndSettle();

    expect(client.requestedOffsets, {
      4: [0],
    });
    expect(shownBytes(tester), fakePreviewJpeg);
  });

  testWidgets('leaving a page or the preview cancels its transfer', (
    tester,
  ) async {
    final client = await pumpGallery(tester);
    final gate = client.chunkGate = Completer<void>();

    await openPreview(tester, 'IMG_0001');
    final first = client.downloadTokens[1]!.single!;
    expect(first.isCancelled, isFalse);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await swipe(tester);
    expect(first.isCancelled, isTrue);
    final second = client.downloadTokens[3]!.single!;
    expect(second.isCancelled, isFalse);

    await tester.pageBack();
    await tester.pump();
    await tester.pump(_transition);
    expect(second.isCancelled, isTrue);

    gate.complete();
    await tester.pumpAndSettle();
    expect(client.requestedOffsets, {
      1: [0],
      3: [0],
    });
  });

  testWidgets('the full image waits for a thumbnail not loaded yet', (
    tester,
  ) async {
    final client = FakeCameraClient(objects)..contentOverrides[4] = cr3;
    final thumbnails = client.thumbnailGate = Completer<void>();
    await pumpGallery(tester, camera: client);

    await openPreview(tester, 'IMG_0001');
    expect(client.requestedOffsets, isEmpty);

    thumbnails.complete();
    await tester.pumpAndSettle();
    expect(client.requestedOffsets, {
      1: [0],
    });
    expect(shownBytes(tester), contentFor(objects[0]));
  });

  testWidgets('the full image waits while a download is active', (
    tester,
  ) async {
    final client = await pumpGallery(tester);
    final gate = client.chunkGate = Completer<void>();
    final context = tester.element(find.byType(ThumbnailTile).first);
    final downloads = context.read<DownloadCubit>();
    final group = context.read<GalleryCubit>().state.groups[1];
    unawaited(downloads.start(client, [group], DownloadFormat.jpeg));
    await pumpUntil(tester, () => client.requestedOffsets.isNotEmpty);

    await openPreview(tester, 'IMG_0001');

    expect(find.text(FullImageLoader.unavailableHint), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    // Only the head of the shown photo, for its orientation.
    await pumpUntil(tester, () => client.requestedOffsets.containsKey(1));
    expect(client.requestedOffsets[1], [0]);
    expect(headReadLength, greaterThan(objects[0].size));
    expect(client.downloadLengths[1], [objects[0].size]);
    expect(find.byTooltip('Download'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.download),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );

    await downloads.cancel();
    client.chunkGate = null;
    gate.complete();
    await pumpUntil(
      tester,
      () => downloads.state.status == DownloadStatus.cancelled,
    );
    await pumpUntil(tester, () => client.requestedOffsets.containsKey(1));
    await tester.pumpAndSettle();
    expect(find.text(FullImageLoader.unavailableHint), findsNothing);
    expect(shownBytes(tester), contentFor(objects[0]));
  });

  testWidgets('swiping back shows a kept photo without fetching it again', (
    tester,
  ) async {
    final client = await pumpGallery(tester);
    await openPreview(tester, 'IMG_0001');
    await tester.pumpAndSettle();
    await swipe(tester);
    await tester.pumpAndSettle();

    await tester.fling(find.byType(PageView), -_swipe, _swipeSpeed);
    await tester.pumpAndSettle();

    expect(title('IMG_0001'), findsOneWidget);
    expect(shownBytes(tester), contentFor(objects[0]));
    expect(client.requestedOffsets[1], [0]);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('swiping back resumes a partial load where it stopped', (
    tester,
  ) async {
    final client = await pumpGallery(tester);
    final gate = client.chunkGate = Completer<void>();
    await openPreview(tester, 'IMG_0001');
    await pumpUntil(tester, () => client.requestedOffsets.containsKey(1));
    await swipe(tester);

    client.chunkGate = null;
    gate.complete();
    await tester.pumpAndSettle();
    await tester.fling(find.byType(PageView), -_swipe, _swipeSpeed);
    await tester.pumpAndSettle();

    expect(shownBytes(tester), contentFor(objects[0]));
    expect(client.requestedOffsets[1], [0, fakeChunkSize]);
  });

  testWidgets('a preview asks the camera for at most one chunk at a time', (
    tester,
  ) async {
    final big = cameraObject(
      1,
      'IMG_0001.JPG',
      size: 3 * previewChunkLength,
      captureDate: start,
    );
    final client = FakeCameraClient([big])..chunkSize = previewChunkLength;
    await pumpGallery(tester, camera: client);

    await openPreview(tester, 'IMG_0001');
    await pumpUntil(
      tester,
      () => (client.downloadLengths[1]?.length ?? 0) >= 4,
    );
    await tester.pumpAndSettle();

    expect(shownBytes(tester), hasLength(big.size));

    expect(client.downloadLengths[1], [
      headReadLength,
      previewChunkLength,
      previewChunkLength,
      previewChunkLength - headReadLength,
    ]);
  });

  group('Download', () {
    Future<void> tapDownload(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Download'));
      await tester.pump();
    }

    testWidgets('saves the shown photo without fetching it again', (
      tester,
    ) async {
      final client = await pumpGallery(tester);
      await openPreview(tester, 'IMG_0002');
      await tester.pumpAndSettle();

      await tapDownload(tester);
      final downloads = tester
          .element(find.byType(PreviewScreen))
          .read<DownloadCubit>();
      await pumpUntil(
        tester,
        () => downloads.state.status == DownloadStatus.completed,
      );
      await tester.pumpAndSettle();

      expect(find.text('Download finished'), findsOneWidget);
      expect(saver.savedBytes['IMG_0002.JPG'], contentFor(objects[2]));
      expect(client.requestedOffsets, {
        3: [0],
      });
      expect(find.byType(PreviewScreen), findsOneWidget);
      expect(find.text('1 selected'), findsNothing);
    });

    testWidgets('resumes after what the preview received so far', (
      tester,
    ) async {
      final client = await pumpGallery(tester);
      final gate = client.chunkGate = Completer<void>();
      await openPreview(tester, 'IMG_0002');
      await pumpUntil(tester, () => client.requestedOffsets.containsKey(3));

      await tapDownload(tester);
      client.chunkGate = null;
      gate.complete();
      final downloads = tester
          .element(find.byType(PreviewScreen))
          .read<DownloadCubit>();
      await pumpUntil(
        tester,
        () => downloads.state.status == DownloadStatus.completed,
      );
      await tester.pumpAndSettle();

      expect(saver.savedBytes['IMG_0002.JPG'], contentFor(objects[2]));
      // The preview shows what the download fetched instead of fetching it
      // again.
      expect(client.requestedOffsets[3], [0, fakeChunkSize]);
      expect(shownBytes(tester), contentFor(objects[2]));
    });

    testWidgets('deselects the photo it downloads, and only that one', (
      tester,
    ) async {
      await pumpGallery(tester);
      final gallery = tester
          .element(find.byType(ThumbnailTile).first)
          .read<GalleryCubit>();
      final groups = gallery.state.groups;
      gallery.setSelected([groups[0], groups[1]], true);
      await tester.pump();
      await openPreview(tester, 'IMG_0001');
      await tester.pumpAndSettle();

      await tapDownload(tester);

      expect(gallery.state.selected, {groups[1].key});
      await tester.pumpAndSettle();
    });

    testWidgets('of a format without the shown file lets the preview load it '
        'after', (tester) async {
      final client = await pumpGallery(tester);
      final gate = client.chunkGate = Completer<void>();
      await openPreview(tester, 'IMG_0001');
      await pumpUntil(tester, () => client.requestedOffsets.containsKey(1));
      final context = tester.element(find.byType(PreviewScreen));
      await tester.runAsync(
        () => context.read<SettingsCubit>().setFormat(DownloadFormat.raw),
      );

      await tapDownload(tester);
      client.chunkGate = null;
      gate.complete();
      final downloads = context.read<DownloadCubit>();
      await pumpUntil(
        tester,
        () => downloads.state.status == DownloadStatus.completed,
      );
      await tester.pumpAndSettle();

      expect(saver.savedBytes.keys, ['IMG_0001.CR3']);
      expect(shownBytes(tester), contentFor(objects[0]));
      expect(client.requestedOffsets[1], [0, fakeChunkSize]);
    });

    testWidgets('is off for a photo without the chosen format', (tester) async {
      await pumpGallery(tester);
      await openPreview(tester, 'IMG_0003');
      final context = tester.element(find.byType(PreviewScreen));
      await tester.runAsync(
        () => context.read<SettingsCubit>().setFormat(DownloadFormat.jpeg),
      );
      await tester.pump();

      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.download),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
    });
  });

  group('rotation', () {
    int turnsOfShown(WidgetTester tester) => tester
        .widget<RotatedBox>(
          find
              .descendant(
                of: find.byType(PreviewScreen),
                matching: find.byType(RotatedBox),
              )
              .first,
        )
        .quarterTurns;

    Future<void> openShown(WidgetTester tester, String baseName) async {
      await openPreview(tester, baseName);
      await pumpUntil(
        tester,
        () => find
            .descendant(
              of: find.byType(PreviewScreen),
              matching: find.byType(RotatedBox),
            )
            .evaluate()
            .isNotEmpty,
      );
    }

    Finder tileTurns(String baseName) => find.descendant(
      of: tileOf(baseName),
      matching: find.byType(RotatedBox),
    );

    FakeCameraClient portraitCamera({bool upright = false}) {
      final jpeg = exifJpeg(orientation: 6);
      final raw = fakeCr3(orientation: 8);
      return FakeCameraClient([
          cameraObject(
            1,
            'IMG_0001.JPG',
            size: jpeg.length,
            captureDate: start,
          ),
          cameraObject(
            2,
            'IMG_0002.CR3',
            size: raw.length,
            captureDate: start.subtract(const Duration(minutes: 1)),
          ),
        ])
        ..contentOverrides[1] = jpeg
        ..contentOverrides[2] = raw
        ..thumbnailsUpright = upright;
    }

    testWidgets('a portrait JPEG turns its thumbnail but not the JPEG, '
        'which turns itself', (tester) async {
      final client = await pumpGallery(
        tester,
        camera: portraitCamera(),
        keepThumbnails: true,
      );
      final gate = client.chunkGate = Completer<void>();

      await openShown(tester, 'IMG_0001');
      expect(turnsOfShown(tester), 0);

      client.chunkGate = null;
      gate.complete();
      await pumpUntil(tester, () => shownBytes(tester)!.length > 1);
      expect(shownBytes(tester), client.contentOverrides[1]);
      expect(turnsOfShown(tester), 0);
    });

    testWidgets('the thumbnail turns once the orientation is known', (
      tester,
    ) async {
      final jpeg = Uint8List.fromList([
        ...exifJpeg(orientation: 6),
        ...Uint8List(exifReadCap),
      ]);
      final client = FakeCameraClient([
        cameraObject(1, 'IMG_0001.JPG', size: jpeg.length, captureDate: start),
      ])..contentOverrides[1] = jpeg;
      await pumpGallery(tester, camera: client, keepThumbnails: true);
      final gate = client.chunkGate = Completer<void>();
      client.chunkSize = exifReadCap;

      await openShown(tester, 'IMG_0001');
      await pumpUntil(tester, () => turnsOfShown(tester) == 1);
      expect(shownBytes(tester), [1]);

      gate.complete();
      await tester.pumpAndSettle();
      expect(shownBytes(tester), jpeg);
      expect(turnsOfShown(tester), 0);
    });

    testWidgets('the preview of a portrait CR3 turns with its CMT1', (
      tester,
    ) async {
      await pumpGallery(tester, camera: portraitCamera(), keepThumbnails: true);

      await openShown(tester, 'IMG_0002');
      await tester.pumpAndSettle();

      expect(shownBytes(tester), fakePreviewJpeg);
      expect(turnsOfShown(tester), 3);
    });

    for (final upright in [false, true]) {
      testWidgets(
        'a CR3 thumbnail ${upright ? 'already upright stays' : 'turns'}'
        ' once the head is in',
        (tester) async {
          final client = await pumpGallery(
            tester,
            camera: portraitCamera(upright: upright),
            keepThumbnails: true,
          );
          final gate = client.chunkGate = Completer<void>();
          client.chunkSize = headReadLength;

          await openShown(tester, 'IMG_0002');
          await pumpUntil(tester, () => client.requestedOffsets.containsKey(2));
          await tester.pump();
          expect(shownBytes(tester), [2]);
          expect(turnsOfShown(tester), upright ? 0 : 3);

          client.chunkGate = null;
          gate.complete();
          await tester.pumpAndSettle();
          expect(shownBytes(tester), fakePreviewJpeg);
          expect(turnsOfShown(tester), 3);
        },
      );
    }

    testWidgets('a grid tile turns once its photo was previewed, '
        'without fetching others', (tester) async {
      final client = await pumpGallery(
        tester,
        camera: portraitCamera(),
        keepThumbnails: true,
      );
      expect(tester.widget<RotatedBox>(tileTurns('IMG_0002')).quarterTurns, 0);

      await openShown(tester, 'IMG_0002');
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(tester.widget<RotatedBox>(tileTurns('IMG_0002')).quarterTurns, 3);
      expect(tester.widget<RotatedBox>(tileTurns('IMG_0001')).quarterTurns, 0);
      expect(client.requestedOffsets.keys, [2]);
    });

    testWidgets('a second preview turns the thumbnail before the head '
        'arrives', (tester) async {
      final client = await pumpGallery(
        tester,
        camera: portraitCamera(),
        keepThumbnails: true,
      );
      await openShown(tester, 'IMG_0002');
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      // The preview closed with its loads, so this visit starts afresh.
      final cache = tester
          .element(find.byType(ThumbnailTile).first)
          .read<ThumbnailCache>();
      expect(cache.turnsOf(client.objects[1]), 3);

      client.chunkGate = Completer<void>();
      await openShown(tester, 'IMG_0002');
      expect(turnsOfShown(tester), 3);

      client.chunkGate!.complete();
      client.chunkGate = null;
      await tester.pumpAndSettle();
    });
  });
}
