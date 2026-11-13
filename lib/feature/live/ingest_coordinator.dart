import 'dart:async';

/// Serializes ingest work per download history entry key, so a manual
/// download and a Live ingest of the same file never run at once. A later
/// requester waits for the earlier one and then re-checks what is left.
class IngestCoordinator {
  final _inFlight = <String, Future<void>>{};

  bool isInFlight(String key) => _inFlight.containsKey(key);

  Future<T> run<T>(Iterable<String> keys, Future<T> Function() body) async {
    final wanted = keys.toSet();
    while (true) {
      final busy = [for (final key in wanted) ?_inFlight[key]];
      if (busy.isEmpty) break;
      await Future.wait(busy);
    }
    final done = Completer<void>();
    for (final key in wanted) {
      _inFlight[key] = done.future;
    }
    try {
      return await body();
    } finally {
      wanted.forEach(_inFlight.remove);
      done.complete();
    }
  }
}
