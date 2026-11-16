import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/auto_upload/auto_upload_cubit.dart';
import 'package:shutterlink/feature/auto_upload/auto_upload_screen.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connect_screen.dart';
import 'package:shutterlink/feature/connect/connect_state.dart';
import 'package:shutterlink/feature/gallery/thumbnail_cache.dart';
import 'package:shutterlink/feature/gallery/thumbnail_tile.dart';
import 'package:shutterlink/feature/mode/attached_client.dart';
import 'package:shutterlink/feature/mode/mode_cubit.dart';
import 'package:shutterlink/feature/mode/modes_button.dart';
import 'package:shutterlink/feature/mode/operating_mode.dart';
import 'package:shutterlink/feature/sessions/sessions_upload_cubit.dart';
import 'package:shutterlink/feature/settings/upload_settings_cubit.dart';
import 'package:shutterlink/feature/upload/upload_status_cubit.dart';
import 'package:shutterlink/feature/upload/upload_status_indicator.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/backend_factory.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/provider_preset.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/spy_sessions_dependencies.dart';
import '../../fakes/test_app.dart';
import '../sessions/sessions_app_test.dart' show pumpUntil;

class _MockAutoUploadCubit extends MockCubit<AutoUploadState>
    implements AutoUploadCubit {}

class _MockConnectCubit extends MockCubit<ConnectState>
    implements ConnectCubit {}

class _MockUploadSettingsCubit extends MockCubit<UploadSettingsState>
    implements UploadSettingsCubit {}

class _MockUploadStatusCubit extends MockCubit<UploadStatusState>
    implements UploadStatusCubit {}

class _MockSessionsUploadCubit extends MockCubit<SessionsUploadState>
    implements SessionsUploadCubit {}

const _destination = Destination(
  type: DestinationType.webdav,
  endpoint: 'https://dav.example.com/remote.php',
);

