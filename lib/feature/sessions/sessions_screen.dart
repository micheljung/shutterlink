import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../settings/settings_cubit.dart';
import 'session.dart';
import 'session_qr_sheet.dart';
import 'sessions_cubit.dart';
import 'sessions_state.dart';

class SessionsScreen extends StatelessWidget {
  const SessionsScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const SessionsScreen());

  static Future<void> showCode(BuildContext context, Session session) async {
    final serverUrl = context.read<SettingsCubit>().state.sessionsServerUrl;
    if (serverUrl == null) return;
    await SessionQrSheet.show(
      context,
      serverUrl: serverUrl,
      code: session.code,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SessionsCubit>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sessions'),
        actions: [
          IconButton(
            tooltip: 'Mark now for clock sync',
            icon: const Icon(Icons.more_time),
            onPressed: () => _markNow(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Start Session'),
        onPressed: () => _start(context),
      ),
      body: BlocBuilder<SessionsCubit, SessionsState>(
        builder: (context, state) {
          if (!state.loaded) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.sessions.isEmpty) {
            return const Center(child: Text('No Sessions yet.'));
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: _fabClearance),
            children: [
              if (state.markedAt case final markedAt?)
                ListTile(
                  leading: const Icon(Icons.more_time),
                  title: Text(
                    'Clock mark set at '
                    '${TimeOfDay.fromDateTime(markedAt.toLocal()).format(context)}',
                  ),
                  subtitle: const Text(
                    'Take a photo, then connect to the camera.',
                  ),
                ),
              for (final session in state.sessions)
                _SessionTile(
                  session: session,
                  blocked:
                      state.blockedId == session.id ||
                      !cubit.canReactivate(session),
                ),
            ],
          );
        },
      ),
    );
  }

  static const _fabClearance = 88.0;

  Future<void> _start(BuildContext context) async {
    final session = await context.read<SessionsCubit>().start();
    if (context.mounted) await showCode(context, session);
  }

  Future<void> _markNow(BuildContext context) async {
    await context.read<SessionsCubit>().markNow();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Marked. Take a photo now, then connect the camera.'),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, required this.blocked});

  final Session session;
  final bool blocked;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SessionsCubit>();
    final localizations = MaterialLocalizations.of(context);
    final expiresAt = session.expiresAt;
    final subtitle = [
      'Started ${localizations.formatMediumDate(session.createdAt.toLocal())}',
      if (session.isActive)
        'Active'
      else if (blocked)
        'Expired'
      else if (expiresAt != null)
        'Expires ${localizations.formatMediumDate(expiresAt.toLocal())}',
    ].join(' · ');
    return ListTile(
      leading: Icon(
        session.isActive ? Icons.radio_button_checked : Icons.qr_code_2,
      ),
      title: Text(session.code),
      subtitle: Text(subtitle),
      onTap: () => SessionsScreen.showCode(context, session),
      trailing: switch ((session.isActive, blocked)) {
        (true, _) => TextButton(
          onPressed: cubit.stop,
          child: const Text('Stop'),
        ),
        (false, true) => TextButton(
          onPressed: () => _startNew(context),
          child: const Text('Start new Session'),
        ),
        (false, false) => TextButton(
          onPressed: () => _reactivate(context),
          child: const Text('Resume'),
        ),
      },
    );
  }

  Future<void> _startNew(BuildContext context) async {
    final session = await context.read<SessionsCubit>().start();
    if (context.mounted) await SessionsScreen.showCode(context, session);
  }

  Future<void> _reactivate(BuildContext context) =>
      context.read<SessionsCubit>().reactivate(session);
}

class SessionsAction extends StatelessWidget {
  const SessionsAction({super.key});

  @override
  Widget build(BuildContext context) {
    final configured = context.select<SettingsCubit, bool>(
      (cubit) => cubit.state.sessionsConfigured,
    );
    if (!configured) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Sessions',
      icon: const Icon(Icons.qr_code_2),
      onPressed: () => Navigator.of(context).push(SessionsScreen.route()),
    );
  }
}
