@Tags(['usb-hardware'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/probe/libusb_pipe.dart';

void main() {
  test('libusb lists the connected camera', () {
    expect(listLibusbDevices(), isNotEmpty);
  });

  test('the camera opens, claims and closes', () async {
    final pipe = await LibusbPipe.open();
    expect(pipe.maxTransfer % pipe.maxPacketSize, 0);
    await pipe.close();
  });
}
