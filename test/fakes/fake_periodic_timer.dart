import 'dart:async';

/// A periodic timer whose ticks the test fires by hand.
class FakePeriodicTimer implements Timer {
  FakePeriodicTimer(this._onTick);

  final void Function() _onTick;
  bool _active = true;
  int _ticks = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _ticks;

  @override
  void cancel() => _active = false;

  /// Fires one tick unless the timer was cancelled.
  void fire() {
    if (!_active) return;
    _ticks++;
    _onTick();
  }
}

/// Hands out [FakePeriodicTimer]s and remembers them.
class FakePeriodicTimers {
  final created = <FakePeriodicTimer>[];

  Timer create(Duration interval, void Function() onTick) {
    final timer = FakePeriodicTimer(onTick);
    created.add(timer);
    return timer;
  }

  /// Fires every live timer once.
  void tick() {
    for (final timer in [...created]) {
      timer.fire();
    }
  }
}
