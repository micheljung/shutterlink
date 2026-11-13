import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/sessions/clock_sync_banner.dart';
import 'package:shutterlink/feature/sessions/session_qr_sheet.dart';
import 'package:shutterlink/feature/sessions/sessions_cubit.dart';
import 'package:shutterlink/feature/settings/sessions_settings_section.dart';
import 'package:shutterlink/feature/settings/settings_cubit.dart';
import 'package:shutterlink/feature/settings/settings_screen.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/spy_sessions_dependencies.dart';
import '../../fakes/test_app.dart';

const _pollInterval = Duration(milliseconds: 5);
const _maxPolls = 400;
const _scrollStep = 100.0;
const _serverUrl = 'https://photos.example.com';

Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < _maxPolls && !condition(); i++) {
    await tester.runAsync(() => Future<void>.delayed(_pollInterval));
    await tester.pump();
  }
  await tester.pump();
  expect(condition(), isTrue);
}

final sessionsServerUrl = find.descendant(
  of: find.byType(SessionsSettingsSection),
  matching: find.text('Server URL'),
);
final sessionsSwitch = find.descendant(
  of: find.byType(SessionsSettingsSection),
  matching: find.byType(Switch),
);

void main() {
  late SpySessionsDependencies sessions;

  Future<FakeCameraClient> pumpApp(
    WidgetTester tester, {
    required Map<String, Object> prefs,
    String? token,
  }) async {
    final client = FakeCameraClient([
      cameraObject(1, 'IMG_0001.JPG', captureDate: DateTime.utc(2026)),
    ])..cameraLag = const Duration(seconds: 90);
    final dependencies = await testDependencies(
      (_, _) async => client,
      prefs: prefs,
      sessions: (settings, directory, coordinator) =>
          sessions = SpySessionsDependencies(
            settings,
            directory,
            coordinator: coordinator,
            token: token,
          ),
    );
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await tester.pump();
    return client;
  }

  Future<void> openSessionsSettings(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Sessions'),
      _scrollStep,
      scrollable: find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }

  testWidgets('a configured app syncs the clock and starts Sessions', (
    tester,
  ) async {
    final client = await pumpApp(
      tester,
      prefs: {
        SettingsRepository.sessionsEnabledKey: true,
        SettingsRepository.sessionsServerUrlKey: _serverUrl,
      },
      token: 'token',
    );
    await pumpUntil(
      tester,
      () => find.byTooltip('Sessions').evaluate().isNotEmpty,
    );
    expect(sessions.workers, 1);

    await tester.tap(find.text('Connect'));
    await pumpUntil(
      tester,
      () => find.byType(ClockSyncBanner).evaluate().isNotEmpty,
    );
    await pumpUntil(
      tester,
      () => find.textContaining('90 s behind').evaluate().isNotEmpty,
    );
    expect(sessions.clockSyncs, 1);
    expect(sessions.collectors, 1);

    await tester.tap(find.byTooltip('Sessions'));
    await tester.pumpAndSettle();
    final cubit = tester
        .element(find.text('Start Session'))
        .read<SessionsCubit>();
    await pumpUntil(tester, () => cubit.state.loaded);
    await tester.tap(find.text('Start Session'));
    await pumpUntil(tester, () => cubit.state.active != null);
    await tester.pumpAndSettle();
    expect(find.byType(SessionQrSheet), findsOneWidget);

    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Disconnect'));
    await tester.pumpAndSettle();
    expect(client.closed, isTrue);
  });

  testWidgets('enabling Sessions in settings reveals its configuration', (
    tester,
  ) async {
    await pumpApp(tester, prefs: {});
    await openSessionsSettings(tester);
    expect(sessionsServerUrl, findsNothing);

    await tester.ensureVisible(sessionsSwitch);
    await tester.tap(sessionsSwitch);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Save token'));
    await tester.pumpAndSettle();
    await pumpUntil(tester, () => sessions.workers == 1);

    await tester.enterText(
      find.descendant(
        of: find.byType(SessionsSettingsSection),
        matching: find.widgetWithText(TextField, 'Server URL'),
      ),
      'http://photos.example.com',
    );
    await tester.pump();
    expect(
      find.text('Use https:// (http:// only for localhost)'),
      findsOneWidget,
    );

    await tester.enterText(
      find.descendant(
        of: find.byType(SessionsSettingsSection),
        matching: find.widgetWithText(TextField, 'Server URL'),
      ),
      _serverUrl,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Upload token'),
      'token',
    );
    await tester.tap(find.byTooltip('Save token'));
    final settings = tester
        .element(find.byType(SettingsScreen))
        .read<SettingsCubit>();
    await pumpUntil(tester, () => settings.state.sessionsConfigured);
    expect(
      find.text('Use https:// (http:// only for localhost)'),
      findsNothing,
    );
    await pumpUntil(
      tester,
      () =>
          find.textContaining('server configuration').evaluate().isNotEmpty ||
          find.textContaining('Ready').evaluate().isNotEmpty,
    );
  });
}
