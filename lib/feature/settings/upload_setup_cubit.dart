import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../upload/backend_factory.dart';
import '../../upload/destination.dart';
import '../../upload/provider_preset.dart';
import '../../upload/storage_backend.dart';
import 'upload_settings_cubit.dart';

/// An upload destination being set up or edited; nothing is stored until
/// [UploadSetupCubit.save].
class UploadSetupState extends Equatable {
  const UploadSetupState({
    this.preset,
    this.input = const PresetInput(),
    this.password = '',
    this.useKey = false,
    this.privateKey = '',
    this.passphrase = '',
    this.certificatePin,
    this.hostKeyPin,
    this.pinnedFor,
  });

  /// Null until the user picks a provider.
  final ProviderPreset? preset;
  final PresetInput input;
  final String password;

  /// SFTP only: sign in with [privateKey] instead of [password].
  final bool useKey;
  final String privateKey;
  final String passphrase;
  final String? certificatePin;
  final String? hostKeyPin;

  /// The server the pins were trusted for.
  final String? pinnedFor;

  ProviderPreset get _preset => preset ?? ProviderPreset.custom;

  Destination get destination => _preset.build(input);

  DestinationType get type => _preset.typeFor(input);

  bool get _keyLogin => type == DestinationType.sftp && useKey;

  DestinationSecrets get secrets {
    final sftp = type == DestinationType.sftp;
    return DestinationSecrets(
      password: password,
      privateKey: _keyLogin ? privateKey.trim() : '',
      passphrase: _keyLogin ? passphrase : '',
      certificatePin: sftp ? null : certificatePin,
      hostKeyPin: sftp ? hostKeyPin : null,
    );
  }

  /// Whether the server step has everything [destination] needs.
  bool get serverComplete {
    final input = this.input;
    bool filled(String value) => value.trim().isNotEmpty;
    return switch (_preset) {
      ProviderPreset.nextcloud => filled(input.server),
      ProviderPreset.backblazeB2 ||
      ProviderPreset.awsS3 => filled(input.region) && filled(input.bucket),
      ProviderPreset.cloudflareR2 =>
        filled(input.server) && filled(input.bucket),
      ProviderPreset.hetznerStorageBox => filled(input.username),
      ProviderPreset.custom =>
        filled(input.server) &&
            (input.type != DestinationType.s3 || filled(input.bucket)),
    };
  }

  /// What a pin was trusted for: the TLS or SSH host the backend connects
  /// to, which for virtual-host S3 includes the bucket.
  static String serverKey(Destination destination) => [
    destination.type.name,
    destination.endpoint,
    destination.bucket,
    destination.pathStyle,
  ].join('|');

  UploadSetupState copyWith({
    ProviderPreset? preset,
    PresetInput? input,
    String? password,
    bool? useKey,
    String? privateKey,
    String? passphrase,
    String? Function()? certificatePin,
    String? Function()? hostKeyPin,
    String? Function()? pinnedFor,
  }) => UploadSetupState(
    preset: preset ?? this.preset,
    input: input ?? this.input,
    password: password ?? this.password,
    useKey: useKey ?? this.useKey,
    privateKey: privateKey ?? this.privateKey,
    passphrase: passphrase ?? this.passphrase,
    certificatePin: certificatePin != null
        ? certificatePin()
        : this.certificatePin,
    hostKeyPin: hostKeyPin != null ? hostKeyPin() : this.hostKeyPin,
    pinnedFor: pinnedFor != null ? pinnedFor() : this.pinnedFor,
  );

  @override
  List<Object?> get props => [
    preset,
    input,
    password,
    useKey,
    privateKey,
    passphrase,
    certificatePin,
    hostKeyPin,
    pinnedFor,
  ];
}

class UploadSetupCubit extends Cubit<UploadSetupState> {
  UploadSetupCubit(this._settings) : super(const UploadSetupState());

  /// Starts from the saved destination. Preset inputs are used only when
  /// they rebuild the identical destination; otherwise the raw fields are.
  UploadSetupCubit.edit(this._settings) : super(_editState(_settings.state));

  final UploadSettingsCubit _settings;

  static UploadSetupState _editState(UploadSettingsState saved) {
    final destination = saved.destination;
    if (destination == null) return const UploadSetupState();
    final secrets = saved.secrets;
    final stored = saved.preset ?? ProviderPreset.custom;
    final storedInput = stored.parse(destination);
    final preset = storedInput == null ? ProviderPreset.custom : stored;
    final input =
        storedInput ??
        ProviderPreset.custom.parse(destination) ??
        PresetInput(
          type: destination.type,
          server: destination.endpoint,
          region: destination.region,
          bucket: destination.bucket,
          pathStyle: destination.pathStyle,
          basePath: destination.basePath,
          username: destination.username,
        );
    final pinned = secrets.certificatePin != null || secrets.hostKeyPin != null;
    return UploadSetupState(
      preset: preset,
      input: input,
      password: secrets.password,
      useKey: secrets.privateKey.isNotEmpty,
      privateKey: secrets.privateKey,
      passphrase: secrets.passphrase,
      certificatePin: secrets.certificatePin,
      hostKeyPin: secrets.hostKeyPin,
      pinnedFor: pinned ? UploadSetupState.serverKey(destination) : null,
    );
  }

  void choosePreset(ProviderPreset preset) =>
      _emitDraft(state.copyWith(preset: preset));

  void updateInput(PresetInput input) =>
      _emitDraft(state.copyWith(input: input));

  void setPassword(String password) => emit(state.copyWith(password: password));

  void setUseKey(bool useKey) => emit(state.copyWith(useKey: useKey));

  void setPrivateKey(String privateKey) =>
      emit(state.copyWith(privateKey: privateKey));

  void setPassphrase(String passphrase) =>
      emit(state.copyWith(passphrase: passphrase));

  void trustCertificate(String fingerprint) => emit(
    state.copyWith(
      certificatePin: () => fingerprint,
      pinnedFor: () => UploadSetupState.serverKey(state.destination),
    ),
  );

  void trustHostKey(String fingerprint) => emit(
    state.copyWith(
      hostKeyPin: () => fingerprint,
      pinnedFor: () => UploadSetupState.serverKey(state.destination),
    ),
  );

  /// Returns null when the server accepted the connection.
  Future<StorageException?> test() =>
      _settings.test(state.destination, state.secrets);

  /// Whether saving sends pending photos somewhere else.
  bool get replaces => _settings.replaces(state.destination);

  Future<void> save() => _settings.save(
    state.destination,
    state.secrets,
    preset: state.preset ?? ProviderPreset.custom,
  );

  /// A pin trusts one server; it must not carry over to another one.
  void _emitDraft(UploadSetupState draft) {
    final pinnedFor = draft.pinnedFor;
    if (pinnedFor != null &&
        pinnedFor != UploadSetupState.serverKey(draft.destination)) {
      emit(
        draft.copyWith(
          certificatePin: () => null,
          hostKeyPin: () => null,
          pinnedFor: () => null,
        ),
      );
      return;
    }
    emit(draft);
  }
}
