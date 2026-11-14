import 'package:equatable/equatable.dart';

import 'destination.dart';
import 'immich_backend.dart';

const _nextcloudPath = '/remote.php/webdav';
const _httpsPrefix = 'https://';
const _r2Region = 'auto';
const _storageBoxDomain = '.your-storagebox.de';
const _storageBoxPort = 23;

/// What the user types for a [ProviderPreset]; each preset reads only the
/// fields it asks for.
class PresetInput extends Equatable {
  const PresetInput({
    this.type = DestinationType.webdav,
    this.server = '',
    this.region = '',
    this.bucket = '',
    this.pathStyle = false,
    this.basePath = '',
    this.username = '',
  });

  /// Custom only.
  final DestinationType type;

  /// The Nextcloud or Immich address, the R2 account ID, or the custom
  /// endpoint.
  final String server;
  final String region;
  final String bucket;

  /// Custom only.
  final bool pathStyle;
  final String basePath;
  final String username;

  PresetInput copyWith({
    DestinationType? type,
    String? server,
    String? region,
    String? bucket,
    bool? pathStyle,
    String? basePath,
    String? username,
  }) => PresetInput(
    type: type ?? this.type,
    server: server ?? this.server,
    region: region ?? this.region,
    bucket: bucket ?? this.bucket,
    pathStyle: pathStyle ?? this.pathStyle,
    basePath: basePath ?? this.basePath,
    username: username ?? this.username,
  );

  @override
  List<Object?> get props => [
    type,
    server,
    region,
    bucket,
    pathStyle,
    basePath,
    username,
  ];
}

enum ProviderPreset {
  nextcloud('Nextcloud / ownCloud', 'WebDAV', DestinationType.webdav),
  backblazeB2('Backblaze B2', 'S3-compatible bucket', DestinationType.s3),
  awsS3('AWS S3', 'Amazon bucket', DestinationType.s3),
  cloudflareR2('Cloudflare R2', 'S3-compatible bucket', DestinationType.s3),
  hetznerStorageBox('Hetzner Storage Box', 'SFTP', DestinationType.sftp),
  immich('Immich', 'Self-hosted photos', DestinationType.immich),
  custom('Custom', 'WebDAV, S3 or SFTP', null);

  const ProviderPreset(this.label, this.description, this._type);

  final String label;
  final String description;
  final DestinationType? _type;

  DestinationType typeFor(PresetInput input) => _type ?? input.type;

  /// Builds the endpoint verbatim from [input], apart from trimming, so an
  /// unchanged input always gives the same fingerprint.
  Destination build(PresetInput input) {
    final server = input.server.trim();
    final region = input.region.trim();
    final bucket = input.bucket.trim();
    final basePath = input.basePath.trim();
    final username = input.username.trim();
    switch (this) {
      case nextcloud:
        return Destination(
          type: DestinationType.webdav,
          endpoint: '${_withScheme(server)}$_nextcloudPath',
          basePath: basePath,
          username: username,
        );
      case backblazeB2:
        return Destination(
          type: DestinationType.s3,
          endpoint: 'https://s3.$region.backblazeb2.com',
          region: region,
          bucket: bucket,
          basePath: basePath,
          username: username,
          pathStyle: true,
        );
      case awsS3:
        return Destination(
          type: DestinationType.s3,
          endpoint: 'https://s3.$region.amazonaws.com',
          region: region,
          bucket: bucket,
          basePath: basePath,
          username: username,
        );
      case cloudflareR2:
        return Destination(
          type: DestinationType.s3,
          endpoint: 'https://$server.r2.cloudflarestorage.com',
          region: _r2Region,
          bucket: bucket,
          basePath: basePath,
          username: username,
          pathStyle: true,
        );
      case hetznerStorageBox:
        return Destination(
          type: DestinationType.sftp,
          endpoint: '$username$_storageBoxDomain:$_storageBoxPort',
          basePath: basePath,
          username: username,
        );
      case immich:
        final url = _withScheme(server);
        final uri = Uri.tryParse(url);
        return Destination(
          type: DestinationType.immich,
          endpoint: uri == null ? url : immichServerRoot(uri).toString(),
        );
      case custom:
        final s3 = input.type == DestinationType.s3;
        return Destination(
          type: input.type,
          endpoint: server,
          region: s3 ? region : '',
          bucket: s3 ? bucket : '',
          basePath: basePath,
          username: username,
          pathStyle: s3 && input.pathStyle,
        );
    }
  }

  /// The input that [build]s [destination], or null if this preset cannot.
  PresetInput? parse(Destination destination) {
    final endpoint = destination.endpoint;
    final common = PresetInput(
      basePath: destination.basePath,
      username: destination.username,
    );
    final PresetInput? input = switch (this) {
      nextcloud when endpoint.endsWith(_nextcloudPath) => common.copyWith(
        server: _withoutHttps(
          endpoint.substring(0, endpoint.length - _nextcloudPath.length),
        ),
      ),
      backblazeB2 || awsS3 => common.copyWith(
        region: destination.region,
        bucket: destination.bucket,
      ),
      cloudflareR2 => common.copyWith(
        server: RegExp(r'^https://(.+)\.r2\.cloudflarestorage\.com$')
            .firstMatch(endpoint)
            ?.group(1),
        bucket: destination.bucket,
      ),
      hetznerStorageBox => common,
      immich => PresetInput(server: _withoutHttps(endpoint)),
      custom => common.copyWith(
        type: destination.type,
        server: endpoint,
        region: destination.region,
        bucket: destination.bucket,
        pathStyle: destination.pathStyle,
      ),
      _ => null,
    };
    if (input == null || typeFor(input) != destination.type) return null;
    return build(input).fingerprint == destination.fingerprint ? input : null;
  }

  static String _withScheme(String server) {
    final trimmed = server.endsWith('/')
        ? server.substring(0, server.length - 1)
        : server;
    return trimmed.contains('://') ? trimmed : '$_httpsPrefix$trimmed';
  }

  static String _withoutHttps(String url) =>
      url.startsWith(_httpsPrefix) ? url.substring(_httpsPrefix.length) : url;
}
