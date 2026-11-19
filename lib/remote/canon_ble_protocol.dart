import 'dart:convert';

/// Canon's Bluetooth remote protocol, the one the BR-E1 remote speaks. See
/// docs/bluetooth-remote.md.
abstract final class CanonBleProtocol {
  static const service = '00050000-0000-1000-0000-d8492fffa821';

  /// Takes the remote's name when pairing and on every connect.
  static const identity = '00050002-0000-1000-0000-d8492fffa821';

  /// Takes one button byte per write.
  static const control = '00050003-0000-1000-0000-d8492fffa821';

  static const _identify = 0x03;
  static const _shutter = 0x80;
  static const _photoMode = 0x0C;
  static const _movieMode = 0x08;

  /// The camera shows at most this many characters of the remote's name.
  static const maxNameLength = 18;
  static const _firstPrintable = 0x20;
  static const _delete = 0x7F;

  static const shutterDown = [_shutter | _photoMode];
  static const shutterUp = [_photoMode];
  static const movieDown = [_shutter | _movieMode];
  static const movieUp = [_movieMode];

  /// Buttons up, which wakes a dozing camera without shooting.
  static const idle = shutterUp;

  static List<int> identify(String name) {
    final ascii = name.runes
        .where((rune) => rune >= _firstPrintable && rune < _delete)
        .take(maxNameLength);
    return [_identify, ...latin1.encode(String.fromCharCodes(ascii))];
  }
}
