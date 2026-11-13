import 'dart:async';
import 'dart:io';

/// A loopback TCP proxy to [targetPort] that cuts the first [dropFirst]
/// connections after [dropAfterBytes] client-to-server bytes.
class DroppingProxy {
  DroppingProxy._(this._server, this.targetPort);

  static Future<DroppingProxy> start(
    int targetPort, {
    int dropAfterBytes = 0,
    int dropFirst = 1,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = DroppingProxy._(server, targetPort)
      .._dropAfterBytes = dropAfterBytes
      .._remainingDrops = dropFirst;
    server.listen(proxy._accept);
    return proxy;
  }

  final ServerSocket _server;
  final int targetPort;
  late int _dropAfterBytes;
  late int _remainingDrops;
  int connections = 0;
  int drops = 0;

  /// A connector for the backends; the host name is ignored.
  Future<Socket> connect(String host, int port) =>
      Socket.connect(InternetAddress.loopbackIPv4, _server.port);

  Future<void> _accept(Socket client) async {
    connections++;
    final upstream = await Socket.connect(
      InternetAddress.loopbackIPv4,
      targetPort,
    );
    var forwarded = 0;
    var dropping = _remainingDrops > 0;

    client.listen(
      (data) {
        if (dropping && forwarded + data.length > _dropAfterBytes) {
          final keep = _dropAfterBytes - forwarded;
          if (keep > 0) upstream.add(data.sublist(0, keep));
          dropping = false;
          _remainingDrops--;
          drops++;
          client.destroy();
          upstream.destroy();
          return;
        }
        forwarded += data.length;
        upstream.add(data);
      },
      onDone: upstream.destroy,
      onError: (Object _) => upstream.destroy(),
      cancelOnError: true,
    );
    upstream.listen(
      client.add,
      onDone: client.destroy,
      onError: (Object _) => client.destroy(),
      cancelOnError: true,
    );
  }

  Future<void> close() => _server.close();
}
