import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptpip/ptpip.dart';

void main() {
  test('Canon EOS opcodes and formats match libgphoto2 ptp.h', () {
    expect(CanonEosOperation.setRemoteMode, 0x9114);
    expect(CanonEosOperation.setEventMode, 0x9115);
    expect(CanonEosOperation.getEvent, 0x9116);
    expect(PtpOperation.getPartialObject, 0x101B);
    expect(PtpOperation.getThumb, 0x100A);
    expect(PtpObjectFormat.canonCr3, 0xB108);
    expect(PtpObjectFormat.exifJpeg, 0x3801);
    expect(PtpResponseCode.ok, 0x2001);
  });
}
