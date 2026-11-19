@Tags(['screenshots'])
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/auto_upload/auto_upload_cubit.dart';
import 'package:shutterlink/feature/auto_upload/auto_upload_screen.dart';
import 'package:shutterlink/feature/connect/connect_screen.dart';
import 'package:shutterlink/feature/gallery/thumbnail_tile.dart';
import 'package:shutterlink/feature/mode/operating_mode.dart';
import 'package:shutterlink/feature/sessions/clock_sync_banner.dart';
import 'package:shutterlink/feature/sessions/session_qr_sheet.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

import 'screenshot_harness.dart';

/// Writes numbered frames of a tour through the app to SCREENSHOTS_DIR;
/// tool/render_store_assets.sh turns them into the demo GIF and videos.
void main() {
  setUpAll(() async {
    WidgetsApp.debugAllowBannerOverride = false;
    await loadFonts();
  });
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  testWidgets('demo reel', (tester) async {
    var frame = 0;
    Future<void> shoot() =>
        capture(tester, 'frame_${(++frame).toString().padLeft(2, '0')}');

    final client = ScreenshotCameraClient()..cameraLag = Duration.zero;
    await pumpApp(
      tester,
      client,
      downloaded: photos.skip(newestDayCount).map((photo) => photo.$1),
      configured: true,
      startUploadQueue: true,
    );
    await shoot();

    await tester.tap(find.text(ConnectScreen.connectLabel));
    await tester.pumpAndSettle();
    await shoot();

    await tester.tap(find.text(OperatingMode.browse.label));
    await tester.pumpAndSettle();
    await precacheImages(tester);
    await shoot();

    final tiles = find.byType(ThumbnailTile);
    final gesture = await tester.startGesture(tester.getCenter(tiles.at(0)));
    await tester.pump(kLongPressTimeout);
    for (final index in [1, 2, 3]) {
      await gesture.moveTo(tester.getCenter(tiles.at(index)));
      await tester.pumpAndSettle();
      await shoot();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    await tester.tap(tiles.at(1));
    await tester.pumpAndSettle();
    await precacheImages(tester);
    await shoot();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await leaveMode(tester);

    await pickMode(tester, OperatingMode.liveShare);
    await pumpUntilFound(tester, find.byType(SessionQrImage));
    await pumpUntilFound(tester, find.text(ClockSyncBanner.inSyncHint));
    await shoot();
    await leaveMode(tester);

    await pickMode(tester, OperatingMode.autoUpload);
    await pumpUntilFound(tester, find.text(AutoUploadScreen.skipBacklogLabel));
    await tester.tap(find.text(AutoUploadScreen.skipBacklogLabel));
    await tester.pump();
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
    await shoot();
    await leaveMode(tester);
  }, variant: platform);
}

Future<void> pickMode(WidgetTester tester, OperatingMode mode) async {
  await tester.ensureVisible(find.text(mode.label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(mode.label));
}
