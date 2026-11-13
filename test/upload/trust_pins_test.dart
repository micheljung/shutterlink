import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/upload/storage_backend.dart';
import 'package:shutterlink/upload/trust_pins.dart';

void main() {
  test('certificate pins compare case- and colon-insensitively', () {
    expect(certificatePinMatches('ab:cd:01', 'AB:CD:01'), isTrue);
    expect(certificatePinMatches(' ABCD01 ', 'AB:CD:01'), isTrue);
    expect(certificatePinMatches('AB:CD:02', 'AB:CD:01'), isFalse);
    expect(certificatePinMatches(null, 'AB:CD:01'), isFalse);
  });

  test('host key pins compare exactly', () {
    final fingerprint = hostKeyFingerprint(
      Uint8List.fromList(utf8.encode('SHA256:abc+/D')),
    );
    expect(fingerprint, 'SHA256:abc+/D');
    expect(hostKeyPinMatches('SHA256:abc+/D', fingerprint), isTrue);
    expect(hostKeyPinMatches('SHA256:abc+/d', fingerprint), isFalse);
    expect(hostKeyPinMatches(null, fingerprint), isFalse);
  });

  test('trust exceptions are readable and not retryable', () {
    const cert = UntrustedCertificateException('AB:CD');
    expect(cert.toString(), contains('AB:CD'));
    expect(cert.retryable, isFalse);
    const key = UnknownHostKeyException('ssh-ed25519', 'SHA256:x');
    expect(key.message, contains('ssh-ed25519 SHA256:x'));
    expect(key.retryable, isFalse);
  });
}
