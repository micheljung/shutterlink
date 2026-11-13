import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

import 'serve.dart';

/// In-memory WebDAV server that behaves like Nextcloud where it matters:
/// MKCOL needs an existing parent, MOVE honours `Overwrite`, and `*.part`
/// names are forbidden.
class WebDavTestServer {
  WebDavTestServer._(this._server);

  static Future<WebDavTestServer> start({
    String username = 'alice',
    String password = 'secret',
    List<String> collections = const [],
    bool tls = false,
  }) async {
    late WebDavTestServer fake;
    final server = await serveLoopback((r) => fake._handle(r), tls: tls);
    fake = WebDavTestServer._(server)
      .._username = username
      .._password = password;
    for (final c in collections) {
      final parts = c.split('/').where((s) => s.isNotEmpty).toList();
      for (var i = 1; i <= parts.length; i++) {
        fake.collections.add(parts.take(i).join('/'));
      }
    }
    return fake;
  }

  final HttpServer _server;
  late String _username;
  late String _password;

  final files = <String, Uint8List>{};
  final collections = <String>{''};
  final requests = <String>[];

  /// Answers a request before normal handling when it returns non-null.
  Response? Function(Request request)? intercept;

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);

  String _pathOf(Uri uri) =>
      uri.pathSegments.where((s) => s.isNotEmpty).join('/');

  String _parent(String path) =>
      path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';

  Future<Response> _handle(Request request) async {
    final path = _pathOf(request.requestedUri);
    requests.add('${request.method} /$path');
    final intercepted = intercept?.call(request);
    if (intercepted != null) return intercepted;

    final expected =
        'Basic ${base64.encode(utf8.encode('$_username:$_password'))}';
    if (request.headers['authorization'] != expected) {
      return Response(401, headers: {'WWW-Authenticate': 'Basic'});
    }

    switch (request.method) {
      case 'PROPFIND':
        return _propfind(path);
      case 'MKCOL':
        if (collections.contains(path) || files.containsKey(path)) {
          return Response(405);
        }
        if (!collections.contains(_parent(path))) return Response(409);
        collections.add(path);
        return Response(201);
      case 'PUT':
        if (path.endsWith('.part')) return Response.forbidden('No .part');
        if (collections.contains(path)) return Response(405);
        if (!collections.contains(_parent(path))) return Response(409);
        final existed = files.containsKey(path);
        final bytes = BytesBuilder();
        try {
          await request.read().forEach(bytes.add);
        } on HttpException {
          return Response(400);
        }
        files[path] = bytes.takeBytes();
        return Response(existed ? 204 : 201);
      case 'MOVE':
        final source = files[path];
        if (source == null) return Response.notFound('');
        final destination = _pathOf(Uri.parse(request.headers['destination']!));
        if (files.containsKey(destination) &&
            request.headers['overwrite'] == 'F') {
          return Response(412);
        }
        if (!collections.contains(_parent(destination))) {
          return Response(409);
        }
        files.remove(path);
        files[destination] = source;
        return Response(201);
      case 'DELETE':
        return files.remove(path) == null
            ? Response.notFound('')
            : Response(204);
    }
    return Response(405);
  }

  Response _propfind(String path) {
    final file = files[path];
    final String prop;
    if (file != null) {
      prop =
          '<d:getcontentlength>${file.length}</d:getcontentlength>'
          '<d:resourcetype/>';
    } else if (collections.contains(path)) {
      prop = '<d:resourcetype><d:collection/></d:resourcetype>';
    } else {
      return Response.notFound('');
    }
    return Response(
      207,
      headers: {'Content-Type': 'application/xml; charset=utf-8'},
      body:
          '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response>'
          '<d:href>/$path</d:href><d:propstat><d:prop>$prop</d:prop>'
          '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
          '</d:multistatus>',
    );
  }
}
