import 'dart:async';

import 'package:shutterlink/usb/usb_camera_platform.dart';

const canonUsbVendor = 0x04A9;
const otherUsbVendor = 0x05AC;

UsbCameraRef usbCamera({
  int vendorId = canonUsbVendor,
  int productId = 0x32EB,
  String platformId = '/dev/bus/usb/001/002',
  String name = 'Canon EOS R',
}) => UsbCameraRef(
  platformId: platformId,
  vendorId: vendorId,
  productId: productId,
  name: name,
);

/// Only Canon's vendor ID is claimed, as with the default registry.
bool claimsCanonOnly(int vendorId) => vendorId == canonUsbVendor;

/// A cable the test plugs and unplugs, with permission answers it chooses.
class FakeUsbCameraWatcher implements UsbCameraWatcher {
  final _attached = StreamController<UsbAttachment>.broadcast(sync: true);
  final _detached = StreamController<UsbCameraRef>.broadcast(sync: true);

  /// Cameras the app may open.
  final permitted = <UsbCameraRef>{};

  /// Answers to [requestPermission], in order; granted once empty.
  final permissionAnswers = <UsbPermission>[];
  final permissionRequests = <UsbCameraRef>[];

  /// 'start owner' and 'stop owner', in order.
  final calls = <String>[];

  void attach(UsbCameraRef device, {bool enumerated = false}) =>
      _attached.add(UsbAttachment(device, enumerated: enumerated));

  void detach(UsbCameraRef device) {
    permitted.remove(device);
    _detached.add(device);
  }

  @override
  Stream<UsbAttachment> get attached => _attached.stream;

  @override
  Stream<UsbCameraRef> get detached => _detached.stream;

  @override
  bool hasPermission(UsbCameraRef device) => permitted.contains(device);

  @override
  Future<UsbPermission> requestPermission(UsbCameraRef device) async {
    permissionRequests.add(device);
    final answer = permissionAnswers.isEmpty
        ? UsbPermission.granted
        : permissionAnswers.removeAt(0);
    if (answer == UsbPermission.granted) permitted.add(device);
    return answer;
  }

  @override
  void start(String owner) => calls.add('start $owner');

  @override
  void stop(String owner) => calls.add('stop $owner');
}
