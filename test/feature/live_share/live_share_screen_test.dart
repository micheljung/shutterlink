import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/live_share/live_share_cubit.dart';
import 'package:shutterlink/feature/live_share/live_share_screen.dart';
import 'package:shutterlink/feature/mode/mode_cubit.dart';
import 'package:shutterlink/feature/mode/operating_mode.dart';
import 'package:shutterlink/feature/sessions/clock_sync_banner.dart';
import 'package:shutterlink/feature/sessions/clock_sync_cubit.dart';
import 'package:shutterlink/feature/sessions/clock_sync_state.dart';
import 'package:shutterlink/feature/sessions/session.dart';
import 'package:shutterlink/feature/sessions/session_qr_sheet.dart';
import 'package:shutterlink/feature/sessions/sessions_cubit.dart';
import 'package:shutterlink/feature/sessions/sessions_state.dart';
import 'package:shutterlink/feature/sessions/sessions_upload_cubit.dart';
import 'package:shutterlink/feature/settings/settings_cubit.dart';
import 'package:shutterlink/feature/settings/upload_settings_cubit.dart';
import 'package:shutterlink/feature/upload/upload_status_cubit.dart';
import 'package:shutterlink/feature/upload/upload_status_indicator.dart';

import '../../fakes/fake_camera_client.dart';

class _MockLiveShareCubit extends MockCubit<LiveShareState>
    implements LiveShareCubit {}

class _MockSessionsCubit extends MockCubit<SessionsState>
    implements SessionsCubit {}

class _MockSettingsCubit extends MockCubit<SettingsState>
    implements SettingsCubit {}

class _MockClockSyncCubit extends MockCubit<ClockState>
    implements ClockSyncCubit {}

class _MockUploadSettingsCubit extends MockCubit<UploadSettingsState>
    implements UploadSettingsCubit {}

class _MockUploadStatusCubit extends MockCubit<UploadStatusState>
    implements UploadStatusCubit {}

class _MockSessionsUploadCubit extends MockCubit<SessionsUploadState>
    implements SessionsUploadCubit {}

const _serverUrl = 'https://photos.example.com';

