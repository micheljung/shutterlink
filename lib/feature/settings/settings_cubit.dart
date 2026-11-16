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
    this.hostOverride,
    this.sessionsServerUrl,
    this.sessionsConfigured = false,
    this.sessionsTokenRevision = 0,
    this.onboardingSeen = false,
  });

  final DownloadFormat format;
  final String? hostOverride;
  final String? sessionsServerUrl;
  final bool sessionsConfigured;

  /// Counts saved tokens, so a corrected token wakes a paused upload worker.
  final int sessionsTokenRevision;

  final bool onboardingSeen;

  SettingsState copyWith({
    DownloadFormat? format,
    String? Function()? hostOverride,
    String? Function()? sessionsServerUrl,
    bool? sessionsConfigured,
    int? sessionsTokenRevision,
    bool? onboardingSeen,
  }) => SettingsState(
    format: format ?? this.format,
    hostOverride: hostOverride != null ? hostOverride() : this.hostOverride,
    sessionsServerUrl: sessionsServerUrl != null
        ? sessionsServerUrl()
        : this.sessionsServerUrl,
    sessionsConfigured: sessionsConfigured ?? this.sessionsConfigured,
    sessionsTokenRevision: sessionsTokenRevision ?? this.sessionsTokenRevision,
    onboardingSeen: onboardingSeen ?? this.onboardingSeen,
  );

  @override
  List<Object?> get props => [
    format,
    hostOverride,
    sessionsServerUrl,
    sessionsConfigured,
    sessionsTokenRevision,
    onboardingSeen,
  ];
}

class SettingsCubit extends Cubit<SettingsState> {
  SettingsCubit(this._repository, {this._credentials})
    : super(
        SettingsState(
          format: _repository.format,
          hostOverride: _repository.hostOverride,
          sessionsServerUrl: _repository.sessionsServerUrl,
          onboardingSeen: _repository.onboardingSeen,
        ),
      );

  final SettingsRepository _repository;
  final SessionsCredentials? _credentials;

  Future<void> init() => _refreshSessionsConfigured();

  Future<void> setFormat(DownloadFormat format) async {
    await _repository.setFormat(format);
    emit(state.copyWith(format: format));
  }

  Future<void> markOnboardingSeen() async {
    await _repository.setOnboardingSeen();
    if (isClosed) return;
    emit(state.copyWith(onboardingSeen: true));
  }

  Future<void> setHostOverride(String? host) async {
    await _repository.setHostOverride(host);
    emit(state.copyWith(hostOverride: () => _repository.hostOverride));
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

  /// The saved token as the credentials report it, or null when unreadable.
  Future<String?> sessionsToken() async {
    final credentials = _credentials;
    return credentials == null ? null : _tokenOf(credentials);
  }

  /// Configured means a valid server URL and a token. The token is not
  /// read without a URL.
  Future<void> _refreshSessionsConfigured() async {
    final credentials = _credentials;
    final configured =
        credentials != null &&
        isValidSessionsServerUrl(_repository.sessionsServerUrl) &&
        (await _tokenOf(credentials))?.isNotEmpty == true;
    if (isClosed) return;
    emit(state.copyWith(sessionsConfigured: configured));
  }

  static Future<String?> _tokenOf(SessionsCredentials credentials) async {
    try {
      return await credentials.token();
    } on Object {
      return null;
    }
  }
}
