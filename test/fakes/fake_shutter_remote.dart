import 'dart:async';

import 'package:shutterlink/remote/remote_bluetooth.dart';
import 'package:shutterlink/remote/shutter_remote.dart';

/// Records clicks; the test drives the link.
class FakeShutterRemote implements ShutterRemote {
  FakeShutterRemote({this.link = RemoteLink.connected});

  final events = <String>[];
  final _links = StreamController<RemoteLink>.broadcast(sync: true);

  /// Clicks throw while set.
  bool failing = false;

  /// Each click takes this long to reach the camera.
  Duration clickTime = Duration.zero;

  @override
  String get name => 'EOS R';

  @override
  RemoteLink link;

  @override
  Stream<RemoteLink> get links => _links.stream;

  void setLink(RemoteLink link) {
    this.link = link;
    _links.add(link);
  }

  @override
  Future<void> connect() async {
    if (link == RemoteLink.connected) return;
    events.add('connect');
    setLink(RemoteLink.connected);
  }

  @override
  Future<void> disconnect() async {
    events.add('disconnect');
    setLink(RemoteLink.disconnected);
  }

  Future<void> _click(String event) async {
    if (clickTime > Duration.zero) await Future<void>.delayed(clickTime);
    if (failing) throw RemoteException('$event failed');
    events.add(event);
  }

  @override
  Future<void> shoot() => _click('shoot');

  @override
  Future<void> toggleRecording() => _click('record');

  @override
  Future<void> wake() async => events.add('wake');
}

/// Finds [cameras] and hands out [remote] for any of them.
class FakeRemoteBluetooth implements RemoteBluetooth {
  FakeRemoteBluetooth({FakeShutterRemote? remote, this.cameras = const []})
    : remote = remote ?? FakeShutterRemote(link: RemoteLink.disconnected);

  final FakeShutterRemote remote;
  final List<RemoteCamera> cameras;
  final states$ = StreamController<BluetoothState>.broadcast();
  bool granted = true;

  @override
  Stream<BluetoothState> get states => states$.stream;

  @override
  Future<bool> requestAccess() async => granted;

  @override
  Future<void> openSettings() async {}

  @override
  Stream<List<RemoteCamera>> scan() => Stream.value(cameras);

  @override
  ShutterRemote remoteFor(RemoteCamera camera) => remote;
}
