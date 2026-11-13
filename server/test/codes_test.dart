import 'package:shutterlink_server/src/codes.dart';
import 'package:test/test.dart';

void main() {
  test('normalizes and validates codes', () {
    expect(
      normalizeCode('  Apple-Banana-Cherry-Delta '),
      'apple-banana-cherry-delta',
    );
    expect(normalizeCode('apple-banana-cherry'), isNull);
    expect(normalizeCode('../../etc-passwd-x-y'), isNull);
    expect(normalizeCode('apple-banana-cherry-delta-echo'), isNull);
    expect(normalizeCode(null), isNull);
  });

  test('validates keys', () {
    expect(isValidKey('a' * 64), isTrue);
    expect(isValidKey('A' * 64), isFalse);
    expect(isValidKey('a' * 63), isFalse);
    expect(isValidKey('../${'a' * 61}'), isFalse);
  });

  test('directory name is a keyed HMAC', () {
    final first = sessionDirName([1, 2, 3], 'apple-banana-cherry-delta');
    expect(first, hasLength(64));
    expect(
      sessionDirName([1, 2, 4], 'apple-banana-cherry-delta'),
      isNot(first),
    );
  });

  test('constant-time compare', () {
    expect(constantTimeEquals('token', 'token'), isTrue);
    expect(constantTimeEquals('token', 'tokem'), isFalse);
    expect(constantTimeEquals('token', 'token2'), isFalse);
  });
}
