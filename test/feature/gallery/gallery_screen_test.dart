import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/feature/gallery/thumbnail_tile.dart';
import 'package:shutterlink/feature/history/download_history_cubit.dart';
import 'package:shutterlink/feature/settings/settings_screen.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/test_app.dart';

const _pollInterval = Duration(milliseconds: 5);
const _maxPolls = 2000;

void main() {
  final objects = [
    cameraObject(1, 'IMG_0001.JPG'),
    cameraObject(2, 'IMG_0001.CR3'),
    cameraObject(3, 'IMG_0002.JPG'),
    cameraObject(4, 'IMG_0003.CR3'),
  ];
  final downloadedBadge = find.byIcon(Icons.download_done);

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
    List<CameraObject> downloaded = const [],
    void Function(AppDependencies dependencies)? onDependencies,
  }) async {
    final client = FakeCameraClient(objects);
    final dependencies = await testDependencies((_, _) async => client);
    onDependencies?.call(dependencies);
    await tester.runAsync(
      () => dependencies.downloadHistory.record(
        cameraKeyOf(client.deviceInfo),
        downloaded,
      ),
    );
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    final history = tester
        .element(find.byType(ThumbnailTile).first)
        .read<DownloadHistoryCubit>();
    await pumpUntil(tester, () => history.state.length == downloaded.length);
    return client;
  }

  testWidgets('shows one tile per photo group with format badges', (
    tester,
  ) async {
    await pumpGallery(tester);

    expect(find.byType(ThumbnailTile), findsNWidgets(3));
    expect(find.text('Photos (3)'), findsOneWidget);
    expect(find.text('RAW+JPEG'), findsOneWidget);
    expect(find.text('JPEG'), findsOneWidget);
    expect(find.text('RAW'), findsOneWidget);
  });

  testWidgets('long-press, tap and select all update the selection', (
    tester,
  ) async {
    await pumpGallery(tester);

    await tester.longPress(find.byType(ThumbnailTile).first);
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.text('Download (1)'), findsOneWidget);

    await tester.tap(find.byType(ThumbnailTile).last);
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Select all'));
    await tester.pump();
    expect(find.text('3 selected'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(3));

    await tester.tap(find.byTooltip('Select none'));
    await tester.pump();
    expect(find.text('Photos (3)'), findsOneWidget);
  });

  testWidgets('leaving the gallery cancels thumbnail requests', (tester) async {
    final client = await pumpGallery(tester);
    expect(client.thumbnailTokens, hasLength(3));
    expect(client.thumbnailTokens.any((token) => token!.isCancelled), isFalse);

    await tester.tap(find.byTooltip('Disconnect'));
    await tester.pumpAndSettle();

    expect(client.thumbnailTokens.every((token) => token!.isCancelled), isTrue);
  });

  Finder tileOf(String baseName) => find.byWidgetPredicate(
    (widget) => widget is ThumbnailTile && widget.group.baseName == baseName,
  );

  testWidgets('badges shots whose files for the format are downloaded', (
    tester,
  ) async {
    await pumpGallery(tester, downloaded: [objects[1], objects[2]]);

    expect(downloadedBadge, findsOneWidget);
    expect(
      find.descendant(of: tileOf('IMG_0002'), matching: downloadedBadge),
      findsOneWidget,
    );
  });

  testWidgets('select new selects shots not downloaded yet', (tester) async {
    await pumpGallery(tester, downloaded: [objects[2]]);

    await tester.tap(find.byTooltip('Select new'));
    await tester.pump();

    expect(find.text('1 selected'), findsOneWidget);
    expect(
      find.descendant(
        of: tileOf('IMG_0001'),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a download reports shots skipped as already downloaded', (
    tester,
  ) async {
    late RecordingPhotoSaver saver;
    await pumpGallery(
      tester,
      downloaded: [objects[2]],
      onDependencies: (dependencies) =>
          saver = dependencies.photoSaver as RecordingPhotoSaver,
    );

    await tester.tap(find.byTooltip('Select all'));
    await tester.pump();
    await tester.tap(find.text('Download (3)'));
    await pumpUntil(
      tester,
      () => find.text('Download finished').evaluate().isNotEmpty,
    );

    expect(find.text('1 already downloaded, skipped'), findsOneWidget);
    expect(saver.saved, [(jpeg: 'IMG_0001.JPG', raw: null)]);
  });

  testWidgets('clearing the history removes badges and downloads again', (
    tester,
  ) async {
    late RecordingPhotoSaver saver;
    await pumpGallery(
      tester,
      downloaded: [objects[2]],
      onDependencies: (dependencies) =>
          saver = dependencies.photoSaver as RecordingPhotoSaver,
    );
    expect(downloadedBadge, findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear download history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    final history = tester
        .element(find.byType(SettingsScreen))
        .read<DownloadHistoryCubit>();
    await pumpUntil(tester, () => history.state.isEmpty);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(downloadedBadge, findsNothing);

    await tester.longPress(tileOf('IMG_0002'));
    await tester.pump();
    await tester.tap(find.text('Download (1)'));
    await pumpUntil(
      tester,
      () => find.text('Download finished').evaluate().isNotEmpty,
    );

    expect(saver.saved, [(jpeg: 'IMG_0002.JPG', raw: null)]);
    await pumpUntil(tester, () => history.state.isNotEmpty);
    expect(downloadedBadge, findsOneWidget);
  });
}
