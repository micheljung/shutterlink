import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';

enum LiveServiceState { connecting, transferring, reconnecting, unreachable }

/// What the Live notification shows.
class LiveStatus extends Equatable {
  const LiveStatus({
    required this.count,
    required this.uploaded,
    required this.pending,
    required this.state,
    required this.text,
  });

  final int count;
  final int uploaded;
  final int pending;
  final LiveServiceState state;
  final String text;

  Map<String, Object> toMap() => {
    'count': count,
    'uploaded': uploaded,
    'pending': pending,
    'state': state.name,
    'text': text,
  };

  @override
  List<Object?> get props => [count, uploaded, pending, state, text];
}

/// Keeps the app running while Live transfers, with a notification that
/// shows progress and offers Stop.
abstract interface class LiveService {
  Future<void> start(LiveStatus status);

  Future<void> updateStatus(LiveStatus status);

  Future<void> stop();

  /// Whether status notifications may be shown.
  Future<bool> requestNotificationPermission();

  /// The user tapped Stop in the notification.
  Stream<void> get stopRequests;
}

/// Android foreground service bridge. Other platforms keep no service.
class PlatformLiveService implements LiveService {
  PlatformLiveService({bool? isAndroid})
    : _isAndroid = isAndroid ?? Platform.isAndroid {
    if (_isAndroid) channel.setMethodCallHandler(_handle);
  }

  static const channel = MethodChannel('ch.micheljung.shutterlink/live');
  static const stopRequestedMethod = 'stopRequested';

  final bool _isAndroid;
  final _stopRequests = StreamController<void>.broadcast();

  @override
  Stream<void> get stopRequests => _stopRequests.stream;

  @override
  Future<void> start(LiveStatus status) => _invoke('start', status.toMap());

  @override
  Future<void> updateStatus(LiveStatus status) =>
      _invoke('updateStatus', status.toMap());

  @override
  Future<void> stop() => _invoke('stop');

  @override
  Future<bool> requestNotificationPermission() async {
    if (!_isAndroid) return true;
    return await channel.invokeMethod<bool>('requestNotificationPermission') ??
        false;
  }

  Future<void> _invoke(String method, [Map<String, Object>? arguments]) async {
    if (!_isAndroid) return;
    await channel.invokeMethod<void>(method, arguments);
  }

  Future<Object?> _handle(MethodCall call) async {
    if (call.method != stopRequestedMethod) {
      throw MissingPluginException(call.method);
    }
    _stopRequests.add(null);
    return null;
  }
}
