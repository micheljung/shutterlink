import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/destination_repository.dart';
import 'package:shutterlink/feature/settings/upload_settings_cubit.dart';
import 'package:shutterlink/feature/settings/upload_setup_cubit.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/provider_preset.dart';

void main() {
  const fingerprint = 'AA:BB:CC';
  late UploadSettingsCubit settings;
  late UploadSetupCubit cubit;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final repository = DestinationRepository(
      await SharedPreferences.getInstance(),
    );
    settings = UploadSettingsCubit(repository, tester: (_, _) async {});
    cubit = UploadSetupCubit(settings)
      ..choosePreset(ProviderPreset.custom)
      ..updateInput(
        const PresetInput(
          type: DestinationType.s3,
          server: 'https://s3.example.com',
          bucket: 'photos',
          basePath: 'eos',
        ),
      );
  });

  tearDown(() async {
    await cubit.close();
    await settings.close();
  });

  void change(PresetInput Function(PresetInput input) edit) =>
      cubit.updateInput(edit(cubit.state.input));

  test('a pin survives a changed folder', () {
    cubit.trustCertificate(fingerprint);

    change((input) => input.copyWith(basePath: 'other'));

    expect(cubit.state.secrets.certificatePin, fingerprint);
  });

  test('a pin is dropped for another bucket', () {
    cubit.trustCertificate(fingerprint);

    change((input) => input.copyWith(bucket: 'other'));

    expect(cubit.state.secrets.certificatePin, isNull);
  });

  test('a pin is dropped when the addressing style changes', () {
    cubit.trustCertificate(fingerprint);

    change((input) => input.copyWith(pathStyle: true));

    expect(cubit.state.secrets.certificatePin, isNull);
  });

  test('SFTP key login keeps the stored password', () {
    change(
      (input) =>
          input.copyWith(type: DestinationType.sftp, server: 'nas.example.com'),
    );
    cubit
      ..setPassword('pw')
      ..setUseKey(true)
      ..setPrivateKey(' key ')
      ..setPassphrase('phrase');

    final secrets = cubit.state.secrets;
    expect(secrets.password, 'pw');
    expect(secrets.privateKey, 'key');
    expect(secrets.passphrase, 'phrase');

    cubit.setUseKey(false);
    expect(cubit.state.secrets.privateKey, isEmpty);
    expect(cubit.state.secrets.password, 'pw');
  });

  test('Immich needs only the address and has no folder', () {
    cubit.choosePreset(ProviderPreset.immich);
    cubit.updateInput(const PresetInput());
    expect(cubit.state.serverComplete, isFalse);

    change((input) => input.copyWith(server: 'photos.example.com'));
    cubit.setPassword(' api-key ');

    expect(cubit.state.serverComplete, isTrue);
    expect(cubit.state.hasFolder, isFalse);
    expect(cubit.state.destination.type, DestinationType.immich);
    expect(cubit.state.secrets.password, 'api-key');
  });
}
