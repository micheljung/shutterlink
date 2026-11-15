import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
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
import 'package:shutterlink/feature/preview/preview_screen.dart';
import 'package:shutterlink/feature/sessions/sessions_upload_cubit.dart';
import 'package:shutterlink/feature/settings/sessions_setup_screen.dart';
import 'package:shutterlink/feature/settings/settings_cubit.dart';
import 'package:shutterlink/feature/settings/upload_settings_cubit.dart';
import 'package:shutterlink/feature/settings/upload_setup_screen.dart';
import 'package:shutterlink/feature/upload/upload_status_cubit.dart';
import 'package:shutterlink/feature/upload/upload_status_indicator.dart';
import 'package:shutterlink/feature/upload/upload_status_sheet.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/backend_factory.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/provider_preset.dart';
import 'package:shutterlink/usb/usb_camera_platform.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_usb_camera_watcher.dart';
import '../../fakes/test_app.dart';
import '../live/live_transfer_cubit_test.dart' show unreachable;

const _pollInterval = Duration(milliseconds: 5);
const _maxPolls = 2000;

const _destination = Destination(
  type: DestinationType.webdav,
  endpoint: 'https://dav.example.com',
);

class _MockUploadSettingsCubit extends MockCubit<UploadSettingsState>
    implements UploadSettingsCubit {}

class _MockUploadStatusCubit extends MockCubit<UploadStatusState>
    implements UploadStatusCubit {}

