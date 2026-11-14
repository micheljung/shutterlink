import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/live/ingest_coordinator.dart';
import 'package:shutterlink/feature/settings/sessions_setup_screen.dart';
import 'package:shutterlink/feature/settings/settings_cubit.dart';

import '../../fakes/fake_sessions_credentials.dart';
import '../../fakes/test_app.dart';

const _serverUrl = 'https://photos.example.com';

void main() {
  late SettingsRepository repository;
  late SettingsCubit settings;
  late FakeSessionsCredentials credentials;
  late List<http.Request> requests;
  late int authStatus;
  Object? authError;

  Future<void> pump(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
    String? token,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    repository = SettingsRepository(await SharedPreferences.getInstance());
    credentials = FakeSessionsCredentials(token);
    settings = SettingsCubit(repository, credentials: credentials);
    await tester.runAsync(settings.init);
    addTearDown(settings.close);
    requests = [];
    authStatus = HttpStatus.noContent;
    authError = null;
    final directory = Directory.systemTemp.createTempSync('sessions_setup');
    addTearDown(() => directory.deleteSync(recursive: true));
    final dependencies = testSessionsDependencies(
      repository,
      directory,
      IngestCoordinator(),
      credentials: credentials,
      newClient: () => MockClient((request) async {
        requests.add(request);
        if (authError case final error?) throw error;
        return http.Response('', authStatus);
      }),
    );
    await tester.pumpWidget(
      RepositoryProvider.value(
        value: dependencies,
        child: BlocProvider.value(
          value: settings,
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    Navigator.of(context).push(SessionsSetupScreen.route()),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  bool nextEnabled(WidgetTester tester) => tester
      .widget<FilledButton>(find.widgetWithText(FilledButton, 'Next'))
      .enabled;

  Future<void> enter(WidgetTester tester, String label, String text) async {
    await tester.enterText(find.widgetWithText(TextField, label), text);
    await tester.pump();
  }

  Future<void> next(WidgetTester tester) async {
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
  }

  Future<void> toCheck(WidgetTester tester, {String token = 'secret'}) async {
    await enter(tester, 'Server URL', _serverUrl);
    await next(tester);
    await enter(tester, 'Upload token', token);
    await next(tester);
  }

  void expectNothingSaved() {
    expect(repository.sessionsEnabled, isFalse);
    expect(repository.sessionsServerUrl, isNull);
    expect(credentials.storedToken, isNull);
  }

  testWidgets('Next accepts only https or localhost URLs', (tester) async {
    await pump(tester);

    expect(nextEnabled(tester), isFalse);
    for (final (url, valid) in [
      ('http://example.com', false),
      ('example.com', false),
      ('https://photos.example.com', true),
      ('http://localhost:8080', true),
    ]) {
      await enter(tester, 'Server URL', url);
      expect(nextEnabled(tester), valid, reason: url);
    }
  });

  testWidgets('a valid token finishes and saves everything', (tester) async {
    await pump(tester);

    await enter(tester, 'Server URL', _serverUrl);
    await next(tester);
    expect(nextEnabled(tester), isFalse);
    await enter(tester, 'Upload token', 'secret');
    await next(tester);

    expect(requests.single.url.toString(), '$_serverUrl/api/auth');
    expect(requests.single.headers['authorization'], 'Bearer secret');
    expect(find.byType(SessionsSetupScreen), findsNothing);
    expect(repository.sessionsEnabled, isTrue);
    expect(repository.sessionsServerUrl, _serverUrl);
    expect(credentials.storedToken, 'secret');
    expect(settings.state.sessionsConfigured, isTrue);
  });

  testWidgets('a rejected token cannot finish', (tester) async {
    await pump(tester);
    authStatus = HttpStatus.unauthorized;

    await toCheck(tester);

    expect(
      find.text('Token rejected. Check the token and try again.'),
      findsOneWidget,
    );
    expect(find.text('Save anyway'), findsNothing);
    expectNothingSaved();
    await tester.tap(find.text('Back to token'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Upload token'), findsOneWidget);
    expectNothingSaved();
  });

  testWidgets('an old server can be saved anyway', (tester) async {
    await pump(tester);
    authStatus = HttpStatus.notFound;

    await toCheck(tester);
    expect(find.textContaining("can't check tokens"), findsOneWidget);
    expectNothingSaved();

    await tester.tap(find.text('Save anyway'));
    await tester.pumpAndSettle();
    expect(repository.sessionsEnabled, isTrue);
    expect(credentials.storedToken, 'secret');
  });

  testWidgets('abandoning setup saves nothing', (tester) async {
    await pump(tester);
    authStatus = HttpStatus.unauthorized;
    await toCheck(tester);

    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();

    expect(find.byType(SessionsSetupScreen), findsNothing);
    expectNothingSaved();
  });

  testWidgets('an empty token on edit checks and keeps the saved one', (
    tester,
  ) async {
    await pump(
      tester,
      prefs: {
        SettingsRepository.sessionsEnabledKey: true,
        SettingsRepository.sessionsServerUrlKey: _serverUrl,
      },
      token: 'stored',
    );
    expect(find.text('Edit Sessions'), findsOneWidget);

    await next(tester);
    expect(nextEnabled(tester), isTrue);
    await next(tester);

    expect(requests.single.headers['authorization'], 'Bearer stored');
    expect(find.byType(SessionsSetupScreen), findsNothing);
    expect(credentials.storedToken, 'stored');
    expect(settings.state.sessionsTokenRevision, 0);
  });

  testWidgets('a TLS failure reports the server unreachable', (tester) async {
    await pump(tester);
    authError = const HandshakeException('certificate expired');

    await toCheck(tester);

    expect(find.textContaining('Could not reach the server'), findsOneWidget);
    expect(find.text('Checking the token…'), findsNothing);
    expectNothingSaved();
    await tester.tap(find.text('Save anyway'));
    await tester.pumpAndSettle();
    expect(repository.sessionsEnabled, isTrue);
  });

  testWidgets('an unreadable saved token asks for it again', (tester) async {
    await pump(
      tester,
      prefs: {
        SettingsRepository.sessionsEnabledKey: true,
        SettingsRepository.sessionsServerUrlKey: _serverUrl,
      },
      token: 'stored',
    );
    credentials.readError = Exception('Keystore key invalidated');

    await next(tester);
    await next(tester);

    expect(
      find.text(
        'Could not read the saved token from this device. Enter it again.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Token rejected. Check the token and try again.'),
      findsNothing,
    );
    expect(find.text('Save anyway'), findsNothing);
    expect(requests, isEmpty);
    await tester.tap(find.text('Back to token'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Upload token'), findsOneWidget);
  });
}
