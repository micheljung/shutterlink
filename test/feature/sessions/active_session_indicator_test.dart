import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/session_repository.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/sessions/active_session_indicator.dart';
import 'package:shutterlink/feature/sessions/sessions_cubit.dart';
import 'package:shutterlink/feature/sessions/sessions_screen.dart';
import 'package:shutterlink/feature/settings/settings_cubit.dart';

import '../../fakes/fake_sessions_credentials.dart';
import 'sessions_screen_test.dart' show pumpUntil;

Future<T> settle<T>(WidgetTester tester, Future<T> future) async {
  late T value;
  var done = false;
  unawaited(
    future.then((result) {
      value = result;
      done = true;
    }),
  );
  await pumpUntil(tester, () => done);
  return value;
}

void main() {
  late Directory root;
  late SessionRepository repository;

  setUp(() {
    root = Directory.systemTemp.createTempSync('active_session');
    repository = SessionRepository(
      File(p.join(root.path, SessionRepository.fileName)),
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<SessionsCubit> pumpIndicator(
    WidgetTester tester, {
    String? token = 'token',
  }) async {
    SharedPreferences.setMockInitialValues({
      SettingsRepository.sessionsEnabledKey: true,
      SettingsRepository.sessionsServerUrlKey: 'https://photos.example.com',
    });
    final settings = SettingsCubit(
      SettingsRepository(await SharedPreferences.getInstance()),
      credentials: FakeSessionsCredentials(token),
    );
    await settle(tester, settings.init());
    final sessions = SessionsCubit(repository);
    addTearDown(settings.close);
    addTearDown(sessions.close);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider.value(value: settings),
          BlocProvider.value(value: sessions),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ActiveSessionIndicator()),
        ),
      ),
    );
    await pumpUntil(tester, () => sessions.state.loaded);
    return sessions;
  }

  testWidgets('shows the running Session until it is stopped', (tester) async {
    final sessions = await pumpIndicator(tester);
    expect(find.byType(ListTile), findsNothing);

    final session = await settle(tester, repository.start());
    await pumpUntil(tester, () => sessions.state.active != null);
    expect(
      find.text(ActiveSessionIndicator.text(session.code)),
      findsOneWidget,
    );

    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();
    expect(find.byType(SessionsScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await settle(tester, repository.stop());
    await pumpUntil(tester, () => sessions.state.active == null);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('stays hidden while Sessions are not configured', (tester) async {
    await pumpIndicator(tester, token: null);
    await settle(tester, repository.start());
    expect(find.byType(ListTile), findsNothing);
  });
}
