import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/sessions_credentials.dart';
import '../../data/settings_repository.dart';

const _localHosts = {'localhost', '127.0.0.1', '::1'};

bool isValidSessionsServerUrl(String? url) {
  final uri = Uri.tryParse(url?.trim() ?? '');
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return false;
  return uri.scheme == 'https' ||
      (uri.scheme == 'http' && _localHosts.contains(uri.host));
}

class SettingsState extends Equatable {
  const SettingsState({
    required this.format,
    required this.previewQuality,
    this.hostOverride,
    this.sessionsEnabled = false,
    this.sessionsServerUrl,
    this.sessionsConfigured = false,
    this.sessionsTokenRevision = 0,
  });

  final DownloadFormat format;
  final PreviewQuality previewQuality;
  final String? hostOverride;
  final bool sessionsEnabled;
  final String? sessionsServerUrl;
  final bool sessionsConfigured;

  /// Counts saved tokens, so a corrected token wakes a paused upload worker.
  final int sessionsTokenRevision;

  SettingsState copyWith({
    DownloadFormat? format,
    PreviewQuality? previewQuality,
    String? Function()? hostOverride,
    bool? sessionsEnabled,
    String? Function()? sessionsServerUrl,
    bool? sessionsConfigured,
    int? sessionsTokenRevision,
  }) => SettingsState(
    format: format ?? this.format,
    previewQuality: previewQuality ?? this.previewQuality,
    hostOverride: hostOverride != null ? hostOverride() : this.hostOverride,
    sessionsEnabled: sessionsEnabled ?? this.sessionsEnabled,
    sessionsServerUrl: sessionsServerUrl != null
        ? sessionsServerUrl()
        : this.sessionsServerUrl,
    sessionsConfigured: sessionsConfigured ?? this.sessionsConfigured,
    sessionsTokenRevision: sessionsTokenRevision ?? this.sessionsTokenRevision,
  );

  @override
  List<Object?> get props => [
    format,
    previewQuality,
    hostOverride,
    sessionsEnabled,
    sessionsServerUrl,
    sessionsConfigured,
    sessionsTokenRevision,
  ];
}

class SettingsCubit extends Cubit<SettingsState> {
  SettingsCubit(this._repository, {this._credentials})
    : super(
        SettingsState(
          format: _repository.format,
          previewQuality: _repository.previewQuality,
          hostOverride: _repository.hostOverride,
          sessionsEnabled: _repository.sessionsEnabled,
          sessionsServerUrl: _repository.sessionsServerUrl,
        ),
      );

  final SettingsRepository _repository;
  final SessionsCredentials? _credentials;

  Future<void> init() => _refreshSessionsConfigured();

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

  Future<void> setSessionsEnabled(bool enabled) async {
    await _repository.setSessionsEnabled(enabled);
    emit(state.copyWith(sessionsEnabled: enabled));
    await _refreshSessionsConfigured();
  }

  /// An invalid URL keeps the saved one; the form shows the error.
  Future<void> setSessionsServerUrl(String? url) async {
    final cleared = url == null || url.trim().isEmpty;
    if (!cleared && !isValidSessionsServerUrl(url)) return;
    await _repository.setSessionsServerUrl(cleared ? null : url);
    emit(
      state.copyWith(sessionsServerUrl: () => _repository.sessionsServerUrl),
    );
    await _refreshSessionsConfigured();
  }

  Future<void> setSessionsToken(String? token) async {
    await _credentials?.setToken(token);
    if (isClosed) return;
    emit(
      state.copyWith(sessionsTokenRevision: state.sessionsTokenRevision + 1),
    );
    await _refreshSessionsConfigured();
  }

  Future<void> _refreshSessionsConfigured() async {
    final credentials = _credentials;
    final configured =
        credentials != null &&
        _repository.sessionsEnabled &&
        isValidSessionsServerUrl(_repository.sessionsServerUrl) &&
        (await credentials.token())?.isNotEmpty == true;
    if (isClosed) return;
    emit(state.copyWith(sessionsConfigured: configured));
  }
}
