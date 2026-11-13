import 'dart:async';
import 'dart:io';

import 'store.dart';

const Duration cleanupInterval = Duration(hours: 1);

class Cleanup {
  Cleanup._(this._store);

  static Future<Cleanup> start(SessionStore store) async {
    final cleanup = Cleanup._(store);
    await cleanup._run();
    cleanup._timer = Timer.periodic(cleanupInterval, (_) => cleanup._run());
    return cleanup;
  }

  final SessionStore _store;
  Timer? _timer;
  Future<void>? _running;

  Future<void> _run() {
    return _running ??= _store
        .purgeExpired()
        .catchError((Object error) => stderr.writeln('Cleanup failed: $error'))
        .whenComplete(() => _running = null);
  }

  Future<void> stop() async {
    _timer?.cancel();
    await _running;
  }
}