void main() {
  final createdAt = DateTime.utc(2026, 11, 13, 10);
  final open = Session(
    id: 'open',
    code: 'apple-banana-cherry-delta',
    createdAt: createdAt,
    intervals: [ActivityInterval(createdAt)],
  );
  final closed = Session(
    id: 'closed',
    code: 'echo-fox-golf-hotel',
    createdAt: createdAt,
    intervals: [ActivityInterval(createdAt, createdAt.add(Duration(hours: 1)))],
  );

  late _MockLiveShareCubit liveShare;
  late _MockSessionsCubit sessions;
  late _MockSettingsCubit settings;
  late ModeCubit modes;

  setUp(() {
    liveShare = _MockLiveShareCubit();
    sessions = _MockSessionsCubit();
    settings = _MockSettingsCubit();
    modes = ModeCubit()..select(OperatingMode.liveShare);
    when(() => settings.state).thenReturn(
      const SettingsState(
        format: DownloadFormat.jpeg,
        sessionsServerUrl: _serverUrl,
        sessionsConfigured: true,
      ),
    );
    when(() => liveShare.state).thenReturn(const LiveShareState(active: true));
    when(() => liveShare.resume()).thenAnswer((_) async {});
    when(() => liveShare.startNew()).thenAnswer((_) async {});
    when(() => sessions.canReactivate(any())).thenReturn(true);
    when(() => sessions.stop()).thenAnswer((_) async {});
    when(() => sessions.start()).thenAnswer((_) async => open);
    when(() => sessions.reactivate(any())).thenAnswer((_) async => closed);
    when(() => sessions.markNow()).thenAnswer((_) async {});
  });

  setUpAll(() => registerFallbackValue(closed));

  tearDown(() => modes.close());

  Future<void> pumpScreen(
    WidgetTester tester, {
    int sessionsPending = 0,
  }) async {
    final uploadSettings = _MockUploadSettingsCubit();
    final uploads = _MockUploadStatusCubit();
    final sessionsUploads = _MockSessionsUploadCubit();
    when(() => uploadSettings.state).thenReturn(const UploadSettingsState());
    when(() => uploads.state).thenReturn(const UploadStatusState());
    when(() => sessionsUploads.state)
        .thenReturn(SessionsUploadState(pending: sessionsPending));
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<LiveShareCubit>.value(value: liveShare),
          BlocProvider<SessionsCubit>.value(value: sessions),
          BlocProvider<SettingsCubit>.value(value: settings),
          BlocProvider<ModeCubit>.value(value: modes),
          BlocProvider<UploadSettingsCubit>.value(value: uploadSettings),
          BlocProvider<UploadStatusCubit>.value(value: uploads),
          BlocProvider<SessionsUploadCubit>.value(value: sessionsUploads),
        ],
        child: const MaterialApp(home: LiveShareScreen()),
      ),
    );
  }

  testWidgets('a mangled server URL shows no QR code', (tester) async {
    when(() => settings.state).thenReturn(
      const SettingsState(
        format: DownloadFormat.jpeg,
        sessionsServerUrl:
            'https://photos.examphttps://photos.example.comtesttoken123 e.com',
        sessionsConfigured: true,
      ),
    );
    when(() => sessions.state)
        .thenReturn(SessionsState(loaded: true, sessions: [open]));
    await pumpScreen(tester);

    expect(find.byType(SessionQrImage), findsNothing);
    expect(find.text(LiveShareScreen.stopLabel), findsOneWidget);
  });

  testWidgets('an open window shows its QR code and code, and Stop closes '
      'it (AC15)', (tester) async {
    when(() => sessions.state)
        .thenReturn(SessionsState(loaded: true, sessions: [open]));
    await pumpScreen(tester);

    expect(find.byType(PrettyQrView), findsOneWidget);
    expect(
      find.text(sessionPageUrl(_serverUrl, open.code).toString()),
      findsOneWidget,
    );
    expect(find.byType(SessionUrlField), findsOneWidget);
    expect(find.byType(SessionOpenButton), findsOneWidget);
    expect(find.text(open.code), findsOneWidget);
    expect(find.text(LiveShareScreen.openTitle), findsOneWidget);

    await tester.tap(find.byType(PrettyQrView));
    await tester.pumpAndSettle();
    expect(find.byType(SessionQrSheet), findsNothing);

    await tester.ensureVisible(find.text(LiveShareScreen.stopLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text(LiveShareScreen.stopLabel));
    verify(() => sessions.stop()).called(1);
  });

  testWidgets('shows the upload indicator while Session photos wait', (
    tester,
  ) async {
    when(() => sessions.state)
        .thenReturn(SessionsState(loaded: true, sessions: [open]));
    await pumpScreen(tester, sessionsPending: 2);

    expect(find.byTooltip(UploadStatusIndicator.tooltip), findsOneWidget);
  });

  testWidgets('with no window open, it offers Start and Resume', (
    tester,
  ) async {
    when(() => sessions.state)
        .thenReturn(SessionsState(loaded: true, sessions: [closed]));
    await pumpScreen(tester);

    expect(find.text(LiveShareScreen.closedText), findsOneWidget);
    expect(find.byType(PrettyQrView), findsNothing);

    await tester.tap(
      find.text('${LiveShareScreen.resumeLabel} ${closed.code}'),
    );
    verify(() => sessions.reactivate(closed)).called(1);
    await tester.ensureVisible(find.text(LiveShareScreen.startLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text(LiveShareScreen.startLabel));
    verify(() => sessions.start()).called(1);
  });

  testWidgets('on re-entry it asks inline to resume or start new (AC19)', (
    tester,
  ) async {
    when(() => liveShare.state)
        .thenReturn(LiveShareState(active: true, resumable: closed));
    when(() => sessions.state)
        .thenReturn(SessionsState(loaded: true, sessions: [closed]));
    await pumpScreen(tester);

    expect(find.text(LiveShareScreen.resumeQuestion(closed.code)), findsOne);
    expect(find.byType(Dialog), findsNothing);

    await tester.ensureVisible(find.text(LiveShareScreen.resumeLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text(LiveShareScreen.resumeLabel));
    verify(() => liveShare.resume()).called(1);
    await tester.ensureVisible(find.text(LiveShareScreen.startLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text(LiveShareScreen.startLabel));
    verify(() => liveShare.startNew()).called(1);
  });

  testWidgets('shows clock sync for the camera, without Mark now', (
    tester,
  ) async {
    final clockSync = _MockClockSyncCubit();
    when(() => clockSync.state)
        .thenReturn(const ClockResolved(ClockResolution.fresh, Duration.zero));
    when(() => liveShare.state).thenReturn(
      LiveShareState(
        active: true,
        client: FakeCameraClient(const []),
        clockSync: clockSync,
      ),
    );
    when(() => sessions.state)
        .thenReturn(SessionsState(loaded: true, sessions: [open]));
    await pumpScreen(tester);

    expect(find.byType(ClockSyncBanner), findsOneWidget);
    expect(find.text('Camera clock in sync'), findsOneWidget);

    expect(find.byIcon(Icons.more_time), findsNothing);
  });

  testWidgets('shows no clock sync while the camera reconnects', (
    tester,
  ) async {
    when(() => sessions.state)
        .thenReturn(SessionsState(loaded: true, sessions: [open]));
    await pumpScreen(tester);

    expect(find.byType(ClockSyncBanner), findsNothing);
  });
}
