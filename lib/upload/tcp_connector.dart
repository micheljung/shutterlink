import 'dart:io';

/// Opens a TCP connection for upload traffic. On Android this goes through a
/// native tunnel bound to an internet-capable network; elsewhere it connects
/// directly.
typedef TcpConnector = Future<Socket> Function(String host, int port);

const connectTimeout = Duration(seconds: 15);

Future<Socket> directConnector(String host, int port) =>
    Socket.connect(host, port, timeout: connectTimeout);
