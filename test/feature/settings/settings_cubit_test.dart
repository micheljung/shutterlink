import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/settings/settings_cubit.dart';

import '../../fakes/fake_sessions_credentials.dart';

void main() {
  late SettingsRepository settings;
  late SettingsCubit cubit;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
    cubit = SettingsCubit(settings);
  });

  tearDown(() => cubit.close());

  test('the onboarding is unseen until marked, and persists', () async {
    expect(cubit.state.onboardingSeen, isFalse);

    await cubit.markOnboardingSeen();

    expect(cubit.state.onboardingSeen, isTrue);
    expect(settings.onboardingSeen, isTrue);
    expect(SettingsCubit(settings).state.onboardingSeen, isTrue);
  });

  test('changing one setting keeps the others', () async {
    await cubit.setHostOverride('10.0.0.9');
    await cubit.setFormat(DownloadFormat.raw);

    expect(
      cubit.state,
      const SettingsState(format: DownloadFormat.raw, hostOverride: '10.0.0.9'),
    );
  });

  group('Sessions', () {
    const url = 'https://photos.example.com';
    late FakeSessionsCredentials credentials;
    late SettingsCubit sessionsCubit;

    setUp(() {
      credentials = FakeSessionsCredentials('token');
      sessionsCubit = SettingsCubit(settings, credentials: credentials);
    });

    tearDown(() => sessionsCubit.close());

    test('not configured without a URL, and the token is not read', () async {
      await sessionsCubit.init();

      expect(sessionsCubit.state.sessionsConfigured, isFalse);
      expect(credentials.reads, 0);
    });

    test('configured is a valid URL and a token, with no toggle', () async {
      await sessionsCubit.setSessionsServerUrl(url);
      expect(sessionsCubit.state.sessionsConfigured, isTrue);
      expect(settings.sessionsServerUrl, url);

      await sessionsCubit.setSessionsToken(null);
      expect(sessionsCubit.state.sessionsConfigured, isFalse);

      await sessionsCubit.setSessionsToken('other');
      expect(sessionsCubit.state.sessionsConfigured, isTrue);

      await sessionsCubit.setSessionsServerUrl(' ');
      expect(sessionsCubit.state.sessionsConfigured, isFalse);
    });

    test(
      'an invalid URL keeps the saved one, an empty one clears it',
      () async {
        await sessionsCubit.setSessionsServerUrl(url);

        await sessionsCubit.setSessionsServerUrl('http://photos.example.com');
        expect(sessionsCubit.state.sessionsServerUrl, url);
        expect(settings.sessionsServerUrl, url);

        await sessionsCubit.setSessionsServerUrl(' ');
        expect(sessionsCubit.state.sessionsServerUrl, isNull);
        expect(settings.sessionsServerUrl, isNull);
      },
    );

    test('an unreadable token counts as not configured', () async {
      await settings.setSessionsServerUrl(url);
      credentials.readError = Exception('keystore unavailable');
      final restored = SettingsCubit(settings, credentials: credentials);
      addTearDown(restored.close);

      await restored.init();

      expect(restored.state.sessionsConfigured, isFalse);
    });

    test('every saved token counts as a new revision', () async {
      await sessionsCubit.setSessionsToken('fixed');
      await sessionsCubit.setSessionsToken('fixed');

      expect(sessionsCubit.state.sessionsTokenRevision, 2);
    });

    test('init restores the configured state', () async {
      await settings.setSessionsServerUrl(url);
      final restored = SettingsCubit(settings, credentials: credentials);
      addTearDown(restored.close);

      await restored.init();

      expect(restored.state.sessionsConfigured, isTrue);
      expect(restored.state.sessionsServerUrl, url);
    });

    test('only https or http on localhost is stored', () async {
      await sessionsCubit.setSessionsServerUrl('http://photos.example.com');
      expect(settings.sessionsServerUrl, isNull);

      await sessionsCubit.setSessionsServerUrl('http://localhost:8080');
      expect(settings.sessionsServerUrl, 'http://localhost:8080');

      expect(isValidSessionsServerUrl('ftp://photos.example.com'), isFalse);
      expect(isValidSessionsServerUrl('https://'), isFalse);
      expect(isValidSessionsServerUrl('http://127.0.0.1:8080'), isTrue);
    });

    test('a mangled address is rejected', () {
      expect(
        isValidSessionsServerUrl(
          'https://photos.examphttps://photos.example.comtesttoken123 e.com',
        ),
        isFalse,
      );
      expect(
        isValidSessionsServerUrl(
          'https://photos.examphttps://photos.example.com',
        ),
        isFalse,
      );
      expect(isValidSessionsServerUrl('https://photos .example.com'), isFalse);
      expect(isValidSessionsServerUrl('https://photos.example.com?a'), isFalse);
      expect(isValidSessionsServerUrl('https://photos.example.com#a'), isFalse);
      expect(isValidSessionsServerUrl(' https://photos.example.com/ '), isTrue);
    });
  });
}
