import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

const _certs = 'test/upload/support/certs';

/// Serves [handler] on an ephemeral loopback port, optionally over TLS with
/// a self-signed certificate.
Future<HttpServer> serveLoopback(Handler handler, {bool tls = false}) {
  final context = tls
      ? (SecurityContext()
          ..useCertificateChain('$_certs/cert.pem')
          ..usePrivateKey('$_certs/key.pem'))
      : null;
  return shelf_io.serve(
    handler,
    InternetAddress.loopbackIPv4,
    0,
    securityContext: context,
  );
}

/// Connects any host name to [port] on loopback, standing in for DNS.
Future<Socket> Function(String, int) loopbackConnector(
  int port, {
  List<String>? hosts,
}) => (host, _) {
  hosts?.add(host);
  return Socket.connect(InternetAddress.loopbackIPv4, port);
};