class _MockSessionsUploadCubit extends MockCubit<SessionsUploadState>
    implements SessionsUploadCubit {}

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
    expect(home(tester).read<ModeCubit>().state, isNull);
  });

  group('setup gates', () {
    Future<AppDependencies> pumpPicker(WidgetTester tester) async {
      answers.add(FakeCameraClient(photos(1)));
      final dependencies = await pumpApp(tester);
      await tester.tap(connectScreenButton);
      await tester.pumpAndSettle();
      return dependencies;
    }

    Future<void> back(WidgetTester tester) async {
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
    }

    testWidgets('Auto Upload asks for a destination, and backing out stays '
        'on the picker', (tester) async {
      await pumpPicker(tester);

      await pick(tester, OperatingMode.autoUpload);
      expect(find.byType(UploadSetupScreen), findsOneWidget);
      await back(tester);

      expect(find.byType(ModePickerScreen), findsOneWidget);
      expect(home(tester).read<ModeCubit>().state, isNull);
    });

    testWidgets('Auto Upload is entered once the destination is set up', (
      tester,
    ) async {
      await pumpPicker(tester);
      await pick(tester, OperatingMode.autoUpload);

      final uploads = home(tester).read<UploadSettingsCubit>();
      await tester.runAsync(
        () => uploads.save(
          _destination,
          const DestinationSecrets(password: 'secret'),
          preset: ProviderPreset.custom,
        ),
      );
      await back(tester);

      expect(find.byType(ModePlaceholderScreen), findsOneWidget);
      expect(find.text(OperatingMode.autoUpload.label), findsOneWidget);
      await tester.tap(find.byTooltip(ModesButton.tooltip));
      await tester.pumpAndSettle();
      expect(find.byType(ModePickerScreen), findsOneWidget);
    });

    testWidgets('Auto Upload with a destination opens no setup', (
      tester,
    ) async {
      final dependencies = await pumpPicker(tester);
      final uploads = home(tester).read<UploadSettingsCubit>();
      await tester.runAsync(
        () => uploads.save(
          _destination,
          const DestinationSecrets(password: 'secret'),
          preset: ProviderPreset.custom,
        ),
      );
      expect(dependencies.destinations.destination, isNotNull);

      await pick(tester, OperatingMode.autoUpload);

      expect(find.byType(UploadSetupScreen), findsNothing);
      expect(find.byType(ModePlaceholderScreen), findsOneWidget);
    });

    testWidgets('QR Session asks for the Sessions server, and backing out '
        'stays on the picker', (tester) async {
      await pumpPicker(tester);

      await pick(tester, OperatingMode.qrSession);
      expect(find.byType(SessionsSetupScreen), findsOneWidget);
      await back(tester);

      expect(find.byType(ModePickerScreen), findsOneWidget);
      expect(home(tester).read<ModeCubit>().state, isNull);
    });

    testWidgets('QR Session is entered once the server is set up', (
      tester,
    ) async {
      await pumpPicker(tester);
      await pick(tester, OperatingMode.qrSession);

      final settings = home(tester).read<SettingsCubit>();
      await tester.runAsync(() async {
        await settings.setSessionsServerUrl('https://photos.example.com');
        await settings.setSessionsToken('token');
        await settings.setSessionsEnabled(true);
      });
      expect(settings.state.sessionsConfigured, isTrue);
      await back(tester);

      expect(find.byType(ModePlaceholderScreen), findsOneWidget);
      expect(find.text(OperatingMode.qrSession.label), findsOneWidget);
    });
  });

  group('the upload indicator', () {
    late _MockUploadSettingsCubit uploadSettings;
    late _MockUploadStatusCubit uploads;
    late _MockSessionsUploadCubit sessions;

    setUp(() {
      uploadSettings = _MockUploadSettingsCubit();
      uploads = _MockUploadStatusCubit();
      sessions = _MockSessionsUploadCubit();
    });

    Future<void> pumpIndicator(
      WidgetTester tester, {
      bool destination = false,
      int pending = 0,
      int sessionsPending = 0,
    }) async {
      when(() => uploadSettings.state).thenReturn(
        UploadSettingsState(destination: destination ? _destination : null),
      );
      when(() => uploads.state).thenReturn(UploadStatusState(pending: pending));
      when(() => sessions.state)
          .thenReturn(SessionsUploadState(pending: sessionsPending));
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<UploadSettingsCubit>.value(value: uploadSettings),
            BlocProvider<UploadStatusCubit>.value(value: uploads),
            BlocProvider<SessionsUploadCubit>.value(value: sessions),
          ],
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(actions: const [UploadStatusIndicator()]),
            ),
          ),
        ),
      );
    }

    final indicator = find.byTooltip(UploadStatusIndicator.tooltip);

    IconButton button(WidgetTester tester) =>
        tester.widget<IconButton>(find.byType(IconButton));

    testWidgets('is hidden with no destination and nothing pending', (
      tester,
    ) async {
      await pumpIndicator(tester);

      expect(indicator, findsNothing);
    });

    testWidgets('is plain with a destination and opens the sheet', (
      tester,
    ) async {
      await pumpIndicator(tester, destination: true);

      expect(indicator, findsOneWidget);
      expect(button(tester).isSelected, isFalse);
      expect(find.byType(Badge), findsNothing);
      await tester.tap(indicator);
      await tester.pumpAndSettle();
      expect(find.byType(UploadStatusSheet), findsOneWidget);
    });

    testWidgets('stands out while the destination queue has photos left', (
      tester,
    ) async {
      await pumpIndicator(tester, pending: 2);

      expect(button(tester).isSelected, isTrue);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('stands out while the Sessions queue has photos left', (
      tester,
    ) async {
      await pumpIndicator(tester, sessionsPending: 3);

      expect(button(tester).isSelected, isTrue);
      expect(find.text('3'), findsOneWidget);
      await tester.tap(indicator);
      await tester.pumpAndSettle();
      expect(find.text(UploadStatusSheet.sessionsTitle), findsOneWidget);
      expect(find.text(UploadStatusSheet.sessionsText(3)), findsOneWidget);
    });
  });

  testWidgets('the indicator shows in the picker and in Browse', (
    tester,
  ) async {
    answers.add(FakeCameraClient(photos(1)));
    await pumpApp(tester);
    await tester.tap(connectScreenButton);
    await tester.pumpAndSettle();
    expect(find.byTooltip(UploadStatusIndicator.tooltip), findsNothing);

    final uploads = home(tester).read<UploadSettingsCubit>();
    await tester.runAsync(
      () => uploads.save(
        _destination,
        const DestinationSecrets(password: 'secret'),
        preset: ProviderPreset.custom,
      ),
    );
    await tester.pump();
    expect(find.byTooltip(UploadStatusIndicator.tooltip), findsOneWidget);

    await pick(tester, OperatingMode.browse);
    expect(find.byTooltip(UploadStatusIndicator.tooltip), findsOneWidget);
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

  testWidgets('a drop closes a preview, so the overlay and its Abort show', (
    tester,
  ) async {
    final dead = FakeCameraClient(photos(3));
    answers.addAll([dead, unreachable]);
    await pumpApp(tester);
    await connectAndBrowse(tester);
    await tester.tap(find.bySemanticsLabel('Preview').first);
    await tester.pumpAndSettle();
    expect(find.byType(PreviewScreen), findsOneWidget);

    dead.simulateDisconnect();
    await tester.pumpAndSettle();
    final asked = dead.thumbnailRequests.length;

    expect(find.byType(PreviewScreen), findsNothing);
    expect(overlay, findsOneWidget);
    await tester.pumpAndSettle();
    expect(dead.thumbnailRequests, hasLength(asked));

    await tester.tap(find.text(ReconnectingOverlay.abortLabel));
    await tester.pumpAndSettle();
    expect(connectScreenButton, findsOneWidget);
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
    final askedDead = {
      for (final MapEntry(:key, :value) in first.requestedOffsets.entries)
        key: [...value],
    };

    await tester.pump(retryDelay);
    await pumpUntil(
      tester,
      () => download.state.status == DownloadStatus.completed,
    );

    expect(second.requestedOffsets, isNotEmpty);
    expect(first.requestedOffsets, askedDead);
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
