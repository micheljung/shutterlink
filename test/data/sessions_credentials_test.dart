import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shutterlink/data/sessions_credentials.dart';

class _MockStorage extends Mock implements FlutterSecureStorage {}

void main() {
  late _MockStorage storage;
  late SecureSessionsCredentials credentials;

  setUp(() async {
    storage = _MockStorage();
    when(() => storage.read(key: SecureSessionsCredentials.tokenKey))
        .thenAnswer((_) async => 'secret');
    when(
      () => storage.write(
        key: SecureSessionsCredentials.tokenKey,
        value: any(named: 'value'),
      ),
    ).thenAnswer((_) async {});
    when(() => storage.delete(key: SecureSessionsCredentials.tokenKey))
        .thenAnswer((_) async {});
    credentials = SecureSessionsCredentials(storage: storage);
  });

  test('reads the token once, with no toggle to turn on', () async {
    expect(await credentials.token(), 'secret');
    expect(await credentials.token(), 'secret');
    verify(() => storage.read(key: SecureSessionsCredentials.tokenKey))
        .called(1);
  });

  test('stores a trimmed token and deletes a blank one', () async {
    await credentials.setToken('  new  ');
    expect(await credentials.token(), 'new');
    verify(
      () =>
          storage.write(key: SecureSessionsCredentials.tokenKey, value: 'new'),
    ).called(1);

    await credentials.setToken(' ');
    expect(await credentials.token(), isNull);
    verify(() => storage.delete(key: SecureSessionsCredentials.tokenKey))
        .called(1);
    verifyNever(() => storage.read(key: SecureSessionsCredentials.tokenKey));
  });

  test('retries a failed read', () async {
    when(() => storage.read(key: SecureSessionsCredentials.tokenKey))
        .thenThrow(PlatformException(code: 'locked'));

    await expectLater(credentials.token(), throwsA(isA<PlatformException>()));

    when(() => storage.read(key: SecureSessionsCredentials.tokenKey))
        .thenAnswer((_) async => 'secret');
    expect(await credentials.token(), 'secret');
  });
}
