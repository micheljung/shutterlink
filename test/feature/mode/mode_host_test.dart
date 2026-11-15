import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connection_supervisor.dart';
import 'package:shutterlink/feature/download/download_cubit.dart';
import 'package:shutterlink/feature/download/download_state.dart';
import 'package:shutterlink/feature/gallery/gallery_screen.dart';
import 'package:shutterlink/feature/gallery/thumbnail_tile.dart';
import 'package:shutterlink/feature/mode/mode_cubit.dart';
import 'package:shutterlink/feature/mode/mode_picker_screen.dart';
import 'package:shutterlink/feature/mode/mode_placeholder_screen.dart';
import 'package:shutterlink/feature/mode/modes_button.dart';
import 'package:shutterlink/feature/mode/operating_mode.dart';
import 'package:shutterlink/feature/mode/reconnecting_overlay.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/usb/usb_camera_platform.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_usb_camera_watcher.dart';
import '../../fakes/test_app.dart';
import '../live/live_transfer_cubit_test.dart' show unreachable;

const _pollInterval = Duration(milliseconds: 5);
const _maxPolls = 2000;

void main() {
  final retryDelay = ConnectionSupervisor.initialReconnectDelay;
  final connectScreenButton = find.text('Connect');
  final overlay = find.byType(ReconnectingOverlay);

  late List<Object> answers;
  late List<ConnectTarget> targets;

  setUp(() {
    answers = [];
    targets = [];
  });

  Future<CameraClient> connector(ConnectTarget target) async {
    targets.add(target);
    final next = answers.removeAt(0);
    if (next is Exception) throw next;
    return next as CameraClient;
  }

  List<CameraObject> photos(int count) => [
    for (var i = 1; i <= count; i++)
      cameraObject(i, 'IMG_${i.toString().padLeft(4, '0')}.JPG'),
  ];

  Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < _maxPolls && !condition(); i++) {
      await tester.runAsync(() => Future<void>.delayed(_pollInterval));
      await tester.pump();
    }
    expect(condition(), isTrue);
  }

  Future<AppDependencies> pumpApp(
    WidgetTester tester, {
    UsbCameraPlatform usb = const NoUsbCameraPlatform(),
  }) async {
    final dependencies = await testDependencies(
      connector,
      usb: usb,
      claimsUsbVendor: claimsCanonOnly,
    );
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    return dependencies;
  }

  Future<void> pick(WidgetTester tester, OperatingMode mode) async {
    await tester.tap(find.text(mode.label));
    await tester.pumpAndSettle();
  }

  BuildContext home(WidgetTester tester) =>
      tester.element(find.byType(Navigator).first);

  testWidgets('a connect shows the picker with all three modes', (
    tester,
  ) async {
    answers.add(FakeCameraClient(photos(1)));
    await pumpApp(tester);

    await tester.tap(connectScreenButton);
    await tester.pumpAndSettle();

    expect(find.byType(ModePickerScreen), findsOneWidget);
    for (final mode in OperatingMode.values) {
      expect(find.text(mode.label), findsOneWidget);
    }
    expect(find.byType(GalleryScreen), findsNothing);
  });

  testWidgets('each mode leads back to the picker', (tester) async {
    answers.add(FakeCameraClient(photos(1)));
    await pumpApp(tester);
    await connectAndBrowse(tester);
    expect(find.byType(GalleryScreen), findsOneWidget);

    await tester.tap(find.byTooltip(ModesButton.tooltip));
    await tester.pumpAndSettle();
    expect(find.byType(ModePickerScreen), findsOneWidget);

    await pick(tester, OperatingMode.qrSession);
    expect(find.byType(ModePlaceholderScreen), findsOneWidget);
    await tester.tap(find.byTooltip(ModesButton.tooltip));
    await tester.pumpAndSettle();
    expect(find.byType(ModePickerScreen), findsOneWidget);
  });

  testWidgets('a drop on the picker shows the overlay too', (tester) async {
    final client = FakeCameraClient(photos(1));
    answers.add(client);
    await pumpApp(tester);
    await tester.tap(connectScreenButton);
    await tester.pumpAndSettle();

    client.simulateDisconnect();
    await tester.pumpAndSettle();

    expect(overlay, findsOneWidget);
    expect(find.byType(ModePickerScreen), findsOneWidget);
    await tester.tap(find.text(ReconnectingOverlay.abortLabel));
    await tester.pumpAndSettle();
  });

  testWidgets('Browse stays under the overlay and leaves the dead client '
      'alone', (tester) async {
    final dead = FakeCameraClient(photos(60));
    answers.addAll([dead, unreachable]);
    await pumpApp(tester);
    await connectAndBrowse(tester);
    final asked = dead.thumbnailRequests.length;
    expect(asked, greaterThan(0));

    dead.simulateDisconnect();
    await tester.pumpAndSettle();
    expect(overlay, findsOneWidget);
    expect(find.text(ReconnectingOverlay.reconnectingText), findsOneWidget);
    expect(find.byType(GalleryScreen), findsOneWidget);

    // New tiles come into view, but must not ask the dead client.
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byType(ThumbnailTile), findsWidgets);
    expect(dead.thumbnailRequests, hasLength(asked));

    await tester.tap(find.byType(ThumbnailTile).first, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsNothing);

    await tester.tap(find.text(ReconnectingOverlay.abortLabel));
    await tester.pumpAndSettle();
  });

  testWidgets('a reconnect hides the overlay and keeps Browse', (tester) async {
    final first = FakeCameraClient(photos(1));
    final second = FakeCameraClient(photos(2));
    answers.addAll([first, second]);
    await pumpApp(tester);
    await connectAndBrowse(tester);

    first.simulateDisconnect();
    await tester.pump();
    await tester.pump();
    expect(overlay, findsOneWidget);
    await tester.pump(retryDelay);
    await tester.pumpAndSettle();

    expect(overlay, findsNothing);
    expect(find.text('Photos (2)'), findsOneWidget);
    expect(second.thumbnailRequests, isNotEmpty);
  });

  testWidgets('a paused download resumes on the new client', (tester) async {
    final first = FakeCameraClient(photos(2), disconnectAfterChunks: 1);
    final second = FakeCameraClient(photos(2));
    answers.addAll([first, second]);
    final dependencies = await pumpApp(tester);
    await connectAndBrowse(tester);
    final download = tester
        .element(find.byType(GalleryScreen))
        .read<DownloadCubit>();

    await tester.tap(find.byTooltip('Select all'));
    await tester.pump();
    await tester.tap(find.text('Download (2)'));
    await pumpUntil(
      tester,
      () => download.state.status == DownloadStatus.paused,
    );
    expect(overlay, findsOneWidget);
    expect(second.requestedOffsets, isEmpty);

    await tester.pump(retryDelay);
    await pumpUntil(
      tester,
      () => download.state.status == DownloadStatus.completed,
    );

    expect(second.requestedOffsets, isNotEmpty);
    final saver = dependencies.photoSaver as RecordingPhotoSaver;
    expect(saver.saved, hasLength(2));
  });

  testWidgets('Abort after the camera came back shows the picker', (
    tester,
  ) async {
    final first = FakeCameraClient(photos(1));
    answers.addAll([first, FakeCameraClient(photos(1))]);
    await pumpApp(tester);
    await connectAndBrowse(tester);
    first.simulateDisconnect();
    await tester.pump();
    await tester.pump();
    expect(overlay, findsOneWidget);
    await tester.pump(retryDelay);
    await tester.pump();
    expect(overlay, findsNothing);

    // The tap raced the reconnect.
    ReconnectingOverlay.abort(home(tester));
    await tester.pumpAndSettle();

    expect(find.byType(ModePickerScreen), findsOneWidget);
    expect(connectScreenButton, findsNothing);
  });

  testWidgets('Disconnect from Browse shows the connect screen for good', (
    tester,
  ) async {
    answers.add(FakeCameraClient(photos(1)));
    await pumpApp(tester);
    await connectAndBrowse(tester);

    await tester.tap(find.byTooltip('Disconnect'));
    await tester.pumpAndSettle();
    await tester.pump(retryDelay * 4);

    expect(connectScreenButton, findsOneWidget);
    expect(overlay, findsNothing);
    expect(targets, hasLength(1));
  });

  testWidgets('a fresh connect after a disconnect shows the picker again', (
    tester,
  ) async {
    answers.addAll([FakeCameraClient(photos(1)), FakeCameraClient(photos(1))]);
    await pumpApp(tester);
    await connectAndBrowse(tester);
    await tester.tap(find.byTooltip('Disconnect'));
    await tester.pumpAndSettle();

    await tester.tap(connectScreenButton);
    await tester.pumpAndSettle();

    expect(find.byType(ModePickerScreen), findsOneWidget);
    expect(home(tester).read<ModeCubit>().state, isNull);
  });

  testWidgets('leaving Browse lets a download finish', (tester) async {
    final client = FakeCameraClient(photos(2))..chunkGate = Completer<void>();
    answers.add(client);
    await pumpApp(tester);
    await connectAndBrowse(tester);
    final download = tester
        .element(find.byType(GalleryScreen))
        .read<DownloadCubit>();
    await tester.tap(find.byTooltip('Select all'));
    await tester.pump();
    await tester.tap(find.text('Download (2)'));
    await pumpUntil(tester, () => client.requestedOffsets.isNotEmpty);
    // Dismiss the download sheet, then go back to the picker.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(ModesButton.tooltip));
    await tester.pumpAndSettle();
    expect(find.byType(ModePickerScreen), findsOneWidget);
    client.chunkGate!.complete();
    client.chunkGate = null;

    await pumpUntil(
      tester,
      () => download.state.status == DownloadStatus.completed,
    );
  });

  group('over USB', () {
    late FakeUsbCameraWatcher watcher;
    final canon = usbCamera();

    setUp(() => watcher = FakeUsbCameraWatcher()..permitted.add(canon));

    testWidgets('the app lets go of the cable in the background only without '
        'a camera', (tester) async {
      answers.add(FakeCameraClient(photos(1)));
      await pumpApp(tester, usb: FakeUsbCameraPlatform(watcher));
      void background() {
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
      }

      void foreground() {
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
      }

      background();
      expect(watcher.owners, isEmpty);
      foreground();
      expect(watcher.owners, {ConnectCubit.usbWatchOwner, 'connect'});

      await connectAndBrowse(tester);
      background();
      expect(watcher.owners, {ConnectCubit.usbWatchOwner});
      foreground();
    });

    testWidgets('a cable takeover keeps Browse, with no picker or connect '
        'screen', (tester) async {
      final wifi = FakeCameraClient(photos(1));
      final usb = FakeCameraClient(photos(3));
      answers.addAll([wifi, usb]);
      await pumpApp(tester, usb: FakeUsbCameraPlatform(watcher));
      await connectAndBrowse(tester);
      var sawOtherScreen = false;
      void check() {
        if (find.byType(ModePickerScreen).evaluate().isNotEmpty ||
            connectScreenButton.evaluate().isNotEmpty) {
          sawOtherScreen = true;
        }
      }

      watcher.attach(canon);
      await tester.pump();
      check();
      await tester.pumpAndSettle();
      check();

      expect(sawOtherScreen, isFalse);
      expect(wifi.closed, isTrue);
      expect(targets.last, isA<UsbTarget>());
      expect(find.text('Photos (3)'), findsOneWidget);
    });

    testWidgets('the overlay asks for USB access when the user must act', (
      tester,
    ) async {
      final first = FakeCameraClient(photos(1));
      final second = FakeCameraClient(photos(2));
      answers.addAll([first, second]);
      await pumpApp(tester, usb: FakeUsbCameraPlatform(watcher));
      watcher.attach(canon);
      await tester.pumpAndSettle();
      await pick(tester, OperatingMode.browse);

      first.simulateDisconnect();
      watcher.detach(canon);
      await tester.pump();
      watcher
        ..permissionAnswers.add(UsbPermission.userActionNeeded)
        ..attach(canon);
      await tester.pumpAndSettle();
      expect(find.text(ReconnectingOverlay.userActionText), findsOneWidget);

      await tester.tap(find.text(ReconnectingOverlay.allowUsbLabel));
      await tester.pumpAndSettle();

      expect(watcher.permissionRequests, [canon, canon]);
      expect(overlay, findsNothing);
      expect(find.text('Photos (2)'), findsOneWidget);
    });
  });
}
