import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/provider_preset.dart';

void main() {
  final cases = [
    (
      ProviderPreset.nextcloud,
      const PresetInput(
        server: 'cloud.example.com',
        basePath: 'Photos',
        username: 'alice',
      ),
      const Destination(
        type: DestinationType.webdav,
        endpoint: 'https://cloud.example.com/remote.php/webdav',
        basePath: 'Photos',
        username: 'alice',
      ),
    ),
    (
      ProviderPreset.nextcloud,
      const PresetInput(server: 'http://nas.local:8080/nextcloud/'),
      const Destination(
        type: DestinationType.webdav,
        endpoint: 'http://nas.local:8080/nextcloud/remote.php/webdav',
      ),
    ),
    (
      ProviderPreset.backblazeB2,
      const PresetInput(
        region: 'eu-central-003',
        bucket: 'camera',
        username: 'keyid',
      ),
      const Destination(
        type: DestinationType.s3,
        endpoint: 'https://s3.eu-central-003.backblazeb2.com',
        region: 'eu-central-003',
        bucket: 'camera',
        username: 'keyid',
        pathStyle: true,
      ),
    ),
    (
      ProviderPreset.awsS3,
      const PresetInput(
        region: ' eu-central-1 ',
        bucket: 'camera',
        basePath: 'eos',
      ),
      const Destination(
        type: DestinationType.s3,
        endpoint: 'https://s3.eu-central-1.amazonaws.com',
        region: 'eu-central-1',
        bucket: 'camera',
        basePath: 'eos',
      ),
    ),
    (
      ProviderPreset.cloudflareR2,
      const PresetInput(server: '0123abcd', bucket: 'camera'),
      const Destination(
        type: DestinationType.s3,
        endpoint: 'https://0123abcd.r2.cloudflarestorage.com',
        region: 'auto',
        bucket: 'camera',
        pathStyle: true,
      ),
    ),
    (
      ProviderPreset.hetznerStorageBox,
      const PresetInput(username: 'u123456'),
      const Destination(
        type: DestinationType.sftp,
        endpoint: 'u123456.your-storagebox.de:23',
        username: 'u123456',
      ),
    ),
    (
      ProviderPreset.hetznerStorageBox,
      const PresetInput(username: 'u123456-sub1', basePath: 'Photos'),
      const Destination(
        type: DestinationType.sftp,
        endpoint: 'u123456-sub1.your-storagebox.de:23',
        basePath: 'Photos',
        username: 'u123456-sub1',
      ),
    ),
    (
      ProviderPreset.immich,
      const PresetInput(server: 'photos.example.com'),
      const Destination(
        type: DestinationType.immich,
        endpoint: 'https://photos.example.com',
      ),
    ),
    (
      ProviderPreset.immich,
      const PresetInput(server: ' http://nas.local:2283/api/ '),
      const Destination(
        type: DestinationType.immich,
        endpoint: 'http://nas.local:2283',
      ),
    ),
    (
      ProviderPreset.immich,
      const PresetInput(
        server: 'https://example.com/immich/',
        basePath: 'ignored',
        username: 'ignored',
      ),
      const Destination(
        type: DestinationType.immich,
        endpoint: 'https://example.com/immich',
      ),
    ),
    (
      ProviderPreset.immich,
      const PresetInput(server: 'api'),
      const Destination(type: DestinationType.immich, endpoint: 'https://api'),
    ),
    (
      ProviderPreset.immich,
      const PresetInput(server: 'https://example.com/immich/api/'),
      const Destination(
        type: DestinationType.immich,
        endpoint: 'https://example.com/immich',
      ),
    ),
    (
      ProviderPreset.custom,
      const PresetInput(
        type: DestinationType.s3,
        server: 'https://minio.example.com',
        region: 'us-east-1',
        bucket: 'camera',
        pathStyle: true,
      ),
      const Destination(
        type: DestinationType.s3,
        endpoint: 'https://minio.example.com',
        region: 'us-east-1',
        bucket: 'camera',
        pathStyle: true,
      ),
    ),
    (
      ProviderPreset.custom,
      const PresetInput(
        type: DestinationType.sftp,
        server: 'nas.example.com:2222',
        region: 'ignored',
        bucket: 'ignored',
        pathStyle: true,
        username: 'alice',
      ),
      const Destination(
        type: DestinationType.sftp,
        endpoint: 'nas.example.com:2222',
        username: 'alice',
      ),
    ),
  ];

  for (final (preset, input, expected) in cases) {
    test('${preset.name} builds ${expected.endpoint}', () {
      expect(preset.build(input), expected);
    });

    test('${preset.name} round-trips ${expected.endpoint}', () {
      final built = preset.build(input);
      final parsed = preset.parse(built);
      expect(parsed, isNotNull);
      expect(preset.build(parsed!).fingerprint, built.fingerprint);
    });
  }

  test('presets do not parse destinations of other providers', () {
    final aws = ProviderPreset.awsS3.build(
      const PresetInput(region: 'eu-central-1', bucket: 'b'),
    );
    for (final preset in [
      ProviderPreset.nextcloud,
      ProviderPreset.backblazeB2,
      ProviderPreset.cloudflareR2,
      ProviderPreset.hetznerStorageBox,
      ProviderPreset.immich,
    ]) {
      expect(preset.parse(aws), isNull, reason: preset.name);
    }
    expect(ProviderPreset.custom.parse(aws), isNotNull);
  });

  test('a storage box with another host parses only as custom', () {
    const moved = Destination(
      type: DestinationType.sftp,
      endpoint: 'u1.your-storagebox.de:23',
      username: 'u2',
    );
    expect(ProviderPreset.hetznerStorageBox.parse(moved), isNull);
    expect(ProviderPreset.custom.parse(moved), isNotNull);
  });

  test('an Immich destination parses back to its address', () {
    final immich = ProviderPreset.immich.build(
      const PresetInput(server: 'photos.example.com/api'),
    );
    expect(
      ProviderPreset.immich.parse(immich),
      const PresetInput(server: 'photos.example.com'),
    );
    expect(ProviderPreset.nextcloud.parse(immich), isNull);
  });
}
