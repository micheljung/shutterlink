import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/upload_client.dart';
import '../sessions/sessions_dependencies.dart';
import '../spacing.dart';
import 'settings_cards.dart';
import 'settings_cubit.dart';

/// Connects Sessions: server URL, upload token, then a check against the
/// server. Nothing is saved before Finish.
class SessionsSetupScreen extends StatefulWidget {
  const SessionsSetupScreen({super.key});

  static Route<void> route() => MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => const SessionsSetupScreen(),
  );

  @override
  State<SessionsSetupScreen> createState() => _SessionsSetupScreenState();
}

enum _Failure {
  rejected('Token rejected. Check the token and try again.'),
  unsupported(
    "This server can't check tokens. Update it, or save without a check.",
  ),
  unreachable(
    'Could not reach the server. Check the address and the internet '
    'connection.',
  ),
  tokenUnreadable(
    'Could not read the saved token from this device. Enter it again.',
  );

  const _Failure(this.message);

  final String message;

  bool get canSaveAnyway => this == unsupported || this == unreachable;
}

enum _Step {
  server('Server'),
  token('Upload token'),
  check('Check');

  const _Step(this.label);

  final String label;
}

class _SessionsSetupScreenState extends State<SessionsSetupScreen> {
  late final SettingsCubit _settings = context.read<SettingsCubit>();

  /// Editing a connected setup, so an empty token keeps the saved one.
  late final bool _editing = _settings.state.sessionsConfigured;
  late final _url = TextEditingController(
    text: _settings.state.sessionsServerUrl,
  );
  final _token = TextEditingController();
  var _step = _Step.server;
  _Failure? _failure;
  var _busy = false;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  bool get _newToken => _token.text.trim().isNotEmpty;

  void _goTo(_Step step) {
    setState(() {
      _step = step;
      _failure = null;
    });
    if (step == _Step.check) _check();
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    final transport = context.read<SessionsDependencies>().transport;
    try {
      final token = _newToken
          ? _token.text.trim()
          : await _settings.sessionsToken();
      if (token == null) {
        _failure = _Failure.tokenUnreadable;
        return;
      }
      final client = transport.client();
      final TokenCheck result;
      try {
        result = await const UploadClient().checkToken(
          client,
          serverUrl: Uri.parse(_url.text.trim()),
          token: token,
        );
      } finally {
        client.close();
      }
      if (!mounted) return;
      _failure = switch (result) {
        TokenCheck.valid => null,
        TokenCheck.rejected => _Failure.rejected,
        TokenCheck.unsupported => _Failure.unsupported,
        TokenCheck.unreachable => _Failure.unreachable,
      };
      if (result == TokenCheck.valid) await _finish();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Enabling last means uploads never start with a half-saved setup.
  Future<void> _finish() async {
    setState(() => _busy = true);
    try {
      await _settings.setSessionsServerUrl(_url.text.trim());
      if (_newToken) await _settings.setSessionsToken(_token.text);
      await _settings.setSessionsEnabled(true);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SetupScaffold(
      title: _editing ? 'Edit Sessions' : 'Connect Sessions',
      steps: [for (final step in _Step.values) step.label],
      step: _step.index,
      headline: switch (_step) {
        _Step.server => 'Where is your Sessions server?',
        _Step.token => 'Enter the upload token',
        _Step.check => 'Check the token',
      },
      bottomBar: switch (_step) {
        _Step.server => ValueListenableBuilder(
          valueListenable: _url,
          builder: (context, value, _) => SetupButtonBar(
            primary: 'Next',
            onPrimary: isValidSessionsServerUrl(value.text)
                ? () => _goTo(_Step.token)
                : null,
          ),
        ),
        _Step.token => ValueListenableBuilder(
          valueListenable: _token,
          builder: (context, value, _) => SetupButtonBar(
            onBack: () => _goTo(_Step.server),
            primary: 'Next',
            onPrimary: _editing || value.text.trim().isNotEmpty
                ? () => _goTo(_Step.check)
                : null,
          ),
        ),
        _Step.check => SetupButtonBar(
          onBack: _busy ? null : () => _goTo(_Step.token),
          primary: 'Check again',
          onPrimary: _busy ? null : _check,
        ),
      },
      children: switch (_step) {
        _Step.server => [
          Text(
            'The address of the server that hosts your Sessions galleries.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: Spacing.large),
          ValueListenableBuilder(
            valueListenable: _url,
            builder: (context, value, _) => TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: 'Server URL',
                hintText: 'https://photos.example.com',
                errorText:
                    value.text.trim().isEmpty ||
                        isValidSessionsServerUrl(value.text)
                    ? null
                    : 'Use https:// (http:// only for localhost)',
              ),
            ),
          ),
        ],
        _Step.token => [
          Text(
            'The token the server was started with.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: Spacing.large),
          TextField(
            controller: _token,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'Upload token',
              hintText: _editing ? 'Leave empty to keep the saved token' : null,
            ),
          ),
        ],
        _Step.check => [
          SetupCheckStatus(
            busy: _busy,
            busyText: 'Checking the token…',
            error: _failure?.message,
            actions: [
              if (_failure?.canSaveAnyway ?? false)
                OutlinedButton(
                  onPressed: _finish,
                  child: const Text('Save anyway'),
                )
              else
                TextButton(
                  onPressed: () => _goTo(_Step.token),
                  child: const Text('Back to token'),
                ),
            ],
          ),
        ],
      },
    );
  }
}
