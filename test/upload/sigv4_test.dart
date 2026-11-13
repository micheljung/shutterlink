import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/upload/sigv4.dart';

// Vectors from awslabs/aws-c-auth tests/aws-signing-test-suite/v4 and the
// Amazon S3 SigV4 documentation examples.
void main() {
  const suite = SigV4Signer(
    credentials: SigV4Credentials(
      'AKIDEXAMPLE',
      'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
    ),
    region: 'us-east-1',
    service: 'service',
  );
  final suiteTime = DateTime.utc(2015, 8, 30, 12, 36);
  const host = {'Host': 'example.amazonaws.com'};

  String signature(Map<String, String> signed) =>
      signed['Authorization']!.split('Signature=').last;

  void vector(
    String name,
    String expected, {
    String method = 'GET',
    Map<String, String> query = const {},
    Map<String, String> headers = host,
    String payloadHash = emptyPayloadHash,
  }) {
    test(name, () {
      final signed = suite.sign(
        method: method,
        canonicalPath: '/',
        query: query,
        headers: headers,
        payloadHash: payloadHash,
        time: suiteTime,
      );
      expect(signature(signed), expected);
    });
  }

  vector(
    'get-vanilla',
    '5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31',
  );
  vector(
    'get-vanilla-query-order-key-case',
    'b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500',
    query: {'Param2': 'value2', 'Param1': 'value1'},
  );
  vector(
    'get-vanilla-utf8-query',
    '2cdec8eed098649ff3a119c94853b13c643bcf08f8b0a1d91e12c9027818dd04',
    query: {'ሴ': 'bar'},
  );
  vector(
    'get-header-value-trim',
    'acc3ed3afb60bb290fc8d2dd0098b9911fcaa05412b367055dee359757a9c736',
    headers: {...host, 'My-Header1': ' value1', 'My-Header2': '"a   b   c"'},
  );
  vector(
    'post-vanilla',
    '5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b',
    method: 'POST',
  );
  vector(
    'post-header-key-sort',
    'c5410059b04c1ee005303aed430f6e6645f61f4dc9e1461ec8f8916fdf18852c',
    method: 'POST',
    headers: {...host, 'My-Header1': 'value1'},
  );
  final formHash = sha256.convert(utf8.encode('Param1=value1')).toString();
  vector(
    'post-x-www-form-urlencoded',
    'd3875051da38690788ef43de4db0d8f280229d82040bfac253562e56c3f20e0b',
    method: 'POST',
    headers: {
      ...host,
      'Content-Type': 'application/x-www-form-urlencoded',
      'Content-Length': '13',
      'X-Amz-Content-Sha256': formHash,
    },
    payloadHash: formHash,
  );

  test('S3 documentation GET Object example', () {
    const signer = SigV4Signer(
      credentials: SigV4Credentials(
        'AKIAIOSFODNN7EXAMPLE',
        'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
      ),
      region: 'us-east-1',
    );
    final signed = signer.sign(
      method: 'GET',
      canonicalPath: '/test.txt',
      query: const {},
      headers: const {
        'Host': 'examplebucket.s3.amazonaws.com',
        'Range': 'bytes=0-9',
        'x-amz-content-sha256': emptyPayloadHash,
      },
      payloadHash: emptyPayloadHash,
      time: DateTime.utc(2013, 5, 24),
    );
    expect(
      signed['Authorization'],
      'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/'
      's3/aws4_request, '
      'SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, '
      'Signature='
      'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
    );
    expect(signed['x-amz-date'], '20130524T000000Z');
  });

  test('uriEncode keeps unreserved characters and optionally slashes', () {
    expect(uriEncode('a b/c~d_e.f-g'), 'a%20b%2Fc~d_e.f-g');
    expect(uriEncode('a b/c', keepSlash: true), 'a%20b/c');
    expect(uriEncode('ü'), '%C3%BC');
  });

  test('canonicalQuery sorts by key, then value', () {
    expect(canonicalQuery({'b': '2', 'a': 'x y', 'A': '1'}), 'A=1&a=x%20y&b=2');
  });
}
