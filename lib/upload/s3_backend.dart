import 'dart:io';

import 'http_support.dart';
import 'remote_path.dart';
import 'sigv4.dart';
import 'storage_backend.dart';
import 'tcp_connector.dart';

const _metaSha256 = 'x-amz-meta-sha256';

final _errorCode = RegExp(r'<Code>([^<]*)</Code>');

/// S3-compatible object storage. Objects are written directly under their
/// final key with `If-None-Match: *`, which makes the PUT itself the atomic
/// commit; [UploadRequest.tempName] is not needed.
class S3Backend implements StorageBackend {
  S3Backend({
    required this.endpoint,
    required this.region,
    required this.bucket,
    this.basePath = '',
    required String accessKey,
    required String secretKey,
    this.pathStyle = true,
    TcpConnector connector = directConnector,
    String? pinnedCertificate,
    this.clock = DateTime.now,
  }) : _signer = SigV4Signer(
         credentials: SigV4Credentials(accessKey, secretKey),
         region: region,
       ),
       _client = httpClientFor(connector, pinnedCertificate: pinnedCertificate);

  final Uri endpoint;
  final String region;
  final String bucket;
  final String basePath;

  /// `https://endpoint/bucket/key` instead of `https://bucket.endpoint/key`.
  final bool pathStyle;
  final SigV4Signer _signer;
  final DateTime Function() clock;
  final HttpClient _client;

  String _key(RemoteTarget target) => [
    ...pathSegments(basePath),
    ...pathSegments(target.directory),
    target.name,
  ].join('/');

  Future<HttpResult> _send(
    String method,
    String key, {
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    String payloadHash = emptyPayloadHash,
    File? file,
    int? fileLength,
    UploadProgress? onProgress,
  }) {
    final host = pathStyle ? endpoint.host : '$bucket.${endpoint.host}';
    final segments = [
      ...pathSegments(endpoint.path),
      if (pathStyle) bucket,
      if (key.isNotEmpty) key,
    ];
    final path =
        '/${segments.map((s) => uriEncode(s, keepSlash: true)).join('/')}';
    final port = endpoint.hasPort ? ':${endpoint.port}' : '';
    final queryString = query.isEmpty ? '' : '?${canonicalQuery(query)}';
    final uri = Uri.parse('${endpoint.scheme}://$host$port$path$queryString');
    final signed = _signer.sign(
      method: method,
      canonicalPath: path,
      query: query,
      headers: {
        'host': '$host$port',
        'x-amz-content-sha256': payloadHash,
        ...headers,
      },
      payloadHash: payloadHash,
      time: clock(),
    );
    signed.remove('host');
    return sendHttp(
      _client,
      method,
      uri,
      headers: signed,
      file: file,
      fileLength: fileLength,
      onProgress: onProgress,
    );
  }

  StorageException _error(HttpResult result, String what) => statusException(
    result.status,
    what,
    detail: _errorCode.firstMatch(result.body)?.group(1),
  );

  @override
  Future<void> testConnection() async {
    final prefix = pathSegments(basePath).join('/');
    final result = await _send(
      'GET',
      '',
      query: {
        'list-type': '2',
        'max-keys': '1',
        if (prefix.isNotEmpty) 'prefix': '$prefix/',
      },
    );
    if (!result.ok) throw _error(result, 'Bucket $bucket');
  }

  @override
  Future<ProbeResult> probe(
    RemoteTarget target, {
    required int size,
    required String sha256,
  }) async {
    final result = await _send('HEAD', _key(target));
    if (result.status == 404) return ProbeResult.absent;
    if (!result.ok) throw _error(result, '$target');
    return _matches(result, size, sha256)
        ? ProbeResult.identical
        : ProbeResult.different;
  }

  bool _matches(HttpResult head, int size, String sha256) =>
      head.headers.contentLength == size &&
      head.headers.value(_metaSha256) == sha256;

  @override
  Future<UploadResult> upload(
    UploadRequest request, {
    UploadProgress? onProgress,
  }) async {
    final target = request.target;
    final existing = await probe(
      target,
      size: request.size,
      sha256: request.sha256,
    );
    if (existing != ProbeResult.absent) return _occupied(existing);

    Future<HttpResult> put({required bool conditional}) => _send(
      'PUT',
      _key(target),
      headers: {
        _metaSha256: request.sha256,
        if (conditional) 'if-none-match': '*',
      },
      payloadHash: request.sha256,
      file: request.source,
      fileLength: request.size,
      onProgress: onProgress,
    );

    var result = await put(conditional: true);
    if (result.status == 412) {
      return _occupied(
        await probe(target, size: request.size, sha256: request.sha256),
      );
    }
    if (result.status == 501 ||
        (result.status == 400 && result.body.contains('NotImplemented'))) {
      // Conditional writes are unsupported; the probe above found the key
      // free, which is the best this server allows.
      result = await put(conditional: false);
    }
    if (!result.ok) throw _error(result, '$target');

    final head = await _send('HEAD', _key(target));
    if (!head.ok || !_matches(head, request.size, request.sha256)) {
      throw StorageException('Uploaded $target could not be verified.');
    }
    return UploadResult.uploaded;
  }

  UploadResult _occupied(ProbeResult result) => result == ProbeResult.identical
      ? UploadResult.alreadyPresent
      : UploadResult.nameTaken;

  @override
  Future<void> close() async => _client.close(force: true);
}
