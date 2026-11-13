import 'dart:async';
import 'dart:collection';

class KeyedMutex {
  final Map<String, Future<void>> _tails = {};

  Future<T> run<T>(String key, Future<T> Function() action) async {
    final previous = _tails[key];
    final done = Completer<void>();
    final tail = done.future;
    _tails[key] = tail;
    try {
      if (previous != null) await previous;
      return await action();
    } finally {
      done.complete();
      if (identical(_tails[key], tail)) _tails.remove(key);
    }
  }
}

class Semaphore {
  Semaphore(this._permits);

  int _permits;
  final Queue<Completer<bool>> _waiters = Queue();

  bool get isHeld => _permits == 0;

  Future<bool> acquire(Duration timeout) {
    if (_permits > 0) {
      _permits--;
      return Future.value(true);
    }
    final waiter = Completer<bool>();
    _waiters.add(waiter);
    return waiter.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(waiter);
        return false;
      },
    );
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(true);
    } else {
      _permits++;
    }
  }
}

class KeyedLock {
  final Map<String, Semaphore> _locks = {};
  final Map<String, int> _users = {};

  bool isLocked(String key) => _locks[key]?.isHeld ?? false;

  Future<bool> acquire(String key, Duration timeout) async {
    final lock = _locks.putIfAbsent(key, () => Semaphore(1));
    _users[key] = (_users[key] ?? 0) + 1;
    final acquired = await lock.acquire(timeout);
    if (!acquired) _forget(key);
    return acquired;
  }

  void release(String key) {
    _locks[key]!.release();
    _forget(key);
  }

  void _forget(String key) {
    final remaining = _users[key]! - 1;
    if (remaining == 0) {
      _users.remove(key);
      _locks.remove(key);
    } else {
      _users[key] = remaining;
    }
  }
}
