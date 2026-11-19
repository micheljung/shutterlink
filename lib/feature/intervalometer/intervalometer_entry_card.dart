import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../spacing.dart';
import 'interval_run.dart';
import 'intervalometer_cubit.dart';
import 'intervalometer_screen.dart';
import 'intervalometer_text.dart';

/// Opens the intervalometer, which needs no Wi-Fi connection, and shows a
/// run that goes on in the background.
class IntervalometerEntryCard extends StatelessWidget {
  const IntervalometerEntryCard({super.key});

  static const subtitle = 'Time-lapses and long exposures over Bluetooth';

  static const _radius = 20.0;
  static const _iconRadius = 22.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final run = context.select<IntervalometerCubit, RunSnapshot?>(
      (cubit) => cubit.state.running ? cubit.state.run : null,
    );
    return Card.filled(
      margin: const EdgeInsets.symmetric(vertical: Spacing.extraSmall),
      color: run == null
          ? colors.surfaceContainerLow
          : colors.tertiaryContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(IntervalometerScreen.route()),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.medium),
          child: Row(
            children: [
              CircleAvatar(
                radius: _iconRadius,
                backgroundColor: colors.tertiary,
                foregroundColor: colors.onTertiary,
                child: const Icon(Icons.timer_outlined),
              ),
              const SizedBox(width: Spacing.medium),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      IntervalometerText.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      run == null
                          ? subtitle
                          : 'Running · shot ${IntervalometerText.progress(run)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: run == null
                            ? colors.onSurfaceVariant
                            : colors.onTertiaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
