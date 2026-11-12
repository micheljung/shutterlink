import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/settings_repository.dart';

class SettingsState extends Equatable {
  const SettingsState({
    required this.format,
    required this.previewQuality,
    this.hostOverride,
  });

  final DownloadFormat format;
  final PreviewQuality previewQuality;
  final String? hostOverride;

  SettingsState copyWith({
    DownloadFormat? format,
    PreviewQuality? previewQuality,
    String? Function()? hostOverride,
  }) => SettingsState(
    format: format ?? this.format,
    previewQuality: previewQuality ?? this.previewQuality,
    hostOverride: hostOverride != null ? hostOverride() : this.hostOverride,
  );

  @override
  List<Object?> get props => [format, previewQuality, hostOverride];
}

class SettingsCubit extends Cubit<SettingsState> {
  SettingsCubit(this._repository)
    : super(
        SettingsState(
          format: _repository.format,
          previewQuality: _repository.previewQuality,
          hostOverride: _repository.hostOverride,
        ),
      );

  final SettingsRepository _repository;

  Future<void> setFormat(DownloadFormat format) async {
    await _repository.setFormat(format);
    emit(state.copyWith(format: format));
  }

  Future<void> setPreviewQuality(PreviewQuality quality) async {
    await _repository.setPreviewQuality(quality);
    emit(state.copyWith(previewQuality: quality));
  }

  Future<void> setHostOverride(String? host) async {
    await _repository.setHostOverride(host);
    emit(state.copyWith(hostOverride: () => _repository.hostOverride));
  }
}
