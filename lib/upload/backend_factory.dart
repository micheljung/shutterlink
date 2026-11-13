import 'package:equatable/equatable.dart';

import 'destination.dart';
import 's3_backend.dart';
import 'sftp_backend.dart';
import 'storage_backend.dart';
import 'tcp_connector.dart';
import 'upload_queue.dart';
import 'webdav_backend.dart';

/// Signing region for S3-compatible servers that ignore regions, e.g. MinIO.
const defaultS3Region = 'us-east-1';
const defaultSftpPort = 22;

/// The secret half of a [Destination], kept out of plain preferences.
class DestinationSecrets extends Equatable {
  const DestinationSecrets({
    this.password = '',
    this.privateKey = '',
    this.passphrase = '',
    this.certificatePin,
    this.hostKeyPin,
  });

  factory DestinationSecrets.fromJson(Map<String, Object?> json) =>
      DestinationSecrets(
        password: json['password'] as String? ?? '',
        privateKey: json['privateKey'] as String? ?? '',
        passphrase: json['passphrase'] as String? ?? '',
        certificatePin: json['certificatePin'] as String?,
        hostKeyPin: json['hostKeyPin'] as String?,
      );

  /// The WebDAV or SFTP password, or the S3 secret access key.
  final String password;

  /// PEM, for SFTP key authentication.
  final String privateKey;
  final String passphrase;

  /// SHA-256 of a TLS certificate the user chose to trust.
  final String? certificatePin;

  /// OpenSSH style `SHA256:<base64>` of the SFTP host key.
  final String? hostKeyPin;

  Map<String, Object?> toJson() => {
    'password': password,
    'privateKey': privateKey,
    'passphrase': passphrase,
    'certificatePin': certificatePin,
    'hostKeyPin': hostKeyPin,
  };

  DestinationSecrets copyWith({
    String? Function()? certificatePin,
    String? Function()? hostKeyPin,
  }) => DestinationSecrets(
    password: password,
    privateKey: privateKey,
    passphrase: passphrase,
    certificatePin: certificatePin != null
        ? certificatePin()
        : this.certificatePin,
    hostKeyPin: hostKeyPin != null ? hostKeyPin() : this.hostKeyPin,
  );

  @override
  List<Object?> get props => [
    password,
    privateKey,
    passphrase,
    certificatePin,
    hostKeyPin,
  ];
}

/// The secrets could not be read, so uploads pause until the user enters
/// them again.
class CredentialsMissingException extends StorageException {
  const CredentialsMissingException()
    : super(
        'The upload credentials are missing. Enter them again in Settings.',
        retryable: false,
      );
}

const _invalidAddress = StorageException(
  'The server address is not valid.',
  retryable: false,
);

Uri _httpEndpoint(String endpoint) {
  final uri = Uri.tryParse(endpoint.trim());
  if (uri == null ||
      !(uri.isScheme('http') || uri.isScheme('https')) ||
      uri.host.isEmpty) {
    throw _invalidAddress;
  }
  return uri;
}

({String host, int port}) _sshEndpoint(String endpoint) {
  final trimmed = endpoint.trim();
  final uri = Uri.tryParse(
    trimmed.startsWith('sftp://') ? trimmed : 'sftp://$trimmed',
  );
  if (uri == null || uri.host.isEmpty) throw _invalidAddress;
  return (host: uri.host, port: uri.hasPort ? uri.port : defaultSftpPort);
}

String? _nonEmpty(String value) => value.isEmpty ? null : value;

/// Throws a [StorageException] if [destination] cannot be addressed.
StorageBackend createBackend(
  Destination destination,
  DestinationSecrets secrets, {
  TcpConnector connector = directConnector,
}) {
  switch (destination.type) {
    case DestinationType.webdav:
      return WebDavBackend(
        endpoint: _httpEndpoint(destination.endpoint),
        basePath: destination.basePath,
        username: destination.username,
        password: secrets.password,
        connector: connector,
        pinnedCertificate: secrets.certificatePin,
      );
    case DestinationType.s3:
      return S3Backend(
        endpoint: _httpEndpoint(destination.endpoint),
        region: destination.region.isEmpty
            ? defaultS3Region
            : destination.region,
        bucket: destination.bucket,
        basePath: destination.basePath,
        accessKey: destination.username,
        secretKey: secrets.password,
        pathStyle: destination.pathStyle,
        connector: connector,
        pinnedCertificate: secrets.certificatePin,
      );
    case DestinationType.sftp:
      final address = _sshEndpoint(destination.endpoint);
      final privateKey = _nonEmpty(secrets.privateKey);
      return SftpBackend(
        host: address.host,
        port: address.port,
        username: destination.username,
        password: privateKey == null ? _nonEmpty(secrets.password) : null,
        privateKey: privateKey,
        passphrase: _nonEmpty(secrets.passphrase),
        basePath: destination.basePath,
        pinnedHostKey: secrets.hostKeyPin,
        connector: connector,
      );
  }
}

/// The queue's [BackendFactory]: reads the secrets on every attempt so a
/// lost Keystore surfaces as [CredentialsMissingException] on the item.
BackendFactory destinationBackendFactory(
  Future<DestinationSecrets> Function() readSecrets, {
  NetworkTcpConnector connector = directNetworkConnector,
}) =>
    (destination, {required allowMetered}) async => createBackend(
      destination,
      await readSecrets(),
      connector: withMeteredPolicy(connector, allowMetered: allowMetered),
    );

/// Runs "Test connection" for a destination that need not be saved yet.
/// Mobile data is allowed since the user asked for it explicitly.
Future<void> testDestination(
  Destination destination,
  DestinationSecrets secrets, {
  NetworkTcpConnector connector = directNetworkConnector,
}) async {
  final backend = createBackend(
    destination,
    secrets,
    connector: withMeteredPolicy(connector, allowMetered: true),
  );
  try {
    await backend.testConnection();
  } finally {
    await backend.close();
  }
}
