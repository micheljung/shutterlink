import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/download/download_cubit.dart';
import 'package:shutterlink/feature/download/download_state.dart';
import 'package:shutterlink/feature/gallery/gallery_cubit.dart';
import 'package:shutterlink/feature/gallery/thumbnail_tile.dart';
import 'package:shutterlink/feature/preview/full_image_loader.dart';
import 'package:shutterlink/feature/preview/preview_screen.dart';

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

  Future<FakeCameraClient> pumpGallery(
    WidgetTester tester, {
    PreviewQuality quality = PreviewQuality.thumbnail,
  }) async {
    final client = FakeCameraClient(objects)..contentOverrides[4] = cr3;
    final dependencies = await testDependencies((_, _) async => client);
    await dependencies.settings.setPreviewQuality(quality);
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
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

  testWidgets('thumbnail quality transfers no photo', (tester) async {
    final client = await pumpGallery(tester);

    await openPreview(tester, 'IMG_0001');
    await swipe(tester);

    expect(client.requestedOffsets, isEmpty);
    expect(find.byType(FullImageLoader), findsNothing);
  });

  testWidgets('full quality shows the downloaded JPEG', (tester) async {
    final client = await pumpGallery(tester, quality: PreviewQuality.full);

    await openPreview(tester, 'IMG_0001');
    await tester.pumpAndSettle();

    expect(client.requestedOffsets, {
      1: [0],
    });
    expect(shownBytes(tester), contentFor(objects[0]));
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('full quality shows the embedded preview of a RAW-only shot', (
    tester,
  ) async {
    final client = await pumpGallery(tester, quality: PreviewQuality.full);

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
    final client = await pumpGallery(tester, quality: PreviewQuality.full);
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
  });

  testWidgets('full quality waits while a download is active', (tester) async {
    final client = await pumpGallery(tester, quality: PreviewQuality.full);
    final gate = client.chunkGate = Completer<void>();
    final context = tester.element(find.byType(ThumbnailTile).first);
    final downloads = context.read<DownloadCubit>();
    final group = context.read<GalleryCubit>().state.groups[1];
    unawaited(downloads.start(client, [group], DownloadFormat.jpeg));
    await pumpUntil(tester, () => client.requestedOffsets.isNotEmpty);

    await openPreview(tester, 'IMG_0001');

    expect(find.text(FullImageLoader.unavailableHint), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(client.requestedOffsets.keys, [3]);

    await downloads.cancel();
    gate.complete();
    await pumpUntil(
      tester,
      () => downloads.state.status == DownloadStatus.cancelled,
    );
  });
}
