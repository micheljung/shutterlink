import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/session_repository.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/sessions/session.dart';
import 'package:shutterlink/feature/sessions/session_qr_sheet.dart';
import 'package:shutterlink/feature/sessions/sessions_cubit.dart';
import 'package:shutterlink/feature/sessions/sessions_screen.dart';
import 'package:shutterlink/feature/settings/settings_cubit.dart';

import '../../fakes/fake_sessions_credentials.dart';

const _maxPolls = 100;
const _pollInterval = Duration(milliseconds: 20);

Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < _maxPolls && !condition(); i++) {
    await tester.runAsync(() => Future<void>.delayed(_pollInterval));
    await tester.pump();
  }
  await tester.pump();
  expect(condition(), isTrue);
}

void main() {
  const serverUrl = 'https://photos.example.com';
  final t0 = DateTime.utc(2026, 11, 13, 10);
  late Directory root;
  late SessionRepository repository;
  late DateTime now;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('sessions_screen');
    now = t0;
    repository = SessionRepository(
      File(p.join(root.path, SessionRepository.fileName)),
      clock: Clock(() => now),
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<SessionsCubit> pumpScreen(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      SettingsRepository.sessionsEnabledKey: true,
      SettingsRepository.sessionsServerUrlKey: serverUrl,
    });
    final settings = SettingsCubit(
      SettingsRepository(await SharedPreferences.getInstance()),
      credentials: FakeSessionsCredentials('token'),
    );
    final sessions = SessionsCubit(repository, clock: Clock(() => now));
    addTearDown(settings.close);
    addTearDown(sessions.close);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider.value(value: settings),
          BlocProvider.value(value: sessions),
        ],
        child: const MaterialApp(home: SessionsScreen()),
      ),
    );
    await pumpUntil(tester, () => sessions.state.loaded);
    return sessions;
  }

  Future<Session> past(WidgetTester tester) async =>
      (await tester.runAsync(() async {
        final session = await repository.start();
        await repository.stop();
        return session;
      }))!;

  testWidgets('shows the code of a past Session again', (tester) async {
    final session = await past(tester);
    await pumpScreen(tester);

    await tester.tap(find.text(session.code));
    await tester.pumpAndSettle();

    expect(find.byType(SessionQrSheet), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SessionQrSheet),
        matching: find.text(session.code),
      ),
      findsOneWidget,
    );
  });

  testWidgets('starting a Session shows its QR immediately', (tester) async {
    final sessions = await pumpScreen(tester);

    await tester.tap(find.text('Start Session'));
    await pumpUntil(tester, () => sessions.state.active != null);
    await tester.pumpAndSettle();

    final code = sessions.state.active!.code;
    expect(
      find.descendant(
        of: find.byType(SessionQrSheet),
        matching: find.text(code),
      ),
      findsOneWidget,
    );
    expect(find.text('$serverUrl/s/$code'), findsOneWidget);
  });

  testWidgets('a past Session can be resumed', (tester) async {
    final session = await past(tester);
    final sessions = await pumpScreen(tester);

    await tester.tap(find.text('Resume'));
    await pumpUntil(tester, () => sessions.state.active?.id == session.id);

    expect(find.text('Stop'), findsOneWidget);
  });

  testWidgets('an expired Session offers a new Session instead', (
    tester,
  ) async {
    final session = await past(tester);
    await tester.runAsync(() => repository.markExpired(session.code));
    final sessions = await pumpScreen(tester);
    await pumpUntil(tester, () => sessions.state.sessions.single.expired);

    expect(find.textContaining('Expired'), findsOneWidget);
    expect(find.text('Resume'), findsNothing);

    await tester.tap(find.text('Start new Session'));
    await pumpUntil(tester, () => sessions.state.sessions.length == 2);
    await tester.pumpAndSettle();

    final fresh = sessions.state.active!;
    expect(fresh.code, isNot(session.code));
    expect(find.byType(SessionQrSheet), findsOneWidget);
  });

  testWidgets('a Session near its server expiry cannot be resumed', (
    tester,
  ) async {
    final session = await past(tester);
    await tester.runAsync(
      () => repository.setExpiresAt(session.code, t0.add(Duration(days: 1))),
    );
    await pumpScreen(tester);
    await tester.pump();

    expect(find.textContaining('Expired'), findsOneWidget);
    expect(find.text('Start new Session'), findsOneWidget);
    expect(find.text('Resume'), findsNothing);
  });
}
