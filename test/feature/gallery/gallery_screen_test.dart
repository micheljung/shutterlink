import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/connect/connect_screen.dart';
import 'package:shutterlink/feature/download/download_cubit.dart';
import 'package:shutterlink/feature/download/download_state.dart';
import 'package:shutterlink/feature/gallery/gallery_cubit.dart';
import 'package:shutterlink/feature/gallery/thumbnail_tile.dart';
import 'package:shutterlink/feature/history/download_history_cubit.dart';
import 'package:shutterlink/feature/mode/operating_mode.dart';
import 'package:shutterlink/feature/sessions/clock_sync_banner.dart';
import 'package:shutterlink/feature/settings/settings_cubit.dart';
import 'package:shutterlink/feature/settings/settings_screen.dart';
import 'package:shutterlink/feature/settings/upload_setup_screen.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/backend_factory.dart';
import 'package:shutterlink/upload/destination.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/spy_sessions_dependencies.dart';
import '../../fakes/test_app.dart';

const _pollInterval = Duration(milliseconds: 5);
const _maxPolls = 2000;

const _settingsScrollStep = 300.0;

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
    bool canDelete = true,
    FutureOr<void> Function(AppDependencies dependencies)? onDependencies,
  }) async {
    final client = FakeCameraClient(objects, canDelete: canDelete);
    final dependencies = await testDependencies((_) async => client);
    await tester.runAsync(() async => onDependencies?.call(dependencies));
    await tester.runAsync(
      () => dependencies.downloadHistory.record(
        cameraKeyOf(client.deviceInfo),
        downloaded,
      ),
    );
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await connectAndBrowse(tester);
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

  testWidgets('offers no Live transfer and no Sessions, even when Sessions '
      'are set up (AC9, AC23)', (tester) async {
    late SpySessionsDependencies sessions;
    final client = FakeCameraClient(objects);
    final dependencies = await testDependencies(
      (_) async => client,
      prefs: {
        SettingsRepository.sessionsServerUrlKey: 'https://photos.example.com',
      },
      sessions: (settings, directory, coordinator) =>
          sessions = SpySessionsDependencies(
            settings,
            directory,
            coordinator: coordinator,
            token: 'token',
          ),
    );
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await pumpUntil(
      tester,
      () => tester
          .element(find.byType(Navigator).first)
          .read<SettingsCubit>()
          .state
          .sessionsConfigured,
    );
    await tester.tap(find.text(ConnectScreen.connectLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text(OperatingMode.browse.label));
    await tester.pump();
    await tester.pump();

    expect(find.text('Photos (3)'), findsOneWidget);
    expect(find.byTooltip('Start Live transfer'), findsNothing);
    expect(find.byTooltip('Sessions'), findsNothing);
    expect(find.byIcon(Icons.qr_code_2), findsNothing);
    expect(find.byType(ClockSyncBanner), findsNothing);
    expect(sessions.collectors, 0);
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

  group('delete', () {
    final deleteAction = find.byTooltip('Delete from camera');

    Future<void> select(WidgetTester tester, List<String> baseNames) async {
      await tester.longPress(tileOf(baseNames.first));
      for (final name in baseNames.skip(1)) {
        await tester.tap(tileOf(name));
      }
      await tester.pump();
    }

    testWidgets('appears with a selection on a camera that can delete', (
      tester,
    ) async {
      await pumpGallery(tester);
      expect(deleteAction, findsNothing);

      await select(tester, ['IMG_0002']);

      expect(deleteAction, findsOneWidget);
    });

    testWidgets('is hidden on a camera without DeleteObject', (tester) async {
      await pumpGallery(tester, canDelete: false);

      await select(tester, ['IMG_0002']);

      expect(deleteAction, findsNothing);
    });

    testWidgets('deletes the selected shots after confirmation', (
      tester,
    ) async {
      final client = await pumpGallery(tester, downloaded: [objects[2]]);
      await select(tester, ['IMG_0001', 'IMG_0002']);

      await tester.tap(deleteAction);
      await tester.pumpAndSettle();
      expect(find.text('Delete 2 photos from the camera?'), findsOneWidget);
      expect(
        find.text(
          'RAW+JPEG shots lose both files.\n'
          'Not downloaded: 1.\n'
          "This can't be undone.",
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(client.deleted, unorderedEquals([1, 2, 3]));
      expect(find.byType(ThumbnailTile), findsOneWidget);
      expect(tileOf('IMG_0003'), findsOneWidget);
      expect(find.text('Photos (1)'), findsOneWidget);
      expect(find.text('Deleted 2 photos.'), findsOneWidget);
    });

    testWidgets('cancelling deletes nothing', (tester) async {
      final client = await pumpGallery(tester);
      await select(tester, ['IMG_0002']);

      await tester.tap(deleteAction);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(client.deleted, isEmpty);
      expect(find.byType(ThumbnailTile), findsNWidgets(3));
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('reports protected shots and keeps them selected', (
      tester,
    ) async {
      final client = await pumpGallery(tester)
        ..deleteDenied = {3};
      await select(tester, ['IMG_0002', 'IMG_0003']);

      await tester.tap(deleteAction);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(client.deleted, [4]);
      expect(
        find.text(
          'Could not delete 1 photo. They are protected or the card is locked.',
        ),
        findsOneWidget,
      );
      expect(find.text('1 selected'), findsOneWidget);
      expect(tileOf('IMG_0002'), findsOneWidget);
    });

    testWidgets('disables Download while it runs', (tester) async {
      final client = await pumpGallery(tester)
        ..deleteGate = Completer<void>();
      await select(tester, ['IMG_0002', 'IMG_0003']);
      await tester.tap(deleteAction);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pump();

      expect(
        tester
            .widget<FilledButton>(
              find.ancestor(
                of: find.text('Download (2)'),
                matching: find.byWidgetPredicate((w) => w is FilledButton),
              ),
            )
            .onPressed,
        isNull,
      );

      client.deleteGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Deleted 2 photos.'), findsOneWidget);
    });

    testWidgets('is disabled while a download runs', (tester) async {
      final client = await pumpGallery(tester)
        ..chunkGate = Completer<void>();
      final context = tester.element(tileOf('IMG_0002'));
      final download = context.read<DownloadCubit>();
      unawaited(
        download.start(
          client,
          context.read<GalleryCubit>().state.groups,
          DownloadFormat.both,
        ),
      );
      await pumpUntil(
        tester,
        () => download.state.status == DownloadStatus.running,
      );
      await select(tester, ['IMG_0003']);

      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: deleteAction,
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      client.chunkGate!.complete();
    });
  });

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

  testWidgets('download + upload without a destination opens the setup', (
    tester,
  ) async {
    late RecordingPhotoSaver saver;
    await pumpGallery(
      tester,
      onDependencies: (dependencies) =>
          saver = dependencies.photoSaver as RecordingPhotoSaver,
    );

    await tester.longPress(find.byType(ThumbnailTile).first);
    await tester.pump();
    await tester.tap(find.text('Download + upload'));
    await tester.pumpAndSettle();

    expect(find.byType(UploadSetupScreen), findsOneWidget);
    expect(find.text('Download finished'), findsNothing);
    expect(saver.saved, isEmpty);
  });

  testWidgets('download + upload names the destination and saves', (
    tester,
  ) async {
    late RecordingPhotoSaver saver;
    await pumpGallery(
      tester,
      onDependencies: (dependencies) async {
        saver = dependencies.photoSaver as RecordingPhotoSaver;
        await dependencies.destinations.save(
          const Destination(
            type: DestinationType.webdav,
            endpoint: 'https://a.example.com/dav',
          ),
          const DestinationSecrets(),
        );
      },
    );

    await tester.longPress(tileOf('IMG_0001'));
    await tester.pump();
    await tester.tap(find.text('Download + upload to WebDAV server'));
    await pumpUntil(
      tester,
      () => find.text('Download finished').evaluate().isNotEmpty,
    );

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
    await tester.scrollUntilVisible(
      find.text('Clear download history'),
      _settingsScrollStep,
      scrollable: find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(find.text('Clear download history'));
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
