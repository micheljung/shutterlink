import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/settings_repository.dart';

class SettingsState extends Equatable {
  const SettingsState({required this.format, this.hostOverride});

  final DownloadFormat format;
  final String? hostOverride;

  @override
  List<Object?> get props => [format, hostOverride];
}

class SettingsCubit extends Cubit<SettingsState> {
  SettingsCubit(this._repository)
    : super(
        SettingsState(
          format: _repository.format,
          hostOverride: _repository.hostOverride,
        ),
      );

  final SettingsRepository _repository;

  Future<void> setFormat(DownloadFormat format) async {
    await _repository.setFormat(format);
    emit(SettingsState(format: format, hostOverride: state.hostOverride));
  }

  Future<void> setHostOverride(String? host) async {
    await _repository.setHostOverride(host);
    emit(
      SettingsState(
        format: state.format,
        hostOverride: _repository.hostOverride,
      ),
    );
  }
}
