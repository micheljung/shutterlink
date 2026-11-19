import 'dart:async';

import 'package:flutter/services.dart';

import 'remote_bluetooth.dart';
import 'shutter_remote.dart';

/// A pretend camera, so the intervalometer can be tried without one. Each
/// click clicks and buzzes the phone.
class DemoRemoteBluetooth implements RemoteBluetooth {
  const DemoRemoteBluetooth();

  static const camera = RemoteCamera(id: 'demo', name: 'Demo camera');
  static const _findDelay = Duration(milliseconds: 600);

  @override
  Stream<BluetoothState> get states => Stream.value(BluetoothState.ready);

  @override
  Future<bool> requestAccess() async => true;

  @override
  Future<void> openSettings() async {}

  @override
  Stream<List<RemoteCamera>> scan() async* {
    await Future<void>.delayed(_findDelay);
    yield const [camera];
  }

  @override
  ShutterRemote remoteFor(RemoteCamera camera) => DemoShutterRemote();
}

class DemoShutterRemote implements ShutterRemote {
  static const _connectDelay = Duration(milliseconds: 400);

  final _links = StreamController<RemoteLink>.broadcast();
  RemoteLink _link = RemoteLink.disconnected;

  @override
  String get name => DemoRemoteBluetooth.camera.name;

  @override
  RemoteLink get link => _link;

  @override
  Stream<RemoteLink> get links => _links.stream;

  void _set(RemoteLink link) {
    _link = link;
    _links.add(link);
  }

  @override
  Future<void> connect() async {
    _set(RemoteLink.connecting);
    await Future<void>.delayed(_connectDelay);
    _set(RemoteLink.connected);
  }

  @override
  Future<void> disconnect() async => _set(RemoteLink.disconnected);

  @override
  Future<void> shoot() => _click();

  @override
  Future<void> toggleRecording() => _click();

  @override
  Future<void> wake() async {}

  Future<void> _click() async {
    if (_link != RemoteLink.connected) {
      throw const RemoteException('The demo camera is not connected.');
    }
    // Feedback only; a shot never waits for it.
    unawaited(_feedback());
  }

  static Future<void> _feedback() async {
    try {
      await SystemSound.play(SystemSoundType.click);
      await HapticFeedback.mediumImpact();
    } on Exception {
      // The demo shot counts without it.
    }
  }
}
