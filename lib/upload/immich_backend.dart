import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'http_support.dart';
import 'storage_backend.dart';
import 'tcp_connector.dart';

const _apiSegment = 'api';
const _deviceId = 'shutterlink';
const _pong = 'pong';
const _created = 'created';
const _duplicate = 'duplicate';
const _reject = 'reject';
const _crlf = '\r\n';

/// SHA-1 of empty input; any checksum will do to prove the key may upload.
const _emptySha1 = 'da39a3ee5e6b4b0d3255bfef95601890afd80709';

/// [endpoint] without a trailing `/api` segment, since the API paths are
/// appended to the server root.
Uri immichServerRoot(Uri endpoint) {
  final segments = endpoint.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isNotEmpty && segments.last == _apiSegment) {
    segments.removeLast();
  }
  return endpoint.replace(pathSegments: segments);
}

/// Uploads to the Immich timeline. Immich identifies assets by content, so
/// names never collide and an identical photo counts as already present.
class ImmichBackend implements StorageBackend {
  ImmichBackend({
    required Uri endpoint,
    required this._apiKey,
    TcpConnector connector = directConnector,
    String? pinnedCertificate,
  }) : endpoint = immichServerRoot(endpoint),
       _client = httpClientFor(connector, pinnedCertificate: pinnedCertificate);

  /// The server root, without a trailing `/api`.
  final Uri endpoint;
  final String _apiKey;
  final HttpClient _client;

  Uri _url(List<String> segments) => endpoint.replace(
    pathSegments: [...endpoint.pathSegments, _apiSegment, ...segments],
  );

  Future<HttpResult> _send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
    File? file,
    int? fileLength,
    List<int> filePrefix = const [],
    List<int> fileSuffix = const [],
    UploadProgress? onProgress,
  }) => sendHttp(
    _client,
    method,
    uri,
    headers: {'x-api-key': _apiKey, 'Accept': 'application/json', ...headers},
    body: body,
    file: file,
    fileLength: fileLength,
    filePrefix: filePrefix,
    fileSuffix: fileSuffix,
    onProgress: onProgress,
  );

  @override
  Future<void> testConnection() async {
    final ping = await _send('GET', _url(const ['server', 'ping']));
    if (ping.status == HttpStatus.notFound ||
        (ping.ok && _string(ping.body, 'res') != _pong)) {
      throw StorageException(
        '${endpoint.host} is not an Immich server.',
        retryable: false,
      );
    }
    if (!ping.ok) {
      throw statusException(
        ping.status,
        'The Immich server',
        detail: _message(ping.body),
      );
    }
    await _isUploaded(_deviceId, _emptySha1);
  }

  @override
  Future<ProbeResult> probe(
    RemoteTarget target, {
    required int size,
    required String sha256,
  }) async => ProbeResult.absent;

  /// Whether Immich already has an asset with [checksum].
  Future<bool> _isUploaded(String id, String checksum) async {
    final check = await _send(
      'POST',
      _url(const ['assets', 'bulk-upload-check']),
      headers: {'Content-Type': 'application/json'},
      body: utf8.encode(
        jsonEncode({
          'assets': [
            {'id': id, 'checksum': checksum},
          ],
        }),
      ),
    );
    if (!check.ok) throw _error(check);
    final results = _value(check.body, 'results');
    return results is List &&
        results.any(
          (result) =>
              result is Map &&
              result['action'] == _reject &&
              result['reason'] == _duplicate,
        );
  }

  @override
  Future<UploadResult> upload(
    UploadRequest request, {
    UploadProgress? onProgress,
  }) async {
    final file = request.source;
    final name = request.target.name;
    final checksum = (await sha1.bind(file.openRead()).first).toString();
    if (await _isUploaded(name, checksum)) return UploadResult.alreadyPresent;
    final modified = (await file.lastModified()).toUtc().toIso8601String();
    final boundary = 'shutterlink-${const Uuid().v4()}';
    final fields = {
      'deviceAssetId': '$name-${request.size}',
      'deviceId': _deviceId,
      'fileCreatedAt': modified,
      'fileModifiedAt': modified,
      'filename': name,
    };
    final prefix = StringBuffer();
    fields.forEach((field, value) {
      prefix
        ..write('--$boundary$_crlf')
        ..write('Content-Disposition: form-data; name="$field"$_crlf$_crlf')
        ..write('$value$_crlf');
    });
    prefix
      ..write('--$boundary$_crlf')
      ..write(
        'Content-Disposition: form-data; name="assetData"; '
        'filename="${_escape(name)}"$_crlf',
      )
      ..write('Content-Type: application/octet-stream$_crlf$_crlf');

    final result = await _send(
      'POST',
      _url(const ['assets']),
      headers: {
        'Content-Type': 'multipart/form-data; boundary=$boundary',
        'x-immich-checksum': checksum,
      },
      file: file,
      fileLength: request.size,
      filePrefix: utf8.encode(prefix.toString()),
      fileSuffix: utf8.encode('$_crlf--$boundary--$_crlf'),
      onProgress: onProgress,
    );
    if (!result.ok) throw _error(result);
    return switch (_string(result.body, 'status')) {
      _created => UploadResult.uploaded,
      _duplicate => UploadResult.alreadyPresent,
      _ => throw StorageException(
        'Unexpected response from Immich for $name.',
        retryable: false,
      ),
    };
  }

  StorageException _error(HttpResult result) => switch (result.status) {
    HttpStatus.unauthorized => const AuthenticationException(
      'Immich rejected the API key.',
    ),
    HttpStatus.forbidden => const AuthenticationException(
      'The API key lacks the asset.upload permission.',
    ),
    _ => statusException(
      result.status,
      'The Immich API',
      detail: _message(result.body),
    ),
  };

  /// Percent-encodes what would end the quoted multipart parameter.
  static String _escape(String name) => name
      .replaceAll('"', '%22')
      .replaceAll('\r', '%0D')
      .replaceAll('\n', '%0A');

  static Object? _value(String body, String name) {
    try {
      final json = jsonDecode(body);
      return json is Map ? json[name] : null;
    } on FormatException {
      return null;
    }
  }

  static String? _string(String body, String name) =>
      switch (_value(body, name)) {
        final String value => value,
        _ => null,
      };

  /// Immich reports validation errors as a list of messages.
  static String? _message(String body) => switch (_value(body, 'message')) {
    final String message => message,
    final List<Object?> messages => messages.join('; '),
    _ => null,
  };

  @override
  Future<void> close() async => _client.close(force: true);
}
