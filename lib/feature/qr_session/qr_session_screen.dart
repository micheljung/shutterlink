import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../demo/demo_shutter_button.dart';
import '../mode/modes_button.dart';
import '../mode/operating_mode.dart';
import '../sessions/active_session_indicator.dart';
import '../sessions/clock_sync_banner.dart';
import '../sessions/session.dart';
import '../sessions/session_qr_sheet.dart';
import '../sessions/sessions_cubit.dart';
import '../sessions/sessions_screen.dart';
import '../sessions/sessions_state.dart';
import '../settings/settings_cubit.dart';
import '../spacing.dart';
import '../upload/upload_status_indicator.dart';
import 'qr_session_cubit.dart';

/// QR Session: guests scan the code, and every shot taken while the
/// window is open goes to their gallery on the Sessions server.
class QrSessionScreen extends StatelessWidget {
  const QrSessionScreen({super.key});

  static const sessionsTooltip = 'Sessions';
  static const markNowTooltip = 'Mark now for clock sync';
  static const markedText =
      'Marked. Take a photo now, then connect the camera.';
  static const notificationsHint =
      'Notifications are off, so the mode only shows here.';
  static const closedText = 'No Session window is open.';
  static const closedHint = 'Photos taken now go nowhere.';
  static const stopLabel = 'Stop';
  static const startLabel = 'Start new Session';
  static const resumeLabel = 'Resume';

  static String resumeQuestion(String code) =>
      'Resume Session $code or start a new one?';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<QrSessionCubit>().state;
    final client = state.client;
    final clockSync = state.clockSync;
    final resumable = state.resumable;
    return Scaffold(
      floatingActionButton: DemoShutterButton(client: client),
      appBar: AppBar(
        title: Text(OperatingMode.qrSession.label),
        actions: [
          const UploadStatusIndicator(),
          IconButton(
            tooltip: markNowTooltip,
            icon: const Icon(Icons.more_time),
            onPressed: () => _markNow(context),
          ),
          IconButton(
            tooltip: sessionsTooltip,
            icon: const Icon(Icons.list_alt),
            onPressed: () => Navigator.of(context).push(SessionsScreen.route()),
          ),
          const ModesButton(),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(Spacing.large).copyWith(
          bottom: DemoShutterButton.showsFor(client)
              ? DemoShutterButton.clearance
              : null,
        ),
        children: [
          if (state.notificationsDenied)
            const Card(
              child: ListTile(
                leading: Icon(Icons.notifications_off_outlined),
                title: Text(notificationsHint),
              ),
            ),
          if (client != null && clockSync != null)
            BlocProvider.value(
              value: clockSync,
              child: ClockSyncBanner(client: client),
            ),
          const ActiveSessionIndicator(),
          const SizedBox(height: Spacing.medium),
          if (resumable != null)
            _ResumePrompt(session: resumable)
          else
            const _Window(),
        ],
      ),
    );
  }

  Future<void> _markNow(BuildContext context) async {
    await context.read<SessionsCubit>().markNow();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text(markedText)));
  }
}

class _ResumePrompt extends StatelessWidget {
  const _ResumePrompt({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QrSessionCubit>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.medium),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              QrSessionScreen.resumeQuestion(session.code),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Spacing.small),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Spacing.small,
              children: [
                TextButton(
                  onPressed: cubit.startNew,
                  child: const Text(QrSessionScreen.startLabel),
                ),
                FilledButton(
                  onPressed: cubit.resume,
                  child: const Text(QrSessionScreen.resumeLabel),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The open window's QR code, or what can be opened.
class _Window extends StatelessWidget {
  const _Window();

  static const _maxQrSize = 360.0;

  @override
  Widget build(BuildContext context) {
    final serverUrl = context.select<SettingsCubit, String?>(
      (cubit) => cubit.state.sessionsServerUrl,
    );
    final sessions = context.read<SessionsCubit>();
    return BlocBuilder<SessionsCubit, SessionsState>(
      builder: (context, state) {
        if (!state.loaded) {
          return const Center(child: CircularProgressIndicator());
        }
        final active = state.active;
        if (active != null) {
          return Column(
            children: [
              if (serverUrl != null)
                LayoutBuilder(
                  builder: (context, constraints) => SessionQrCode(
                    serverUrl: serverUrl,
                    code: active.code,
                    size: min(
                      constraints.maxWidth - 2 * Spacing.medium,
                      _maxQrSize,
                    ),
                  ),
                ),
              const SizedBox(height: Spacing.large),
              OutlinedButton.icon(
                icon: const Icon(Icons.stop),
                label: const Text(QrSessionScreen.stopLabel),
                onPressed: sessions.stop,
              ),
            ],
          );
        }
        final last = state.sessions.firstOrNull;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ListTile(
              leading: Icon(Icons.qr_code_2),
              title: Text(QrSessionScreen.closedText),
              subtitle: Text(QrSessionScreen.closedHint),
            ),
            const SizedBox(height: Spacing.medium),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: Spacing.small,
              children: [
                if (last != null && sessions.canReactivate(last))
                  OutlinedButton(
                    onPressed: () => sessions.reactivate(last),
                    child: Text('${QrSessionScreen.resumeLabel} ${last.code}'),
                  ),
                FilledButton(
                  onPressed: sessions.start,
                  child: const Text(QrSessionScreen.startLabel),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
