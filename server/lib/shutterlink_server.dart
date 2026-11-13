import 'dart:io';

import 'package:clock/clock.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'src/app.dart';
import 'src/cleanup.dart';
import 'src/limits.dart';
import 'src/tips.dart';

export 'src/limits.dart' show defaultRetention;
export 'src/tips.dart';

class ShutterlinkServer {
  ShutterlinkServer._(this._server, this._cleanup, this.url);

  static Future<ShutterlinkServer> start({
    required Directory dataDir,
    required String uploadToken,
    List<Tip> tips = const [],
    Duration retention = defaultRetention,
    Clock clock = const Clock(),
    Object? address,
    int port = 0,
  }) async {
    final app = await ShutterlinkApp.open(
      dataDir: dataDir,
      uploadToken: uploadToken,
      tips: tips,
      retention: retention,
      clock: clock,
    );
    final cleanup = await Cleanup.start(app.store);
    final server = await shelf_io.serve(
      app.handler,
      address ?? InternetAddress.loopbackIPv4,
      port,
      poweredByHeader: null,
    );
    return ShutterlinkServer._(
      server,
      cleanup,
      Uri(scheme: 'http', host: server.address.address, port: server.port),
    );
  }

  final HttpServer _server;
  final Cleanup _cleanup;
  final Uri url;

  Future<void> close() async {
    await _cleanup.stop();
    await _server.close(force: true);
  }
}
