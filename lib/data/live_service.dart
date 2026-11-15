import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';

enum LiveServiceState { connecting, transferring, reconnecting, unreachable }

/// What the notification of a mode running in the background shows.
class LiveStatus extends Equatable {
  const LiveStatus({
    required this.title,
    required this.count,
    required this.uploaded,
    required this.pending,
    required this.state,
    required this.text,
  });

  /// The running mode's name.
  final String title;
  final int count;
  final int uploaded;
  final int pending;
  final LiveServiceState state;
  final String text;

  Map<String, Object> toMap() => {
    'title': title,
    'count': count,
    'uploaded': uploaded,
    'pending': pending,
    'state': state.name,
    'text': text,
  };

  @override
  List<Object?> get props => [title, count, uploaded, pending, state, text];
}

/// Keeps the app running while a mode works in the background, with a
/// notification that shows progress and offers Stop.
abstract interface class LiveService {
  Future<void> start(LiveStatus status);

  Future<void> updateStatus(LiveStatus status);

  Future<void> stop();

  /// Whether status notifications may be shown.
  Future<bool> requestNotificationPermission();

  /// The user tapped Stop in the notification.
  Stream<void> get stopRequests;
}

/// Android foreground service bridge. iOS keeps no service, since the app
/// is suspended in the background; it keeps the screen on instead.
class PlatformLiveService implements LiveService {
  PlatformLiveService({bool? isAndroid, bool? isIOS})
    : _isAndroid = isAndroid ?? Platform.isAndroid,
      _isIOS = isIOS ?? Platform.isIOS {
    if (_isAndroid) channel.setMethodCallHandler(_handle);
  }

  static const channel = MethodChannel('ch.micheljung.shutterlink/live');
  static const idleTimerChannel = MethodChannel(
    'ch.micheljung.shutterlink/idle_timer',
  );
  static const stopRequestedMethod = 'stopRequested';
  static const setIdleTimerDisabledMethod = 'setDisabled';

  final bool _isAndroid;
  final bool _isIOS;
  final _stopRequests = StreamController<void>.broadcast();

  @override
  Stream<void> get stopRequests => _stopRequests.stream;

  @override
  Future<void> start(LiveStatus status) async {
    await _setIdleTimerDisabled(true);
    await _invoke('start', status.toMap());
  }

  @override
  Future<void> updateStatus(LiveStatus status) =>
      _invoke('updateStatus', status.toMap());

  @override
  Future<void> stop() async {
    await _setIdleTimerDisabled(false);
    await _invoke('stop');
  }

  /// Keeps an iPhone from locking while a mode runs, since a locked phone
  /// suspends the app.
  Future<void> _setIdleTimerDisabled(bool disabled) async {
    if (!_isIOS) return;
    try {
      await idleTimerChannel.invokeMethod<void>(
        setIdleTimerDisabledMethod,
        disabled,
      );
    } on MissingPluginException {
      // Best effort: the mode runs on with the screen locking.
    } on PlatformException {
      // Same.
    }
  }

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
