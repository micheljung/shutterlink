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

  test('preview quality defaults to thumbnail and persists', () async {
    expect(cubit.state.previewQuality, PreviewQuality.thumbnail);

    await cubit.setPreviewQuality(PreviewQuality.full);

    expect(cubit.state.previewQuality, PreviewQuality.full);
    expect(settings.previewQuality, PreviewQuality.full);
    expect(SettingsCubit(settings).state.previewQuality, PreviewQuality.full);
  });

  test('changing one setting keeps the others', () async {
    await cubit.setPreviewQuality(PreviewQuality.full);
    await cubit.setHostOverride('10.0.0.9');
    await cubit.setFormat(DownloadFormat.raw);

    expect(
      cubit.state,
      const SettingsState(
        format: DownloadFormat.raw,
        previewQuality: PreviewQuality.full,
        hostOverride: '10.0.0.9',
      ),
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

    test('off by default without reading credentials', () async {
      await sessionsCubit.init();

      expect(sessionsCubit.state.sessionsEnabled, isFalse);
      expect(sessionsCubit.state.sessionsConfigured, isFalse);
      expect(credentials.reads, 0);
    });

    test('configured needs enabled, a valid URL and a token', () async {
      await sessionsCubit.setSessionsEnabled(true);
      expect(sessionsCubit.state.sessionsConfigured, isFalse);

      await sessionsCubit.setSessionsServerUrl(url);
      expect(sessionsCubit.state.sessionsConfigured, isTrue);
      expect(settings.sessionsServerUrl, url);

      await sessionsCubit.setSessionsToken(null);
      expect(sessionsCubit.state.sessionsConfigured, isFalse);

      await sessionsCubit.setSessionsToken('other');
      await sessionsCubit.setSessionsEnabled(false);
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
      await settings.setSessionsEnabled(true);
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
      await settings.setSessionsEnabled(true);
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
  });
}
