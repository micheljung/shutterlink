@Tags(['screenshots'])
library;

import 'package:clock/clock.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/auto_upload/auto_upload_cubit.dart';
import 'package:shutterlink/feature/auto_upload/auto_upload_screen.dart';
import 'package:shutterlink/feature/connect/connect_screen.dart';
import 'package:shutterlink/feature/gallery/thumbnail_tile.dart';
import 'package:shutterlink/feature/mode/mode_picker_screen.dart';
import 'package:shutterlink/feature/mode/operating_mode.dart';
import 'package:shutterlink/feature/sessions/clock_sync_banner.dart';
import 'package:shutterlink/feature/sessions/session_qr_sheet.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/provider_preset.dart';

import 'screenshot_harness.dart';

void main() {
  setUpAll(() async {
    WidgetsApp.debugAllowBannerOverride = false;
    await loadFonts();
  });
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  testWidgets('connect screen', (tester) async {
    await pumpApp(tester, ScreenshotCameraClient());
    await capture(tester, 'connect');
  }, variant: platform);

  testWidgets('mode picker', (tester) async {
    await pumpApp(tester, ScreenshotCameraClient());
    await tester.tap(find.text(ConnectScreen.connectLabel));
    await tester.pumpAndSettle();
    expect(find.text(ModePickerScreen.title), findsOneWidget);
    await capture(tester, 'modes');
  }, variant: platform);

  testWidgets('gallery', (tester) async {
    await pumpApp(
      tester,
      ScreenshotCameraClient(),
      downloaded: photos.skip(newestDayCount).map((photo) => photo.$1),
    );
    await connect(tester);
    final tiles = find.byType(ThumbnailTile);
    final gesture = await tester.startGesture(tester.getCenter(tiles.at(0)));
    await tester.pump(kLongPressTimeout);
    await gesture.moveTo(tester.getCenter(tiles.at(3)));
    await gesture.up();
    await tester.pumpAndSettle();
    await capture(tester, 'gallery');
  }, variant: platform);

  testWidgets('preview', (tester) async {
    await pumpApp(tester, ScreenshotCameraClient());
    await connect(tester);
    await tester.tap(find.byType(ThumbnailTile).at(1));
    await tester.pumpAndSettle();
    await precacheImages(tester);
    await capture(tester, 'preview');
  }, variant: platform);

  testWidgets('download sheet', (tester) async {
    final client = ScreenshotCameraClient(stall: true);
    await pumpApp(tester, client);
    await connect(tester);
    await tester.longPress(find.byType(ThumbnailTile).first);
    for (final index in [1, 2, 4, 5]) {
      await tester.tap(find.byType(ThumbnailTile).at(index));
    }
    await tester.pump();
    await tester.tap(find.text('Download (5)'));
    for (var i = 0; i < maxDownloadPolls && !client.stalled.isCompleted; i++) {
      await tester.runAsync(() => Future<void>.delayed(downloadPollInterval));
      await tester.pump();
    }
    expect(client.stalled.isCompleted, isTrue);
    await tester.pump(settleDuration);
    await capture(tester, 'download');
  }, variant: platform);

  testWidgets('settings', (tester) async {
    await pumpApp(tester, ScreenshotCameraClient());
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Both'));
    await tester.pumpAndSettle();
    await capture(tester, 'settings');
  }, variant: platform);

  testWidgets('settings without upload or Sessions', (tester) async {
    await pumpApp(tester, ScreenshotCameraClient());
    await openSettingsAt(tester, 'Upload');
    await capture(tester, 'settings_upload_empty');
  }, variant: platform);

  testWidgets('settings with upload and Sessions', (tester) async {
    await pumpApp(tester, ScreenshotCameraClient(), configured: true);
    await openSettingsAt(tester, 'Upload');
    await capture(tester, 'settings_upload_configured');
  }, variant: platform);

  testWidgets('upload setup provider step', (tester) async {
    await pumpApp(tester, ScreenshotCameraClient());
    await openSettingsAt(tester, 'Upload');
    await tapAndSettle(tester, 'Set up upload');
    await tapAndSettle(tester, ProviderPreset.backblazeB2.label);
    await capture(tester, 'upload_setup_provider');
  }, variant: platform);

  testWidgets('upload setup Backblaze B2 step', (tester) async {
    await pumpApp(tester, ScreenshotCameraClient());
    await openSettingsAt(tester, 'Upload');
    await tapAndSettle(tester, 'Set up upload');
    await tapAndSettle(tester, ProviderPreset.backblazeB2.label);
    await tapAndSettle(tester, 'Next');
    await tester.enterText(
      find.widgetWithText(TextField, 'Region'),
      'eu-central-003',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Bucket name'),
      'camera-photos',
    );
    await settleWithoutFocus(tester);
    await capture(tester, 'upload_setup_b2');
  }, variant: platform);

  testWidgets('upload edit page', (tester) async {
    await withClock(Clock.fixed(screenshotDay), () async {
      await pumpApp(tester, ScreenshotCameraClient(), configured: true);
      await openSettingsAt(tester, 'Upload');
      await tester.tap(find.text('Edit').first);
      await tester.pumpAndSettle();
      await capture(tester, 'upload_edit');
    });
  }, variant: platform);

  testWidgets('Sessions setup token step', (tester) async {
    await pumpApp(tester, ScreenshotCameraClient());
    await openSettingsAt(tester, 'Sessions');
    await tapAndSettle(tester, 'Connect Sessions');
    await tester.enterText(
      find.widgetWithText(TextField, 'Server URL'),
      sessionsServerUrl,
    );
    await tester.pump();
    await tapAndSettle(tester, 'Next');
    await tester.enterText(
      find.widgetWithText(TextField, 'Upload token'),
      'a-long-random-token',
    );
    await settleWithoutFocus(tester);
    await capture(tester, 'sessions_setup_token');
  }, variant: platform);

  testWidgets('Live Share', (tester) async {
    final client = ScreenshotCameraClient()..cameraLag = Duration.zero;
    await pumpApp(tester, client, configured: true);
    await enterMode(tester, OperatingMode.liveShare);
    await pumpUntilFound(tester, find.byType(SessionQrImage));
    await pumpUntilFound(tester, find.text(ClockSyncBanner.inSyncHint));
    await capture(tester, 'live_share');
    await leaveMode(tester);
  }, variant: platform);

  testWidgets('Auto Upload', (tester) async {
    final client = ScreenshotCameraClient();
    await pumpApp(tester, client, configured: true, startUploadQueue: true);
    await enterMode(tester, OperatingMode.autoUpload);
    await pumpUntilFound(tester, find.text(AutoUploadScreen.skipBacklogLabel));
    await tester.tap(find.text(AutoUploadScreen.skipBacklogLabel));
    await tester.pump();
    // Real ingestion stages files with real IO, which the test zone doesn't
    // run, so the screen gets the state a few new shots would leave.
    final cubit = tester
        .element(find.byType(AutoUploadScreen))
        .read<AutoUploadCubit>();
    final shots = [
      for (final object in client.objects)
        if (object.kind == CameraObjectKind.jpeg) RecentShot(object, client),
    ].take(newShotCount).toList();
    cubit.emit(
      cubit.state.copyWith(
        detected: shots.length,
        uploaded: shots.length - 1,
        pending: 1,
        recent: shots,
      ),
    );
    await tester.pump();
    await precacheImages(tester);
    await capture(tester, 'auto_upload');
    await leaveMode(tester);
  }, variant: platform);
}
