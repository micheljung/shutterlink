import 'dart:convert';

import 'package:crypto/crypto.dart';

final RegExp codePattern = RegExp(r'^[a-z]+(-[a-z]+){3}$');
final RegExp keyPattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _whitespace = RegExp(r'\s+');

String? normalizeCode(String? raw) {
  if (raw == null) return null;
  final code = raw.trim().toLowerCase().replaceAll(_whitespace, '-');
  return codePattern.hasMatch(code) ? code : null;
}

bool isValidKey(String? key) => key != null && keyPattern.hasMatch(key);

String sessionDirName(List<int> secret, String normalizedCode) =>
    Hmac(sha256, secret).convert(utf8.encode(normalizedCode)).toString();

bool constantTimeEquals(String a, String b) {
  final left = sha256.convert(utf8.encode(a)).bytes;
  final right = sha256.convert(utf8.encode(b)).bytes;
  var difference = 0;
  for (var i = 0; i < left.length; i++) {
    difference |= left[i] ^ right[i];
  }
  return difference == 0;
}
