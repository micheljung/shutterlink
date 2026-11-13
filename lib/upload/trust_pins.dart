import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Uppercase, colon-separated SHA-256 of the certificate's DER encoding, as
/// browsers display it.
String certificateFingerprint(X509Certificate certificate) => sha256
    .convert(certificate.der)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(':');

/// dartssh2 hands host keys over as UTF-8 `SHA256:<base64>`.
String hostKeyFingerprint(Uint8List fingerprint) =>
    utf8.decode(fingerprint, allowMalformed: true);

bool certificatePinMatches(String? pin, String fingerprint) {
  if (pin == null) return false;
  String normalize(String s) => s.replaceAll(':', '').toUpperCase().trim();
  return normalize(pin) == normalize(fingerprint);
}

bool hostKeyPinMatches(String? pin, String fingerprint) =>
    pin != null && pin.trim() == fingerprint;
