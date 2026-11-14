import 'package:flutter/material.dart';

import '../spacing.dart';

class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.extraSmall,
        Spacing.large,
        0,
        Spacing.small,
      ),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card.outlined(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(Spacing.large),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}

/// A configured service: what it is, where it points, and its actions.
class SettingsSummaryCard extends StatelessWidget {
  const SettingsSummaryCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.error,
    required this.actions,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? error;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card.filled(
      margin: EdgeInsets.zero,
      color: colors.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.large),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: colors.secondary,
                  foregroundColor: colors.onSecondary,
                  child: Icon(icon),
                ),
                const SizedBox(width: Spacing.large),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      Text(subtitle, style: theme.textTheme.bodyMedium),
                      if (error case final error?)
                        Text(
                          error,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.error,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.small),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Spacing.small,
              children: actions,
            ),
          ],
        ),
      ),
    );
  }
}

/// A service that is not set up yet, with the button that sets it up.
class SettingsEmptyCard extends StatelessWidget {
  const SettingsEmptyCard({
    super.key,
    required this.icon,
    required this.title,
    required this.text,
    required this.action,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String text;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingsCard(
      children: [
        Row(
          children: [
            Icon(icon, color: theme.colorScheme.outline),
            const SizedBox(width: Spacing.medium),
            Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
          ],
        ),
        const SizedBox(height: Spacing.small),
        Text(text, style: theme.textTheme.bodyMedium),
        const SizedBox(height: Spacing.medium),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(onPressed: onPressed, child: Text(action)),
        ),
      ],
    );
  }
}

/// A full-screen step-by-step setup: close button, progress, step label,
/// question and a Back/Next bar.
class SetupScaffold extends StatelessWidget {
  const SetupScaffold({
    super.key,
    required this.title,
    required this.steps,
    required this.step,
    required this.headline,
    required this.children,
    required this.bottomBar,
  });

  final String title;
  final List<String> steps;
  final int step;
  final String headline;
  final List<Widget> children;
  final Widget bottomBar;

  static const _progressHeight = 4.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: const CloseButton(),
        title: Text(title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(_progressHeight),
          child: LinearProgressIndicator(value: (step + 1) / steps.length),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(Spacing.large),
        children: [
          Text(
            'Step ${step + 1} of ${steps.length} · ${steps[step]}',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: Spacing.extraSmall),
          Text(headline, style: theme.textTheme.headlineSmall),
          const SizedBox(height: Spacing.large),
          ...children,
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.large),
          child: bottomBar,
        ),
      ),
    );
  }
}

/// Back (unless on the first step) and a primary button filling the rest.
class SetupButtonBar extends StatelessWidget {
  const SetupButtonBar({
    super.key,
    this.onBack,
    required this.primary,
    required this.onPrimary,
  });

  final VoidCallback? onBack;
  final String primary;
  final VoidCallback? onPrimary;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (onBack case final onBack?) ...[
        OutlinedButton(onPressed: onBack, child: const Text('Back')),
        const SizedBox(width: Spacing.medium),
      ],
      Expanded(
        child: FilledButton(onPressed: onPrimary, child: Text(primary)),
      ),
    ],
  );
}

class InfoBox extends StatelessWidget {
  const InfoBox(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Card.filled(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(Spacing.medium),
      child: Row(
        children: [
          const Icon(Icons.info_outline),
          const SizedBox(width: Spacing.medium),
          Expanded(child: Text(text)),
        ],
      ),
    ),
  );
}

/// A failed check, with the ways out of it.
class ErrorBox extends StatelessWidget {
  const ErrorBox(this.text, {super.key, this.actions = const []});

  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card.filled(
      margin: EdgeInsets.zero,
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.medium),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, color: colors.onErrorContainer),
                const SizedBox(width: Spacing.medium),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(color: colors.onErrorContainer),
                  ),
                ),
              ],
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: Spacing.small),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: Spacing.small,
                children: actions,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The last step of a setup: progress while checking, then the failure and
/// its ways out, or a note.
class SetupCheckStatus extends StatelessWidget {
  const SetupCheckStatus({
    super.key,
    required this.busy,
    required this.busyText,
    this.error,
    this.actions = const [],
    this.note,
  });

  final bool busy;
  final String busyText;
  final String? error;
  final List<Widget> actions;
  final String? note;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(busyText),
          const SizedBox(height: Spacing.medium),
          const LinearProgressIndicator(),
        ],
      );
    }
    if (error case final error?) return ErrorBox(error, actions: actions);
    if (note case final note?) return Text(note);
    return const SizedBox.shrink();
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  String? content,
  Widget? contentWidget,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: contentWidget ?? Text(content!),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
