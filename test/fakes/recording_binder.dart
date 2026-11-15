import 'dart:async';
import 'dart:io';

import 'package:shutterlink/data/network_binder.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

const cameraGateway = '192.168.1.2';
const homeGateway = '10.0.0.1';
const unreachable = CameraDisconnectedException(
  SocketException('Connection refused'),
);

/// Records binding calls and tracks which owners hold the Wi-Fi.
class RecordingBinder implements NetworkBinder {
  final calls = <String>[];
  final owners = <String>{};
  final lost = StreamController<void>.broadcast();
  Object? Function() gateway = () => cameraGateway;
  Completer<void>? acquireGate;

  @override
  Future<String?> acquireBinding(
    String owner, {
    bool holdNetwork = false,
  }) async {
    calls.add('acquire $owner${holdNetwork ? ' hold' : ''}');
    await acquireGate?.future;
    final result = gateway();
    if (result is Exception) throw result;
    owners.add(owner);
    return result as String?;
  }

  @override
  Future<void> releaseBinding(String owner) async {
    calls.add('release $owner');
    owners.remove(owner);
  }

  @override
  void transferBinding(String from, String to) {
    calls.add('transfer $from>$to');
    if (owners.remove(from)) owners.add(to);
  }

  @override
  Stream<void> get bindingLost => lost.stream;

  @override
  Future<void> acquireMulticastLock() async {}

  @override
  Future<void> releaseMulticastLock() async {}
}
