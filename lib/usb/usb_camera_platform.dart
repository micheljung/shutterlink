import 'package:flutter/foundation.dart';

import 'usb_pipe.dart';

/// A camera on the USB cable.
///
/// Two refs are equal when vendor and product match: reading the serial
/// needs permission, and a re-plug changes [platformId]. Telling apart two
/// identical cameras is not supported.
@immutable
class UsbCameraRef {
  const UsbCameraRef({
    required this.platformId,
    required this.vendorId,
    required this.productId,
    required this.name,
    this.serial,
  });

  /// The platform's handle for the device as currently plugged in, e.g. the
  /// Android device name.
  final String platformId;
  final int vendorId;
  final int productId;
  final String name;
  final String? serial;

  @override
  bool operator ==(Object other) =>
      other is UsbCameraRef &&
      other.vendorId == vendorId &&
      other.productId == productId;

  @override
  int get hashCode => Object.hash(vendorId, productId);

  @override
  String toString() =>
      'UsbCameraRef($name, '
      '${vendorId.toRadixString(16).padLeft(4, '0')}:'
      '${productId.toRadixString(16).padLeft(4, '0')}, $platformId)';
}

enum UsbPermission {
  granted,
  denied,

  /// The request is shown to the user, but the app is in the background and
  /// does not wait for the answer.
  userActionNeeded,
}

/// Reports cameras coming and going on the USB cable.
abstract interface class UsbCameraWatcher {
  /// Cameras plugged in, and those already plugged in when the first owner
  /// [start]s. Each camera is reported once until it is [detached].
  Stream<UsbCameraRef> get attached;

  Stream<UsbCameraRef> get detached;

  Future<UsbPermission> requestPermission(UsbCameraRef device);

  bool hasPermission(UsbCameraRef device);

  /// Watches on behalf of [owner]. The first owner enumerates the cameras
  /// already plugged in.
  void start(String owner);

  /// Ends [owner]'s watch.
  void stop(String owner);
}

abstract interface class UsbCameraPlatform {
  UsbCameraWatcher get watcher;

  /// Opens [device] for PTP. Throws [UsbTransferException] when it cannot.
  Future<UsbCameraLink> open(UsbCameraRef device);
}

/// A platform without USB camera support.
class NoUsbCameraPlatform implements UsbCameraPlatform {
  const NoUsbCameraPlatform();

  @override
  UsbCameraWatcher get watcher => const NoUsbCameraWatcher();

  @override
  Future<UsbCameraLink> open(UsbCameraRef device) =>
      Future.error(const UsbTransferException('USB is not supported'));
}

class NoUsbCameraWatcher implements UsbCameraWatcher {
  const NoUsbCameraWatcher();

  @override
  Stream<UsbCameraRef> get attached => const Stream.empty();

  @override
  Stream<UsbCameraRef> get detached => const Stream.empty();

  @override
  Future<UsbPermission> requestPermission(UsbCameraRef device) async =>
      UsbPermission.denied;

  @override
  bool hasPermission(UsbCameraRef device) => false;

  @override
  void start(String owner) {}

  @override
  void stop(String owner) {}
}
