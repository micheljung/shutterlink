import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../settings/settings_cubit.dart';
import 'sessions_cubit.dart';
import 'sessions_screen.dart';
import 'sessions_state.dart';

/// Keeps a running Session visible, since every photo taken meanwhile goes
/// to that person's gallery.
class ActiveSessionIndicator extends StatelessWidget {
  const ActiveSessionIndicator({super.key});

  static String text(String code) => 'Session $code active';

  @override
  Widget build(BuildContext context) {
    final configured = context.select<SettingsCubit, bool>(
      (cubit) => cubit.state.sessionsConfigured,
    );
    return configured ? const _ActiveSession() : const SizedBox.shrink();
  }
}

class _ActiveSession extends StatelessWidget {
  const _ActiveSession();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return BlocSelector<SessionsCubit, SessionsState, String?>(
      selector: (state) => state.active?.code,
      builder: (context, code) => code == null
          ? const SizedBox.shrink()
          : Material(
              color: colors.tertiaryContainer,
              child: ListTile(
                dense: true,
                textColor: colors.onTertiaryContainer,
                iconColor: colors.onTertiaryContainer,
                leading: const Icon(Icons.radio_button_checked),
                title: Text(ActiveSessionIndicator.text(code)),
                onTap: () => Navigator.of(context).push(SessionsScreen.route()),
              ),
            ),
    );
  }
}
