import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/destination_repository.dart';
import '../../upload/backend_factory.dart';
import '../../upload/destination.dart';
import '../../upload/network_policy.dart';
import '../../upload/provider_preset.dart';
import '../../upload/storage_backend.dart';

typedef ConnectionTester = Future<void> Function(
  Destination destination,
  DestinationSecrets secrets,
);

class UploadSettingsState extends Equatable {
  const UploadSettingsState({
    this.destination,
    this.preset,
    this.secrets = const DestinationSecrets(),
    this.credentialsMissing = false,
    this.loaded = false,
  });

  final Destination? destination;
  final ProviderPreset? preset;
  final DestinationSecrets secrets;

  /// A destination exists but its secrets were lost.
  final bool credentialsMissing;

  /// Whether [secrets] were read; until then they are empty, not missing.
  final bool loaded;

  @override
  List<Object?> get props => [
    destination,
    preset,
    secrets,
    credentialsMissing,
    loaded,
  ];
}

class UploadSettingsCubit extends Cubit<UploadSettingsState> {
  UploadSettingsCubit(this._repository, {required this._tester})
    : super(
        UploadSettingsState(
          destination: _repository.destination,
          preset: _repository.preset,
        ),
      );

  final DestinationRepository _repository;
  final ConnectionTester _tester;

  Future<void> load() async {
    final destination = _repository.destination;
    final preset = _repository.preset;
    if (destination == null) {
      emit(const UploadSettingsState(loaded: true));
      return;
    }
    try {
      emit(
        UploadSettingsState(
          destination: destination,
          preset: preset,
          secrets: await _repository.readSecrets(),
          loaded: true,
        ),
      );
    } on CredentialsMissingException {
      emit(
        UploadSettingsState(
          destination: destination,
          preset: preset,
          credentialsMissing: true,
          loaded: true,
        ),
      );
    }
  }

  /// Whether saving [destination] sends pending photos somewhere else.
  bool replaces(Destination destination) {
    final current = state.destination;
    return current != null && current.fingerprint != destination.fingerprint;
  }

  /// Returns null when the server accepted the connection.
  Future<StorageException?> test(
    Destination destination,
    DestinationSecrets secrets,
  ) async {
    try {
      await _tester(destination, secrets);
      return null;
    } on StorageException catch (error) {
      return error;
    } on Exception catch (error) {
      return StorageException('$error', retryable: false);
    }
  }

  /// Keeps the current mobile data policy and local copy choice.
  Future<void> save(
    Destination destination,
    DestinationSecrets secrets, {
    required ProviderPreset preset,
  }) async {
    final current = state.destination;
    final saved = current == null
        ? destination
        : destination.withPolicy(
            current.policy,
            keepLocalCopy: current.keepLocalCopy,
          );
    final storedPreset = preset == ProviderPreset.custom ? null : preset;
    await _repository.save(saved, secrets, preset: storedPreset);
    emit(
      UploadSettingsState(
        destination: saved,
        preset: storedPreset,
        secrets: secrets,
        loaded: true,
      ),
    );
  }

  Future<void> setPolicy(
    MobileDataPolicy policy, {
    required bool keepLocalCopy,
  }) async {
    final current = state.destination;
    if (current == null) return;
    await _repository.savePolicy(policy, keepLocalCopy: keepLocalCopy);
    emit(
      UploadSettingsState(
        destination: current.withPolicy(policy, keepLocalCopy: keepLocalCopy),
        preset: state.preset,
        secrets: state.secrets,
        credentialsMissing: state.credentialsMissing,
        loaded: state.loaded,
      ),
    );
  }

  Future<void> remove() async {
    await _repository.remove();
    emit(const UploadSettingsState(loaded: true));
  }
}
