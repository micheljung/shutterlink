import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import 'limits.dart' as limits;
import 'store.dart';

typedef _Listener = StreamController<List<int>>;

/// Server-sent events that only say "something changed": each event carries
/// the Session's new generation, never Session data.
class Doorbell {
  Doorbell(
    this._store, {
    Stream<void>? keepAliveTicks,
    this._perSession = limits.sseStreamsPerSession,
    this._global = limits.sseStreamsGlobal,
  }) {
    _store
      ..onBump = ring
      ..onPurged = detach;
    _ticks = (keepAliveTicks ?? Stream<void>.periodic(limits.sseKeepAlive))
        .listen((_) => _keepAlive());
  }

  static final List<int> opening = utf8.encode(
    'retry: ${limits.sseRetry.inMilliseconds}\n: open\n\n',
  );
  static final List<int> _keepAliveFrame = utf8.encode(':\n\n');

  final SessionStore _store;
  final int _perSession;
  final int _global;
  late final StreamSubscription<void> _ticks;
  final Map<String, Set<_Listener>> _ringable = {};

  /// Every open stream, including those detached by a purge.
  final Set<_Listener> _open = {};
  bool _closed = false;

  @visibleForTesting
  int get openStreams => _open.length;

  String eventId(int generation) => '${_store.bootId}-$generation';

  /// The `Last-Event-ID` or `since` value with a weak-ETag prefix and quotes
  /// removed, or null when there is none.
  static String? normalizeId(String? raw) {
    if (raw == null) return null;
    var id = raw.trim();
    if (id.startsWith('W/')) id = id.substring(2);
    if (id.length >= 2 && id.startsWith('"') && id.endsWith('"')) {
      id = id.substring(1, id.length - 1);
    }
    return id.isEmpty ? null : id;
  }

  /// Opens a stream for the Session [name], or returns null over a cap.
  /// Registration and the catch-up read happen in one synchronous turn, so
  /// no ring is lost in between.
  Stream<List<int>>? open(String name, String? knownId) {
    final listeners = _ringable[name];
    if (_closed ||
        _open.length >= _global ||
        (listeners?.length ?? 0) >= _perSession) {
      return null;
    }
    late final _Listener listener;
    listener = _Listener(onCancel: () => _remove(name, listener));
    _open.add(listener);
    (_ringable[name] ??= {}).add(listener);
    listener.add(opening);
    final generation = _store.generationOf(name);
    if (knownId != null &&
        generation != null &&
        knownId != eventId(generation)) {
      listener.add(_event(generation));
    }
    return listener.stream;
  }

  List<int> _event(int generation) =>
      utf8.encode('id: ${eventId(generation)}\ndata: $generation\n\n');

  void ring(String name, int generation) {
    final listeners = _ringable[name];
    if (listeners == null || _store.generationOf(name) == null) return;
    final event = _event(generation);
    for (final listener in [...listeners]) {
      listener.add(event);
    }
  }

  /// Leaves the streams open with keep-alives only, exactly like the stream
  /// of an unknown code.
  void detach(String name) => _ringable.remove(name);

  void _keepAlive() {
    for (final listener in [..._open]) {
      listener.add(_keepAliveFrame);
    }
  }

  void _remove(String name, _Listener listener) {
    _open.remove(listener);
    final listeners = _ringable[name];
    if (listeners == null || !listeners.remove(listener)) return;
    if (listeners.isEmpty) _ringable.remove(name);
  }

  Future<void> close() async {
    _closed = true;
    await _ticks.cancel();
    final listeners = [..._open];
    _open.clear();
    _ringable.clear();
    for (final listener in listeners) {
      unawaited(listener.close());
    }
  }
}
