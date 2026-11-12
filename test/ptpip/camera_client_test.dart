import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptpip/ptpip.dart';

void main() {
  test('value types compare by value', () {
    final guid = Uint8List(ptpIpGuidSize);
    expect(
      CameraIdentity(guid: guid, name: 'a'),
      CameraIdentity(guid: guid, name: 'a'),
    );
    const info = CameraDeviceInfo(
      manufacturer: 'Canon Inc.',
      model: 'Canon EOS R',
      deviceVersion: '1',
      serialNumber: '2',
      operationsSupported: [1],
    );
    expect(
      info,
      CameraDeviceInfo(
        manufacturer: 'Canon Inc.',
        model: 'Canon EOS R',
        deviceVersion: '1',
        serialNumber: '2',
        operationsSupported: List.of(info.operationsSupported),
      ),
    );
  });

  test('exceptions describe themselves', () {
    expect(const PairingRequiredException(5).toString(), contains('5'));
    expect(
      const CameraDisconnectedException('gone').toString(),
      contains('gone'),
    );
    expect(
      const PtpResponseException(0x101B, 0x2002).toString(),
      'PtpResponseException(op: 0x101b, code: 0x2002)',
    );
    expect(const TransferCancelledException(), isA<Exception>());
  });
}
