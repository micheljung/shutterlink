import 'dart:io';

import 'storage_backend.dart';
import 'trust_pins.dart';

/// Opens a TCP connection for upload traffic. On Android this goes through a
/// native tunnel bound to an internet-capable network; elsewhere it connects
/// directly.
typedef TcpConnector = Future<Socket> Function(String host, int port);

const connectTimeout = Duration(seconds: 15);

Future<Socket> directConnector(String host, int port) =>
    Socket.connect(host, port, timeout: connectTimeout);

/// An [HttpClient] whose connections go through [connector]. HTTPS
/// certificates that fail system validation are accepted only if their
/// SHA-256 matches [pinnedCertificate]; otherwise requests fail with
/// [UntrustedCertificateException].
HttpClient httpClientFor(
  TcpConnector connector, {
  String? pinnedCertificate,
  SecurityContext? context,
}) {
  final client = HttpClient(context: context)
    ..connectionTimeout = connectTimeout;
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    final raw = connector(uri.host, uri.port);
    final socket = uri.scheme == 'https'
        ? raw.then(
            (socket) => _secure(socket, uri.host, pinnedCertificate, context),
          )
        : raw;
    return ConnectionTask.fromSocket(socket, () {
      raw.then((s) => s.destroy(), onError: (_) {});
    });
  };
  return client;
}

Future<Socket> _secure(
  Socket socket,
  String host,
  String? pin,
  SecurityContext? context,
) async {
  String? rejected;
  try {
    return await SecureSocket.secure(
      socket,
      host: host,
      context: context,
      onBadCertificate: (certificate) {
        final fingerprint = certificateFingerprint(certificate);
        if (certificatePinMatches(pin, fingerprint)) return true;
        rejected = fingerprint;
        return false;
      },
    );
  } on HandshakeException {
    socket.destroy();
    final fingerprint = rejected;
    if (fingerprint != null) {
      throw UntrustedCertificateException(fingerprint);
    }
    rethrow;
  }
}
