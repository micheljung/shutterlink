import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';

import 'serve.dart';

class S3Object {
  S3Object(this.bytes, this.meta);

  final Uint8List bytes;
  final Map<String, String> meta;
}

/// In-memory S3 server that verifies SigV4 with its own implementation,
/// supports path-style and virtual-host addressing via the `Host` header,
/// PUT with `If-None-Match`, HEAD and ListObjectsV2.
class S3TestServer {
  S3TestServer._(this._server);

  static Future<S3TestServer> start({
    String accessKey = 'AKIDTEST',
    String secretKey = 'test-secret',
    String region = 'eu-central-1',
    List<String> buckets = const ['photos'],
    bool tls = false,
  }) async {
    late S3TestServer fake;
    final server = await serveLoopback((r) => fake._handle(r), tls: tls);
    fake = S3TestServer._(server)
      .._accessKey = accessKey
      .._secretKey = secretKey
      .._region = region;
    for (final b in buckets) {
      fake.buckets[b] = {};
    }
    return fake;
  }

  final HttpServer _server;
  late String _accessKey;
  late String _secretKey;
  late String _region;

  final buckets = <String, Map<String, S3Object>>{};
  final requests = <String>[];

  /// When false, a PUT with `If-None-Match` answers 501 like older servers.
  bool supportsConditionalWrites = true;

  /// Answers a request before normal handling when it returns non-null.
  Response? Function(Request request)? intercept;

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);

  Response _error(int status, String code) => Response(
    status,
    headers: {'Content-Type': 'application/xml'},
    body: '<?xml version="1.0"?><Error><Code>$code</Code></Error>',
  );

  Future<Response> _handle(Request request) async {
    final host = request.headers['host']!.split(':').first;
    final segments = request.requestedUri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList();
    final String bucket;
    final String key;
    final virtual = buckets.keys.where((b) => host.startsWith('$b.'));
    if (virtual.isNotEmpty) {
      bucket = virtual.first;
      key = segments.join('/');
    } else {
      bucket = segments.isEmpty ? '' : segments.first;
      key = segments.skip(1).join('/');
    }
    requests.add('${request.method} $bucket/$key');
    final intercepted = intercept?.call(request);
    if (intercepted != null) return intercepted;

    final body = BytesBuilder();
    try {
      await request.read().forEach(body.add);
    } on HttpException {
      return Response(400);
    }
    final bytes = body.takeBytes();

    final authError = _verifySignature(request, bytes);
    if (authError != null) return authError;

    final objects = buckets[bucket];
    if (objects == null) return _error(404, 'NoSuchBucket');

    switch (request.method) {
      case 'GET' when key.isEmpty:
        final query = request.requestedUri.queryParameters;
        final prefix = query['prefix'] ?? '';
        final max = int.parse(query['max-keys'] ?? '1000');
        final keys = objects.keys.where((k) => k.startsWith(prefix)).take(max);
        return Response.ok(
          '<?xml version="1.0"?><ListBucketResult>'
          '${keys.map((k) => '<Contents><Key>$k</Key></Contents>').join()}'
          '</ListBucketResult>',
          headers: {'Content-Type': 'application/xml'},
        );
      case 'HEAD':
        final object = objects[key];
        if (object == null) return Response.notFound(null);
        return Response.ok(
          null,
          headers: {
            'content-length': '${object.bytes.length}',
            for (final m in object.meta.entries) m.key: m.value,
          },
        );
      case 'PUT':
        if (request.headers['if-none-match'] != null) {
          if (!supportsConditionalWrites) return _error(501, 'NotImplemented');
          if (objects.containsKey(key)) {
            return _error(412, 'PreconditionFailed');
          }
        }
        objects[key] = S3Object(bytes, {
          for (final h in request.headers.entries)
            if (h.key.startsWith('x-amz-meta-')) h.key: h.value,
        });
        return Response.ok(null);
    }
    return _error(405, 'MethodNotAllowed');
  }

  Response? _verifySignature(Request request, Uint8List body) {
    final authorization = request.headers['authorization'];
    final match = RegExp(
      r'^AWS4-HMAC-SHA256 Credential=([^/]+)/(\d{8})/([^/]+)/s3/aws4_request, '
      r'SignedHeaders=([^,]+), Signature=([0-9a-f]{64})$',
    ).firstMatch(authorization ?? '');
    if (match == null) return _error(400, 'AuthorizationHeaderMalformed');
    if (match.group(1) != _accessKey) return _error(403, 'InvalidAccessKeyId');
    if (match.group(3) != _region) {
      return _error(400, 'AuthorizationHeaderMalformed');
    }
    final payloadHash = request.headers['x-amz-content-sha256']!;
    if (payloadHash != sha256.convert(body).toString()) {
      return _error(400, 'XAmzContentSHA256Mismatch');
    }

    String encode(String s) =>
        Uri.encodeComponent(s)
            .replaceAll('!', '%21')
            .replaceAll("'", '%27')
            .replaceAll('(', '%28')
            .replaceAll(')', '%29')
            .replaceAll('*', '%2A');
    final query =
        request.requestedUri.queryParameters.entries
            .map((e) => '${encode(e.key)}=${encode(e.value)}')
            .toList()
          ..sort();
    final signedHeaders = match.group(4)!.split(';');
    final canonical = [
      request.method,
      request.requestedUri.path,
      query.join('&'),
      for (final h in signedHeaders)
        '$h:${request.headers[h]!.trim().replaceAll(RegExp(r' +'), ' ')}',
      '',
      signedHeaders.join(';'),
      payloadHash,
    ].join('\n');
    final date = request.headers['x-amz-date']!;
    final scope = '${match.group(2)}/$_region/s3/aws4_request';
    final toSign =
        'AWS4-HMAC-SHA256\n$date\n$scope\n'
        '${sha256.convert(utf8.encode(canonical))}';
    List<int> mac(List<int> key, String data) =>
        Hmac(sha256, key).convert(utf8.encode(data)).bytes;
    final key = mac(
      mac(
        mac(mac(utf8.encode('AWS4$_secretKey'), match.group(2)!), _region),
        's3',
      ),
      'aws4_request',
    );
    final expected = Hmac(sha256, key).convert(utf8.encode(toSign)).toString();
    if (expected != match.group(5)) return _error(403, 'SignatureDoesNotMatch');
    return null;
  }
}
