import 'dart:convert';

import 'package:crypto/crypto.dart';

/// SHA-256 of an empty payload.
const emptyPayloadHash =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

class SigV4Credentials {
  const SigV4Credentials(this.accessKey, this.secretKey);

  final String accessKey;
  final String secretKey;
}

/// AWS Signature Version 4 for a single request, with S3 path semantics
/// (no double encoding, no path normalization).
class SigV4Signer {
  const SigV4Signer({
    required this.credentials,
    required this.region,
    this.service = 's3',
  });

  final SigV4Credentials credentials;
  final String region;
  final String service;

  /// Returns [headers] plus `x-amz-date` and `Authorization`. [headers] must
  /// contain `host`; every header given is signed.
  Map<String, String> sign({
    required String method,
    required String canonicalPath,
    required Map<String, String> query,
    required Map<String, String> headers,
    required String payloadHash,
    required DateTime time,
  }) {
    final amzDate = _amzDate(time.toUtc());
    final date = amzDate.substring(0, 8);
    final all = <String, String>{
      for (final e in headers.entries) e.key.toLowerCase(): _trim(e.value),
      'x-amz-date': amzDate,
    };
    final names = all.keys.toList()..sort();
    final signedHeaders = names.join(';');
    final canonicalRequest = [
      method,
      canonicalPath,
      canonicalQuery(query),
      ...names.map((n) => '$n:${all[n]}'),
      '',
      signedHeaders,
      payloadHash,
    ].join('\n');
    final scope = '$date/$region/$service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');
    var key = _hmac(utf8.encode('AWS4${credentials.secretKey}'), date);
    key = _hmac(key, region);
    key = _hmac(key, service);
    key = _hmac(key, 'aws4_request');
    final signature = Hmac(
      sha256,
      key,
    ).convert(utf8.encode(stringToSign)).toString();
    return {
      ...headers,
      'x-amz-date': amzDate,
      'Authorization':
          'AWS4-HMAC-SHA256 Credential=${credentials.accessKey}/$scope, '
          'SignedHeaders=$signedHeaders, Signature=$signature',
    };
  }
}

String canonicalQuery(Map<String, String> query) {
  final pairs =
      query.entries.map((e) => (uriEncode(e.key), uriEncode(e.value))).toList()
        ..sort((a, b) {
          final byKey = a.$1.compareTo(b.$1);
          return byKey != 0 ? byKey : a.$2.compareTo(b.$2);
        });
  return pairs.map((p) => '${p.$1}=${p.$2}').join('&');
}

/// Encodes every byte except the RFC 3986 unreserved characters; `/` too
/// unless [keepSlash].
String uriEncode(String value, {bool keepSlash = false}) {
  final out = StringBuffer();
  for (final byte in utf8.encode(value)) {
    final c = String.fromCharCode(byte);
    if (_unreserved.hasMatch(c) || (keepSlash && c == '/')) {
      out.write(c);
    } else {
      out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

final _unreserved = RegExp(r'^[A-Za-z0-9\-._~]$');

List<int> _hmac(List<int> key, String data) =>
    Hmac(sha256, key).convert(utf8.encode(data)).bytes;

String _trim(String value) => value.trim().replaceAll(RegExp(r'\s+'), ' ');

String _amzDate(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}'
      'T${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
}
