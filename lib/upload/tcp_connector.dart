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

/// A connector that can be told whether metered networks (mobile data) may
/// carry the connection. The network policy decides per file kind.
typedef NetworkTcpConnector = Future<Socket> Function(
  String host,
  int port, {
  required bool allowMetered,
});

/// Ignores [allowMetered]; for platforms without network selection.
Future<Socket> directNetworkConnector(
  String host,
  int port, {
  required bool allowMetered,
}) => directConnector(host, port);

/// Fixes [allowMetered] so the result can be handed to a backend. Build one
/// backend per policy outcome.
TcpConnector withMeteredPolicy(
  NetworkTcpConnector connector, {
  required bool allowMetered,
}) =>
    (host, port) => connector(host, port, allowMetered: allowMetered);

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
