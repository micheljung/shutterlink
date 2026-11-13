import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/settings_repository.dart';

void main() {
  late SettingsRepository settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
  });

  test('format defaults to JPEG and persists changes', () async {
    expect(settings.format, DownloadFormat.jpeg);

    await settings.setFormat(DownloadFormat.both);

    expect(
      SettingsRepository(await SharedPreferences.getInstance()).format,
      DownloadFormat.both,
    );
  });

  test('preview quality defaults to thumbnail and persists changes', () async {
    expect(settings.previewQuality, PreviewQuality.thumbnail);

    await settings.setPreviewQuality(PreviewQuality.full);

    expect(
      SettingsRepository(await SharedPreferences.getInstance()).previewQuality,
      PreviewQuality.full,
    );
  });

  test('blank host override clears it', () async {
    await settings.setHostOverride(' 192.168.1.5 ');
    expect(settings.hostOverride, '192.168.1.5');

    await settings.setHostOverride('  ');
    expect(settings.hostOverride, isNull);
  });

  test('Sessions are off by default and persist changes', () async {
    expect(settings.sessionsEnabled, isFalse);
    expect(settings.sessionsServerUrl, isNull);

    await settings.setSessionsEnabled(true);
    await settings.setSessionsServerUrl(' https://photos.example.com ');

    final reloaded = SettingsRepository(await SharedPreferences.getInstance());
    expect(reloaded.sessionsEnabled, isTrue);
    expect(reloaded.sessionsServerUrl, 'https://photos.example.com');

    await settings.setSessionsServerUrl('  ');
    expect(settings.sessionsServerUrl, isNull);
  });

  group('CameraHostResolver', () {
    test('prefers the override', () async {
      await settings.setHostOverride('10.0.0.9');
      final resolver = CameraHostResolver(
        settings,
        wifiGateway: () async => '192.168.1.1',
      );

      expect(await resolver.resolve(boundGateway: '192.168.1.3'), '10.0.0.9');
    });

    test('uses the bound gateway, then the Wi-Fi gateway', () async {
      final resolver = CameraHostResolver(
        settings,
        wifiGateway: () async => '192.168.1.1',
      );

      expect(
        await resolver.resolve(boundGateway: '192.168.1.3'),
        '192.168.1.3',
      );
      expect(await resolver.resolve(), '192.168.1.1');
    });

    test('falls back to the constant', () async {
      final resolver = CameraHostResolver(
        settings,
        wifiGateway: () async => '0.0.0.0',
      );

      expect(await resolver.resolve(), CameraHostResolver.fallbackHost);
    });
  });
}
