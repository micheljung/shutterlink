import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/feature/sessions/clock_sync_banner.dart';
import 'package:shutterlink/feature/settings/sessions_settings_section.dart';
import 'package:shutterlink/feature/settings/settings_screen.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/spy_sessions_dependencies.dart';
import '../../fakes/test_app.dart';

const _scrollStep = 100.0;

final sessionsServerUrl = find.descendant(
  of: find.byType(SessionsSettingsSection),
  matching: find.text('Server URL'),
);
final sessionsSwitch = find.descendant(
  of: find.byType(SessionsSettingsSection),
  matching: find.byType(Switch),
);

void main() {
  testWidgets('Sessions off touches no credentials, worker or network', (
    tester,
  ) async {
    late SpySessionsDependencies sessions;
    final client = FakeCameraClient([cameraObject(1, 'IMG_0001.JPG')]);
    final dependencies = await testDependencies(
      (_, _) async => client,
      sessions: (settings, directory, coordinator) =>
          sessions = SpySessionsDependencies(
            settings,
            directory,
            coordinator: coordinator,
            token: 'token',
          ),
    );
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Sessions'), findsNothing);

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.text('Photos (1)'), findsOneWidget);
    expect(find.byTooltip('Sessions'), findsNothing);
    expect(find.byType(ClockSyncBanner), findsNothing);

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
    expect(sessionsSwitch, findsOneWidget);
    expect(sessionsServerUrl, findsNothing);

    expect(sessions.fakeCredentials.reads, 0);
    expect(sessions.workers, 0);
    expect(sessions.clockSyncs, 0);
    expect(sessions.collectors, 0);
    expect(sessions.requests, isEmpty);
    expect(client.requestedOffsets, isEmpty);
  });
}
