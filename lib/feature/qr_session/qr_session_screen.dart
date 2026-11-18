import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../brand/brand_theme.dart';
import '../../demo/demo_shutter_button.dart';
import '../mode/mode_back_button.dart';
import '../mode/operating_mode.dart';
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

  static const sessionsTooltip = 'Past Sessions';
  static const notificationsHint =
      'Notifications are off, so the mode only shows here.';
  static const autoResumedText =
      'Resumed the Session that was open when the connection was lost.';
  static const openTitle = 'Session open';
  static const openHint = 'Guests scan this code to see your photos.';
  static const openDetail = 'Every photo you take now goes to their gallery.';
  static const enlargeTooltip = 'Show large';
  static const copyTooltip = 'Copy link';
  static const copiedText = 'Link copied.';
  static const closedText = 'No Session open';
  static const closedHint =
      'Start a Session to show guests a QR code. Only photos taken while a '
      'Session is open go to their gallery.';
  static const stopLabel = 'Stop Session';
  static const startLabel = 'Start new Session';
  static const resumeLabel = 'Resume';
  static const resumeHint =
      'Guests who scanned its code before keep the same gallery.';

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
        leading: const ModeBackButton(),
        title: Text(OperatingMode.qrSession.label),
        actions: [
          const UploadStatusIndicator(),
          IconButton(
            tooltip: sessionsTooltip,
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.of(context).push(SessionsScreen.route()),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxContentWidth),
            child: ListView(
              padding: const EdgeInsets.all(Spacing.large).copyWith(
                bottom: DemoShutterButton.showsFor(client)
                    ? DemoShutterButton.clearance
                    : null,
              ),
              children: [
                if (state.notificationsDenied) ...[
                  const _Notice(
                    icon: Icons.notifications_off_outlined,
                    text: notificationsHint,
                  ),
                  const SizedBox(height: Spacing.medium),
                ],
                if (state.autoResumed) ...[
                  const _Notice(icon: Icons.restart_alt, text: autoResumedText),
                  const SizedBox(height: Spacing.medium),
                ],
                if (client != null && clockSync != null) ...[
                  BlocProvider.value(
                    value: clockSync,
                    child: ClockSyncBanner(client: client),
                  ),
                  const SizedBox(height: Spacing.medium),
                ],
                if (resumable != null)
                  _ResumePrompt(session: resumable)
                else
                  const _Window(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static const _maxContentWidth = 560.0;
}

/// The rounded card every part of the screen sits on.
class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  static const radius = 28.0;

  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    margin: EdgeInsets.zero,
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
    child: Padding(
      padding: const EdgeInsets.all(Spacing.extraLarge),
      child: child,
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colors.secondaryContainer,
      child: ListTile(
        iconColor: colors.onSecondaryContainer,
        textColor: colors.onSecondaryContainer,
        leading: Icon(icon),
        title: Text(text),
      ),
    );
  }
}

/// A large icon on a tinted disc, at the top of a panel.
class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  static const _size = 72.0;
  static const _iconSize = 36.0;
  static const _alpha = 0.14;

  @override
  Widget build(BuildContext context) => Container(
    width: _size,
    height: _size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color.withValues(alpha: _alpha),
    ),
    child: Icon(icon, size: _iconSize, color: color),
  );
}

class _ResumePrompt extends StatelessWidget {
  const _ResumePrompt({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QrSessionCubit>();
    final theme = Theme.of(context);
    return _Panel(
      child: Column(
        children: [
          _Badge(icon: Icons.history, color: theme.colorScheme.primary),
          const SizedBox(height: Spacing.large),
          Text(
            QrSessionScreen.resumeQuestion(session.code),
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Spacing.small),
          Text(
            QrSessionScreen.resumeHint,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Spacing.extraLarge),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.play_arrow),
              onPressed: cubit.resume,
              label: const Text(QrSessionScreen.resumeLabel),
            ),
          ),
          const SizedBox(height: Spacing.small),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: cubit.startNew,
              child: const Text(QrSessionScreen.startLabel),
            ),
          ),
        ],
      ),
    );
  }
}

/// The open window's QR code, or what can be opened.
class _Window extends StatelessWidget {
  const _Window();

