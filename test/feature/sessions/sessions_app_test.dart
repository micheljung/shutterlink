import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/app.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/data/upload_worker.dart';
import 'package:shutterlink/feature/connect/connect_screen.dart';
import 'package:shutterlink/feature/sessions/clock_sync_banner.dart';
import 'package:shutterlink/feature/sessions/session_qr_sheet.dart';
import 'package:shutterlink/feature/sessions/sessions_cubit.dart';
import 'package:shutterlink/feature/sessions/sessions_upload_cubit.dart';
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

final serverUrlField = find.widgetWithText(TextField, 'Server URL');

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

  Future<void> tapAndSettle(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  testWidgets('connecting Sessions saves the setup only on finish', (
    tester,
  ) async {
    await pumpApp(tester, prefs: {});
    await openSessionsSettings(tester);
    expect(serverUrlField, findsNothing);
    final settings = tester
        .element(find.byType(SettingsScreen))
        .read<SettingsCubit>();

    await tester.ensureVisible(find.text('Connect Sessions'));
    await tester.pumpAndSettle();
    await tapAndSettle(tester, 'Connect Sessions');
    await tester.enterText(serverUrlField, 'http://photos.example.com');
    await tester.pump();
    expect(
      find.text('Use https:// (http:// only for localhost)'),
      findsOneWidget,
    );
    await tester.enterText(serverUrlField, _serverUrl);
    await tester.pump();
    expect(
      find.text('Use https:// (http:// only for localhost)'),
      findsNothing,
    );
    await tapAndSettle(tester, 'Next');
    await tester.enterText(
      find.widgetWithText(TextField, 'Upload token'),
      'token',
    );
    await tester.pump();
    await tester.tap(find.text('Next'));
    await pumpUntil(
      tester,
      () => find.textContaining("can't check tokens").evaluate().isNotEmpty,
    );
    expect(sessions.requests.single.url.path, '/api/auth');
    expect(settings.state.sessionsEnabled, isFalse);
    expect(settings.state.sessionsServerUrl, isNull);

    await tester.tap(find.text('Save anyway'));
    await pumpUntil(tester, () => settings.state.sessionsConfigured);
    await pumpUntil(tester, () => sessions.workers == 1);
    expect(settings.state.sessionsServerUrl, _serverUrl);
    await pumpUntil(
      tester,
      () =>
          find.textContaining('server configuration').evaluate().isNotEmpty ||
          find.textContaining('Ready').evaluate().isNotEmpty,
    );
  });

  testWidgets('saving a corrected token wakes the paused upload worker', (
    tester,
  ) async {
    await pumpApp(
      tester,
      prefs: {
        SettingsRepository.sessionsEnabledKey: true,
        SettingsRepository.sessionsServerUrlKey: _serverUrl,
      },
      token: 'wrong',
    );
    await pumpUntil(tester, () => sessions.workers == 1);
    var enqueued = false;
    unawaited(() async {
      final session = await sessions.repository.start();
      final photo = File(p.join(sessions.uploadDirectory.path, 'a.jpg'));
      await photo.create(recursive: true);
      await photo.writeAsBytes([1, 2, 3]);
      await sessions.queue.enqueue(sessionCode: session.code, file: photo);
      enqueued = true;
    }());
    await pumpUntil(tester, () => enqueued);
    await pumpUntil(tester, () => sessions.requests.length == 1);
    final uploads = tester
        .element(find.byType(ConnectScreen))
        .read<SessionsUploadCubit>();
    await pumpUntil(
      tester,
      () => uploads.state.status == UploadWorkerStatus.serverConfiguration,
    );

    await tester
        .element(find.byType(ConnectScreen))
        .read<SettingsCubit>()
        .setSessionsToken('corrected');
    await pumpUntil(tester, () => sessions.requests.length == 2);
    expect(sessions.requests.last.headers['authorization'], 'Bearer corrected');
    await tester.pumpWidget(const SizedBox());
    await pumpUntil(tester, () => uploads.isClosed);
  });

  testWidgets('editing the server URL saves it only on finish', (tester) async {
    const typed = 'https://other.example.com';
    await pumpApp(
      tester,
      prefs: {
        SettingsRepository.sessionsEnabledKey: true,
        SettingsRepository.sessionsServerUrlKey: _serverUrl,
      },
      token: 'token',
    );
    await pumpUntil(tester, () => sessions.workers == 1);
    var enqueued = false;
    unawaited(() async {
      final session = await sessions.repository.start();
      final photo = File(p.join(sessions.uploadDirectory.path, 'a.jpg'));
      await photo.create(recursive: true);
      await photo.writeAsBytes([1, 2, 3]);
      await sessions.queue.enqueue(sessionCode: session.code, file: photo);
      enqueued = true;
    }());
    await pumpUntil(tester, () => enqueued);
    await pumpUntil(tester, () => sessions.requests.length == 1);
    final uploads = tester
        .element(find.byType(ConnectScreen))
        .read<SessionsUploadCubit>();
    await pumpUntil(
      tester,
      () => uploads.state.status == UploadWorkerStatus.serverConfiguration,
    );
    await openSessionsSettings(tester);
    final settings = tester
        .element(find.byType(SettingsScreen))
        .read<SettingsCubit>();

    Future<void> editToCheck() async {
      await tester.ensureVisible(find.text('Edit'));
      await tester.pumpAndSettle();
      await tapAndSettle(tester, 'Edit');
      await tester.enterText(serverUrlField, typed);
      await tester.pump();
      await tapAndSettle(tester, 'Next');
      await tester.tap(find.text('Next'));
      await pumpUntil(
        tester,
        () => find.text('Save anyway').evaluate().isNotEmpty,
      );
    }

    await editToCheck();
    expect(sessions.requests, hasLength(2));
    expect(sessions.requests.last.url.toString(), '$typed/api/auth');
    expect(sessions.requests.last.headers['authorization'], 'Bearer token');
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(settings.state.sessionsServerUrl, _serverUrl);
    expect(sessions.fakeCredentials.storedToken, 'token');

    await editToCheck();
    await tester.tap(find.text('Save anyway'));
    await pumpUntil(
      tester,
      () =>
          sessions.requests.last.url.host == Uri.parse(typed).host &&
          sessions.requests.last.method == 'PUT',
    );
    expect(settings.state.sessionsServerUrl, typed);
    expect(sessions.fakeCredentials.storedToken, 'token');
    await tester.pumpWidget(const SizedBox());
    await pumpUntil(tester, () => uploads.isClosed);
  });

  testWidgets('disconnecting keeps the server URL and token', (tester) async {
    await pumpApp(
      tester,
      prefs: {
        SettingsRepository.sessionsEnabledKey: true,
        SettingsRepository.sessionsServerUrlKey: _serverUrl,
      },
      token: 'token',
    );
    await openSessionsSettings(tester);
    final settings = tester
        .element(find.byType(SettingsScreen))
        .read<SettingsCubit>();
    expect(find.text('photos.example.com'), findsOneWidget);

    await tester.ensureVisible(find.text('Disconnect'));
    await tester.pumpAndSettle();
    await tapAndSettle(tester, 'Disconnect');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Disconnect'),
      ),
    );
    await pumpUntil(tester, () => !settings.state.sessionsEnabled);

    expect(settings.state.sessionsServerUrl, _serverUrl);
    expect(sessions.fakeCredentials.storedToken, 'token');
    expect(find.text('Connect Sessions'), findsOneWidget);
  });
}