void main() {
  late _MockAutoUploadCubit cubit;
  late _MockConnectCubit connect;
  late FakeCameraClient client;
  late MemoryThumbnailCache cache;

  setUp(() {
    cubit = _MockAutoUploadCubit();
    connect = _MockConnectCubit();
    client = FakeCameraClient([]);
    cache = MemoryThumbnailCache();
    when(() => connect.state).thenReturn(ConnectConnected(client));
  });

  Future<void> pump(
    WidgetTester tester,
    AutoUploadState state, {
    CameraClient? attached,
  }) async {
    when(() => cubit.state).thenReturn(state);
    final uploadSettings = _MockUploadSettingsCubit();
    when(() => uploadSettings.state)
        .thenReturn(const UploadSettingsState(destination: _destination));
    final uploads = _MockUploadStatusCubit();
    when(() => uploads.state).thenReturn(const UploadStatusState());
    final sessions = _MockSessionsUploadCubit();
    when(() => sessions.state).thenReturn(const SessionsUploadState());
    await tester.pumpWidget(
      RepositoryProvider<ThumbnailCache>.value(
        value: cache,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AutoUploadCubit>.value(value: cubit),
            BlocProvider<ConnectCubit>.value(value: connect),
            BlocProvider<UploadSettingsCubit>.value(value: uploadSettings),
            BlocProvider<UploadStatusCubit>.value(value: uploads),
            BlocProvider<SessionsUploadCubit>.value(value: sessions),
            BlocProvider(create: (_) => ModeCubit()),
          ],
          child: MaterialApp(
            home: AttachedClient(
              client: attached ?? client,
              child: const AutoUploadScreen(),
            ),
          ),
        ),
      ),
    );
  }

  Finder counter(String label, int value) =>
      find.bySemanticsLabel('$label: $value');

  testWidgets('shows the counters, the destination and the camera, and no '
      'card', (tester) async {
    await pump(
      tester,
      const AutoUploadState(
        phase: AutoUploadPhase.running,
        detected: 5,
        uploaded: 3,
        pending: 2,
        failed: 1,
      ),
    );

    expect(counter(AutoUploadScreen.detectedLabel, 5), findsOneWidget);
    expect(counter(AutoUploadScreen.uploadedLabel, 3), findsOneWidget);
    expect(counter(AutoUploadScreen.pendingLabel, 2), findsOneWidget);
    expect(counter(AutoUploadScreen.failedLabel, 1), findsOneWidget);
    expect(find.text('WebDAV server'), findsOneWidget);
    expect(find.text('dav.example.com'), findsOneWidget);
    expect(find.text(AutoUploadScreen.waitingText), findsOneWidget);
    expect(find.text(client.deviceInfo.model), findsOneWidget);
    expect(find.text(AutoUploadScreen.noShotsText), findsOneWidget);
    expect(find.byType(ThumbnailTile), findsNothing);
    expect(find.byType(GridView), findsNothing);
    expect(find.byTooltip(UploadStatusIndicator.tooltip), findsOneWidget);
  });

  testWidgets('says when it is reading the card', (tester) async {
    await pump(tester, const AutoUploadState(phase: AutoUploadPhase.starting));

    expect(find.text(AutoUploadScreen.readingText), findsOneWidget);
  });

  testWidgets('says when the camera reconnects', (tester) async {
    when(() => connect.state).thenReturn(const ConnectReconnecting());

    await pump(tester, const AutoUploadState(phase: AutoUploadPhase.running));

    expect(find.text(AutoUploadScreen.reconnectingText), findsOneWidget);
  });

  testWidgets('asks about the photos already on the card', (tester) async {
    await pump(
      tester,
      const AutoUploadState(phase: AutoUploadPhase.running, backlog: 3),
    );
    expect(find.text('Also upload the 3 existing photos?'), findsOneWidget);

    await tester.tap(find.text(AutoUploadScreen.uploadBacklogLabel));
    verify(() => cubit.uploadBacklog(upload: true)).called(1);
    await tester.tap(find.text(AutoUploadScreen.skipBacklogLabel));
    verify(() => cubit.uploadBacklog(upload: false)).called(1);
  });

  testWidgets('asks nothing without a backlog', (tester) async {
    await pump(tester, const AutoUploadState(phase: AutoUploadPhase.running));

    expect(find.text(AutoUploadScreen.uploadBacklogLabel), findsNothing);
  });

  testWidgets('tells iPhone users to keep the app open', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await pump(tester, const AutoUploadState(phase: AutoUploadPhase.running));
    final onIos = find.text(AutoUploadScreen.keepOpenText).evaluate().length;

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pump(tester, const AutoUploadState(phase: AutoUploadPhase.running));
    final onAndroid = find
        .text(AutoUploadScreen.keepOpenText)
        .evaluate()
        .length;
    debugDefaultTargetPlatformOverride = null;

    expect(onIos, 1);
    expect(onAndroid, 0);
  });

  testWidgets('says when notifications are off', (tester) async {
    await pump(
      tester,
      const AutoUploadState(
        phase: AutoUploadPhase.running,
        notificationsDenied: true,
      ),
    );

    expect(find.text(AutoUploadScreen.notificationsHint), findsOneWidget);
  });

  testWidgets('recent shots ask only the attached client for thumbnails', (
    tester,
  ) async {
    final dead = FakeCameraClient([]);
    final fresh = cameraObject(2, 'IMG_0002.JPG');
    final old = cameraObject(1, 'IMG_0001.JPG');
    await pump(
      tester,
      AutoUploadState(
        phase: AutoUploadPhase.running,
        detected: 2,
        recent: [RecentShot(fresh, client), RecentShot(old, dead)],
      ),
    );
    await tester.pump();

    expect(find.bySemanticsLabel('IMG_0002.JPG'), findsOneWidget);
    expect(find.bySemanticsLabel('IMG_0001.JPG'), findsOneWidget);
    expect(client.thumbnailRequests, [fresh.handle]);
    expect(dead.thumbnailRequests, isEmpty);
  });

  testWidgets('AC14: with a Session open, nothing collects for Sessions', (
    tester,
  ) async {
    late SpySessionsDependencies sessions;
    final camera = FakeCameraClient([
      cameraObject(1, 'IMG_0001.JPG', captureDate: DateTime.now()),
    ]);
    final dependencies = await testDependencies(
      (_) async => camera,
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
    await tester.runAsync(() async {
      await sessions.repository.start();
      await dependencies.uploadQueue.start();
    });
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await tester.pump();
    final home = tester.element(find.byType(Navigator).first);
    await tester.runAsync(
      () => home.read<UploadSettingsCubit>().save(
        _destination,
        const DestinationSecrets(password: 'secret'),
        preset: ProviderPreset.custom,
      ),
    );
    await tester.tap(find.text(ConnectScreen.connectLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text(OperatingMode.autoUpload.label));
    final autoUpload = home.read<AutoUploadCubit>();
    await pumpUntil(
      tester,
      () => autoUpload.state.phase == AutoUploadPhase.running,
    );

    expect(find.text('Also upload the 1 existing photo?'), findsOneWidget);
    expect(sessions.collectors, 0);
    expect(sessions.clockSyncs, 0);
    expect(await tester.runAsync(sessions.queue.items), isEmpty);
    await tester.tap(find.byTooltip(ModesButton.tooltip));
    await tester.pumpAndSettle();
  });
}