  @override
  Widget build(BuildContext context) {
    final serverUrl = context.select<SettingsCubit, String?>(
      (cubit) => cubit.state.validSessionsServerUrl,
    );
    return BlocBuilder<SessionsCubit, SessionsState>(
      builder: (context, state) {
        if (!state.loaded) {
          return const Padding(
            padding: EdgeInsets.all(Spacing.extraLarge),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final active = state.active;
        if (active != null) {
          return _OpenWindow(session: active, serverUrl: serverUrl);
        }
        return _ClosedWindow(last: state.sessions.firstOrNull);
      },
    );
  }
}

class _OpenWindow extends StatelessWidget {
  const _OpenWindow({required this.session, required this.serverUrl});

  final Session session;
  final String? serverUrl;

  static const _maxQrSize = 320.0;
  static const _dotSize = 10.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final serverUrl = this.serverUrl;
    final online = BrandColors.online(theme.brightness);
    return _Panel(
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: _dotSize,
                height: _dotSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: online,
                ),
              ),
              const SizedBox(width: Spacing.small),
              Text(
                QrSessionScreen.openTitle,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: online,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.small),
          Text(
            QrSessionScreen.openHint,
            style: theme.textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Spacing.large),
          if (serverUrl != null)
            LayoutBuilder(
              builder: (context, constraints) => _QrTile(
                serverUrl: serverUrl,
                code: session.code,
                size: min(
                  constraints.maxWidth - 2 * _QrTile.padding,
                  _maxQrSize,
                ),
              ),
            ),
          const SizedBox(height: Spacing.large),
          SelectableText(
            session.code,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
          ),
          if (serverUrl != null) ...[
            const SizedBox(height: Spacing.extraSmall),
            _Link(url: sessionPageUrl(serverUrl, session.code).toString()),
          ],
          const SizedBox(height: Spacing.medium),
          Text(
            QrSessionScreen.openDetail,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Spacing.extraLarge),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.error,
                side: BorderSide(color: colors.error.withValues(alpha: 0.5)),
              ),
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text(QrSessionScreen.stopLabel),
              onPressed: context.read<SessionsCubit>().stop,
            ),
          ),
        ],
      ),
    );
  }
}

/// The QR code on white, which scanners need; a tap shows it large.
class _QrTile extends StatelessWidget {
  const _QrTile({
    required this.serverUrl,
    required this.code,
    required this.size,
  });

  final String serverUrl;
  final String code;
  final double size;

  static const padding = Spacing.large;
  static const _radius = 20.0;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: QrSessionScreen.enlargeTooltip,
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(_radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () =>
            SessionQrSheet.show(context, serverUrl: serverUrl, code: code),
        child: Padding(
          padding: const EdgeInsets.all(padding),
          child: SessionQrImage(serverUrl: serverUrl, code: code, size: size),
        ),
      ),
    ),
  );
}

class _Link extends StatelessWidget {
  const _Link({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: SelectableText(
            url,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        IconButton(
          tooltip: QrSessionScreen.copyTooltip,
          visualDensity: VisualDensity.compact,
          iconSize: Spacing.large + Spacing.tiny,
          icon: const Icon(Icons.copy),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: url));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text(QrSessionScreen.copiedText)),
            );
          },
        ),
      ],
    );
  }
}

class _ClosedWindow extends StatelessWidget {
  const _ClosedWindow({required this.last});

  final Session? last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = context.read<SessionsCubit>();
    final last = this.last;
    final resumable = last != null && sessions.canReactivate(last);
    return _Panel(
      child: Column(
        children: [
          _Badge(icon: Icons.qr_code_2, color: theme.colorScheme.primary),
          const SizedBox(height: Spacing.large),
          Text(
            QrSessionScreen.closedText,
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Spacing.small),
          Text(
            QrSessionScreen.closedHint,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Spacing.extraLarge),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.qr_code),
              onPressed: sessions.start,
              label: const Text(QrSessionScreen.startLabel),
            ),
          ),
          if (resumable) ...[
            const SizedBox(height: Spacing.small),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.play_arrow),
                onPressed: () => sessions.reactivate(last),
                label: Text('${QrSessionScreen.resumeLabel} ${last.code}'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
