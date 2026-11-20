import 'dart:async';

import 'package:equatable/equatable.dart';

enum RemoteLink {
  disconnected,
  connecting,

  /// Waiting for the user to confirm Android's pairing request.
  pairing,

  /// The camera is there but refuses this phone; only pairing again helps.
  refused,
  connected,
}

/// A camera's shutter button, pressed from the phone.
abstract interface class ShutterRemote {
  /// What the camera calls itself, e.g. "EOS R".
  String get name;

  RemoteLink get link;

  Stream<RemoteLink> get links;

  /// Connects, and keeps connecting after a drop until [disconnect].
  Future<void> connect();

  Future<void> disconnect();

  /// Clicks the shutter button: takes a photo at the camera's shutter
  /// speed, or on BULB opens an exposure or closes the open one.
  Future<void> shoot();

  /// Clicks the movie button, which starts or stops a recording.
  Future<void> toggleRecording();

  /// Nudges a camera that may have gone to sleep, without shooting.
  Future<void> wake();
}

/// A camera found nearby or remembered from an earlier pairing.
class RemoteCamera extends Equatable {
  const RemoteCamera({required this.id, required this.name});

  /// The Bluetooth address on Android, a per-phone identifier on iPhone.
  final String id;
  final String name;

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  static RemoteCamera? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    if (id is! String || name is! String) return null;
    return RemoteCamera(id: id, name: name);
  }

  @override
  List<Object?> get props => [id, name];
}

class RemoteException implements Exception {
  const RemoteException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'RemoteException($message, $cause)';
}
