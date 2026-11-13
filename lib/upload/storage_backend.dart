import 'dart:io';

import 'package:equatable/equatable.dart';

/// A file location relative to the destination's base path.
class RemoteTarget extends Equatable {
  const RemoteTarget({required this.directory, required this.name});

  /// The date directory, e.g. `2026-11-13`.
  final String directory;
  final String name;

  @override
  List<Object?> get props => [directory, name];

  @override
  String toString() => '$directory/$name';
}

class UploadRequest extends Equatable {
  const UploadRequest({
    required this.source,
    required this.target,
    required this.tempName,
    required this.size,
    required this.sha256,
  });

  final File source;
  final RemoteTarget target;

  /// Name of the temporary file in [RemoteTarget.directory]; reused across
  /// retries so an interrupted upload never leaves a second orphan behind.
  final String tempName;
  final int size;

  /// Lowercase hex SHA-256 of [source].
  final String sha256;

  @override
  List<Object?> get props => [source.path, target, tempName, size, sha256];
}

enum ProbeResult {
  absent,

  /// Same size (and, where the backend can tell, same SHA-256).
  identical,
  different,
}

enum UploadResult {
  uploaded,

  /// An identical file already occupied the target name.
  alreadyPresent,

  /// A different file occupies the target name; pick the next candidate.
  nameTaken,
}

typedef UploadProgress = void Function(int sentBytes, int totalBytes);

abstract interface class StorageBackend {
  Future<ProbeResult> probe(
    RemoteTarget target, {
    required int size,
    required String sha256,
  });

  /// Writes [UploadRequest.tempName], then commits it to the target name
  /// without overwriting and verifies the committed size.
  Future<UploadResult> upload(
    UploadRequest request, {
    UploadProgress? onProgress,
  });

  Future<void> testConnection();

  Future<void> close();
}

class StorageException implements Exception {
  const StorageException(this.message, {this.retryable = true});

  /// Readable for the user, e.g. shown by "Test connection".
  final String message;

  /// Whether retrying later may succeed without the user changing anything.
  final bool retryable;

  @override
  String toString() => message;
}

/// The server's TLS certificate failed system validation and does not match
/// the stored pin. The user may trust [fingerprint] after confirming it.
class UntrustedCertificateException extends StorageException {
  const UntrustedCertificateException(this.fingerprint)
    : super(
        'The server certificate is not trusted '
        '(SHA-256 $fingerprint).',
        retryable: false,
      );

  final String fingerprint;
}

/// The SSH host key does not match the stored pin, or none is stored yet.
class UnknownHostKeyException extends StorageException {
  const UnknownHostKeyException(this.keyType, this.fingerprint)
    : super(
        'The server host key is not trusted ($keyType $fingerprint).',
        retryable: false,
      );

  final String keyType;

  /// OpenSSH style, e.g. `SHA256:base64`.
  final String fingerprint;
}
