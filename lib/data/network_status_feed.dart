import 'dart:async';

import 'package:flutter/foundation.dart';

import '../upload/network_policy.dart';

/// Shares one platform network subscription. The platform serves a single
/// listener and reports the current networks only when it starts listening,
/// so every later listener first receives the latest status.
class NetworkStatusFeed implements ValueListenable<NetworkStatus> {
  NetworkStatusFeed(
    Stream<NetworkStatus> source, {
    required NetworkStatus initial,
  }) : _status = ValueNotifier(initial) {
    _subscription = source.listen((status) {
      _status.value = status;
      _changes.add(status);
    });
  }

  final ValueNotifier<NetworkStatus> _status;
  final _changes = StreamController<NetworkStatus>.broadcast(sync: true);
  late final StreamSubscription<NetworkStatus> _subscription;

  @override
  NetworkStatus get value => _status.value;

  @override
  void addListener(VoidCallback listener) => _status.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _status.removeListener(listener);

  Stream<NetworkStatus> get statuses => Stream.multi((controller) {
    controller.add(_status.value);
    final changes = _changes.stream.listen(controller.add);
    controller.onCancel = changes.cancel;
  });

  Future<void> dispose() async {
    await _subscription.cancel();
    await _changes.close();
    _status.dispose();
  }
}
