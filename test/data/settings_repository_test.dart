import 'package:eos_transfer/data/camera_host_resolver.dart';
import 'package:eos_transfer/data/settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  test('blank host override clears it', () async {
    await settings.setHostOverride(' 192.168.1.5 ');
    expect(settings.hostOverride, '192.168.1.5');

    await settings.setHostOverride('  ');
    expect(settings.hostOverride, isNull);
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
