import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/destination_repository.dart';
import 'package:shutterlink/upload/backend_factory.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/network_policy.dart';

class _FailingSecureStorage extends FlutterSecureStorage {
  final deleted = <String>[];

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => Future.error(Exception('Keystore key invalidated'));

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => deleted.add(key);
}

void main() {
  const s3 = Destination(
    type: DestinationType.s3,
    endpoint: 'https://s3.example.com',
    region: 'eu-central-1',
    bucket: 'photos',
    basePath: 'eos',
    username: 'AKIDEXAMPLE',
    pathStyle: true,
    policy: MobileDataPolicy.jpeg,
    keepLocalCopy: false,
  );
  const s3Secrets = DestinationSecrets(
    password: 'wJalrXUtnFEMI-secret-key',
    certificatePin: 'AB:CD',
  );
  const sftp = Destination(
    type: DestinationType.sftp,
    endpoint: 'nas.example.com:2222',
    username: 'alice',
  );
  const sftpSecrets = DestinationSecrets(
    password: 'sftp-password-123',
    privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n',
    passphrase: 'key-passphrase-456',
    hostKeyPin: 'SHA256:hostkeypin',
  );
  late SharedPreferences prefs;
  late DestinationRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    repository = DestinationRepository(prefs);
  });

  tearDown(() => repository.close());

  test('has no destination initially', () async {
    expect(repository.destination, isNull);
    await expectLater(
      repository.readSecrets(),
      throwsA(isA<CredentialsMissingException>()),
    );
  });

  test('round-trips the destination and its secrets', () async {
    await repository.save(s3, s3Secrets);

    final reloaded = DestinationRepository(prefs);
    expect(reloaded.destination, s3);
    expect(await reloaded.readSecrets(), s3Secrets);
  });

  test('save replaces the previous destination and announces it', () async {
    final changes = <Destination?>[];
    repository.changes.listen(changes.add);
    await repository.save(s3, s3Secrets);

    await repository.save(sftp, sftpSecrets);
    await pumpEventQueue();

    expect(repository.destination, sftp);
    expect(await repository.readSecrets(), sftpSecrets);
    expect(changes, [s3, sftp]);
  });

  test('remove clears settings and secrets', () async {
    final changes = <Destination?>[];
    repository.changes.listen(changes.add);
    await repository.save(s3, s3Secrets);

    await repository.remove();
    await pumpEventQueue();

    expect(repository.destination, isNull);
    expect(prefs.getKeys(), isEmpty);
    expect(
      await DestinationRepository.defaultSecureStorage.read(
        key: DestinationRepository.secretsKey,
      ),
      isNull,
    );
    expect(changes, [s3, null]);
  });

  test('no preference key or value contains a secret (AC15)', () async {
    await repository.save(s3, s3Secrets);
    final s3Prefs = {for (final key in prefs.getKeys()) key: prefs.get(key)};
    await repository.save(sftp, sftpSecrets);
    final sftpPrefs = {for (final key in prefs.getKeys()) key: prefs.get(key)};

    for (final (stored, secrets) in [
      (s3Prefs, s3Secrets),
      (sftpPrefs, sftpSecrets),
    ]) {
      final texts = [
        for (final MapEntry(:key, :value) in stored.entries) ...[key, '$value'],
      ];
      for (final secret in [
        secrets.password,
        secrets.privateKey,
        secrets.passphrase,
        ?secrets.certificatePin,
        ?secrets.hostKeyPin,
      ].where((secret) => secret.isNotEmpty)) {
        expect(
          texts.where((text) => text.contains(secret)),
          isEmpty,
          reason: secret,
        );
      }
    }
  });

  test('an unreadable secure storage is wiped and reported', () async {
    await repository.save(s3, s3Secrets);
    final storage = _FailingSecureStorage();
    final broken = DestinationRepository(prefs, secureStorage: storage);

    await expectLater(
      broken.readSecrets(),
      throwsA(isA<CredentialsMissingException>()),
    );
    expect(storage.deleted, [DestinationRepository.secretsKey]);
    expect(broken.destination, s3);
  });

  test('corrupt secrets are wiped and reported', () async {
    await repository.save(s3, s3Secrets);
    FlutterSecureStorage.setMockInitialValues({
      DestinationRepository.secretsKey: '[not an object]',
    });

    await expectLater(
      repository.readSecrets(),
      throwsA(isA<CredentialsMissingException>()),
    );
    expect(
      await DestinationRepository.defaultSecureStorage.read(
        key: DestinationRepository.secretsKey,
      ),
      isNull,
    );
  });

  test('secrets of another destination are not used', () async {
    await repository.save(s3, s3Secrets);
    await prefs.setString(DestinationRepository.bucketKey, 'other');

    await expectLater(
      repository.readSecrets(),
      throwsA(isA<CredentialsMissingException>()),
    );
  });

  test('an unknown type reads as no destination', () async {
    await repository.save(s3, s3Secrets);
    await prefs.setString(DestinationRepository.typeKey, 'ftp');

    expect(repository.destination, isNull);
  });
}
