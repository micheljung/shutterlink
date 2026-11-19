import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/remote/canon_ble_protocol.dart';

void main() {
  test('button bytes match the BR-E1 remote', () {
    expect(CanonBleProtocol.shutterDown, [0x8C]);
    expect(CanonBleProtocol.shutterUp, [0x0C]);
    expect(CanonBleProtocol.movieDown, [0x88]);
    expect(CanonBleProtocol.movieUp, [0x08]);
  });

  test('identify sends 0x03 and the name in ASCII', () {
    expect(CanonBleProtocol.identify('Shutterlink'), [
      0x03,
      ...'Shutterlink'.codeUnits,
    ]);
  });

  test('identify drops what the camera cannot show and caps the length', () {
    expect(CanonBleProtocol.identify('Zoë📷'), [0x03, ...'Zo'.codeUnits]);
    expect(
      CanonBleProtocol.identify('x' * 40),
      hasLength(1 + CanonBleProtocol.maxNameLength),
    );
  });
}
