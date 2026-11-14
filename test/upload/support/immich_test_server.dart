import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart';

import 'serve.dart';

const uploadPermission = 'asset.upload';

/// One stored asset with the multipart fields it was uploaded with.
class ImmichAsset {
  const ImmichAsset(this.id, this.bytes, this.fields, this.filename);

  final String id;
  final Uint8List bytes;
  final Map<String, String> fields;

  /// The `filename` parameter of the `assetData` part.
  final String? filename;
}

/// In-memory Immich server following the OpenAPI spec for `/server/ping`,
/// `/assets` and `/assets/bulk-upload-check`: assets are keyed by SHA-1,
/// the `x-immich-checksum` header short-circuits a known asset as
/// `duplicate` like the real server, and uploads need the v2 device fields.
class ImmichTestServer {
  ImmichTestServer._(this._server);

  static Future<ImmichTestServer> start({
    String apiKey = 'immich-key',
    Set<String> permissions = const {uploadPermission},
    bool tls = false,
  }) async {
    late ImmichTestServer fake;
    final server = await serveLoopback((r) => fake._handle(r), tls: tls);
    return fake = ImmichTestServer._(server)
      ..apiKey = apiKey
      ..permissions = permissions;
  }

  final HttpServer _server;
  late String apiKey;
  late Set<String> permissions;

  /// Keyed by lowercase hex SHA-1.
  final assets = <String, ImmichAsset>{};
  final requests = <String>[];

  /// Answers a request before normal handling when it returns non-null.
  Response? Function(Request request)? intercept;

  /// Stores the next new asset but answers 502, like a proxy that lost the
  /// response.
  bool loseNextUploadResponse = false;

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);

  Future<Response> _handle(Request request) async {
    final path = '/${request.url.path}';
    requests.add('${request.method} $path');
    final intercepted = intercept?.call(request);
    if (intercepted != null) return intercepted;

    if (request.method == 'GET' && path == '/api/server/ping') {
      return _json(200, {'res': 'pong'});
    }
    if (request.headers['x-api-key'] != apiKey) {
      return _json(401, {
        'message': 'Invalid API key',
        'error': 'Unauthorized',
        'statusCode': 401,
      });
    }
    final route = '${request.method} $path';
    if (route != 'POST /api/assets' &&
        route != 'POST /api/assets/bulk-upload-check') {
      return _json(404, {'message': 'Cannot $route', 'statusCode': 404});
    }
    if (!permissions.contains(uploadPermission)) {
      return _json(403, {
        'message': 'Missing required permission: $uploadPermission',
        'error': 'Forbidden',
        'statusCode': 403,
      });
    }
    return route == 'POST /api/assets'
        ? _upload(request)
        : _bulkUploadCheck(request);
  }

  Future<Response> _bulkUploadCheck(Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map;
    final results = [
      for (final item in (body['assets'] as List).cast<Map>())
        _checkResult(item['id'] as String, item['checksum'] as String),
    ];
    return _json(200, {'results': results});
  }

  Map<String, Object> _checkResult(String id, String checksum) {
    final known = _knownAsset(checksum);
    return known == null
        ? {'id': id, 'action': 'accept'}
        : {
            'id': id,
            'action': 'reject',
            'reason': 'duplicate',
            'assetId': known.id,
            'isTrashed': false,
          };
  }

  ImmichAsset? _knownAsset(String checksum) =>
      assets[checksum.length == 28
          ? base64Decode(checksum).map(_hex).join()
          : checksum.toLowerCase()];

  static String _hex(int byte) => byte.toRadixString(16).padLeft(2, '0');

  Future<Response> _upload(Request request) async {
    final header = request.headers['x-immich-checksum'];
    final announced = header == null ? null : _knownAsset(header);
    final contentType = HeaderValue.parse(
      request.headers['content-type'] ?? '',
    );
    final boundary = contentType.parameters['boundary'];
    if (contentType.value != 'multipart/form-data' || boundary == null) {
      return _badRequest('Expected multipart/form-data');
    }

    final fields = <String, String>{};
    Uint8List? data;
    String? filename;
    try {
      await for (final part in MimeMultipartTransformer(
        boundary,
      ).bind(request.read())) {
        final disposition = HeaderValue.parse(
          part.headers['content-disposition'] ?? '',
        );
        final name = disposition.parameters['name'];
        final bytes = await part.fold<BytesBuilder>(
          BytesBuilder(),
          (b, chunk) => b..add(chunk),
        );
        if (name == 'assetData') {
          data = bytes.takeBytes();
          filename = disposition.parameters['filename'];
        } else if (name != null) {
          fields[name] = utf8.decode(bytes.takeBytes());
        }
      }
    } on HttpException {
      return _badRequest('Upload interrupted');
    } on MimeMultipartException {
      return _badRequest('Malformed multipart body');
    }
    if (announced != null) {
      return _json(200, {'id': announced.id, 'status': 'duplicate'});
    }
    final asset = data;
    if (asset == null) return _badRequest('assetData is required');
    final invalid = [
      for (final field in const ['deviceAssetId', 'deviceId'])
        if (fields[field]?.isNotEmpty != true) '$field must be a string',
      for (final field in const ['fileCreatedAt', 'fileModifiedAt'])
        if (DateTime.tryParse(fields[field] ?? '') == null)
          '$field must be an ISO 8601 date',
    ];
    if (invalid.isNotEmpty) {
      return _json(400, {
        'message': invalid,
        'error': 'Bad Request',
        'statusCode': 400,
      });
    }
    final checksum = sha1.convert(asset).toString();
    if (header != null && header.toLowerCase() != checksum) {
      return _badRequest('x-immich-checksum does not match the file');
    }
    final existing = assets[checksum];
    if (existing != null) {
      return _json(200, {'id': existing.id, 'status': 'duplicate'});
    }
    final id = 'asset-${assets.length + 1}';
    assets[checksum] = ImmichAsset(id, asset, fields, filename);
    if (loseNextUploadResponse) {
      loseNextUploadResponse = false;
      return Response(502);
    }
    return _json(201, {'id': id, 'status': 'created'});
  }

  Response _badRequest(String message) =>
      _json(400, {'message': message, 'statusCode': 400});

  static Response _json(int status, Object body) => Response(
    status,
    body: jsonEncode(body),
    headers: {'Content-Type': 'application/json; charset=utf-8'},
  );
}
