import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/destination_repository.dart';
import '../../upload/backend_factory.dart';
import '../../upload/destination.dart';
import '../../upload/storage_backend.dart';

typedef ConnectionTester = Future<void> Function(
  Destination destination,
  DestinationSecrets secrets,
);

class UploadSettingsState extends Equatable {
  const UploadSettingsState({
    this.destination,
    this.secrets = const DestinationSecrets(),
    this.credentialsMissing = false,
  });

  final Destination? destination;
  final DestinationSecrets secrets;

  /// A destination exists but its secrets were lost.
  final bool credentialsMissing;

  @override
  List<Object?> get props => [destination, secrets, credentialsMissing];
}

class UploadSettingsCubit extends Cubit<UploadSettingsState> {
  UploadSettingsCubit(this._repository, {required this._tester})
    : super(UploadSettingsState(destination: _repository.destination));

  final DestinationRepository _repository;
  final ConnectionTester _tester;

  Future<void> load() async {
    final destination = _repository.destination;
    if (destination == null) {
      emit(const UploadSettingsState());
      return;
    }
    try {
      emit(
        UploadSettingsState(
          destination: destination,
          secrets: await _repository.readSecrets(),
        ),
      );
    } on CredentialsMissingException {
      emit(
        UploadSettingsState(destination: destination, credentialsMissing: true),
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

  Future<void> save(Destination destination, DestinationSecrets secrets) async {
    await _repository.save(destination, secrets);
    emit(UploadSettingsState(destination: destination, secrets: secrets));
  }

  Future<void> remove() async {
    await _repository.remove();
    emit(const UploadSettingsState());
  }
}
