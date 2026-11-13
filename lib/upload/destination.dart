import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:equatable/equatable.dart';

import 'network_policy.dart';

enum DestinationType { webdav, s3, sftp }

/// The single configured upload target, without secrets.
class Destination extends Equatable {
  const Destination({
    required this.type,
    required this.endpoint,
    this.region = '',
    this.bucket = '',
    this.basePath = '',
    this.username = '',
    this.pathStyle = false,
    this.policy = MobileDataPolicy.off,
    this.keepLocalCopy = true,
  });

  final DestinationType type;

  /// URL for WebDAV/S3, `host:port` for SFTP.
  final String endpoint;
  final String region;
  final String bucket;
  final String basePath;
  final String username;
  final bool pathStyle;
  final MobileDataPolicy policy;
  final bool keepLocalCopy;

  /// Identifies where files land, so a changed server, bucket or path counts
  /// as a new destination while a changed secret or policy does not.
  String get fingerprint => sha256
      .convert(
        utf8.encode(
          [type.name, endpoint, region, bucket, basePath, username].join('|'),
        ),
      )
      .toString();

  @override
  List<Object?> get props => [
    type,
    endpoint,
    region,
    bucket,
    basePath,
    username,
    pathStyle,
    policy,
    keepLocalCopy,
  ];
}
