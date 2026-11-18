import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../ptpip/camera_client.dart';
import '../spacing.dart';
import 'clock_sync_cubit.dart';
import 'clock_sync_state.dart';

/// How far the camera clock is off, e.g. "42 s ahead" or "1 h 5 min
/// behind". A positive [offset] means the camera clock is behind.
String describeOffset(Duration offset) {
  final seconds = (offset.inMilliseconds / Duration.millisecondsPerSecond)
      .round();
  if (seconds == 0) return 'in sync';
  final direction = seconds > 0 ? 'behind' : 'ahead';
  return '${_amount(seconds.abs())} $direction';
}

String _amount(int seconds) {
  const secondsPerMinute = 60;
  const minutesPerHour = 60;
  const showSecondsBelow = 2 * secondsPerMinute;
  if (seconds < showSecondsBelow) return '$seconds s';
  final minutes = (seconds / secondsPerMinute).round();
  if (minutes < minutesPerHour) return '$minutes min';
  final hours = minutes ~/ minutesPerHour;
  final rest = minutes % minutesPerHour;
  return rest == 0 ? '$hours h' : '$hours h $rest min';
}

/// The camera clock as the Session sees it. A Session matches photos by
/// their capture time, so a camera clock that is off is measured and
/// corrected for; the camera's own clock is never changed.
class ClockSyncBanner extends StatelessWidget {
  const ClockSyncBanner({super.key, required this.client});

  static const _thumbnailSize = 96.0;

  final CameraClient client;

  static const checkingText = 'Checking the camera clock…';
  static const correctedHint =
      'Shutterlink corrects for this, so photos land in the right Session.';
  static const inSyncHint = 'Photos land in the right Session.';
  static const setCameraHint =
      "To change it, set the date and time in the camera's menu.";
  static const assumedHint =
      'Not measured. If photos land in the wrong Session, measure it with a '
      'sync photo.';
  static const promptText =
      "Shutterlink can't read this camera's clock. To match photos to the "
      'right Session, tap Sync clock, then take a photo with the camera.';
  static const syncingText = 'Take a photo with the camera now';
  static const syncingHint =
      'Shutterlink measures the camera clock from when the photo appears.';
  static const markedQuestion = 'Is this the photo you took after Mark now?';
  static const syncLabel = 'Sync clock';
  static const measureLabel = 'Measure again';

  /// Offsets this far off are worth fixing in the camera itself.
  static const _setCameraFrom = Duration(minutes: 1);

  static String clockText(Duration offset) {
    final described = describeOffset(offset);
    return described == describeOffset(Duration.zero)
        ? 'Camera clock in sync'
        : 'Camera clock is $described';
  }

  static String measuredText(ClockResolved state) =>
      state.kind == ClockResolution.assumed
      ? 'Using the camera clock as it is.'
      : 'Camera clock measured: ${describeOffset(state.offset)}.';

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ClockSyncCubit>();
    final colors = Theme.of(context).colorScheme;
    return BlocConsumer<ClockSyncCubit, ClockState>(
      listenWhen: (_, current) =>
          current is ClockResolved &&
          current.kind != ClockResolution.stored &&
          current.kind != ClockResolution.fresh,
      listener: (context, state) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(measuredText(state as ClockResolved))),
      ),
      builder: (context, state) => Card.outlined(
        margin: EdgeInsets.zero,
        child: switch (state) {
          ClockPending() => const ListTile(
            leading: SizedBox.square(
              dimension: Spacing.large,
              child: CircularProgressIndicator(strokeWidth: Spacing.tiny),
            ),
            title: Text(checkingText),
          ),
          ClockResolved(:final kind, :final offset) => ListTile(
            leading: Icon(
              kind == ClockResolution.assumed
                  ? Icons.schedule
                  : Icons.check_circle_outline,
              color: kind == ClockResolution.assumed ? null : colors.primary,
            ),
            title: Text(clockText(offset)),
            subtitle: Text(_resolvedHint(kind, offset)),
            trailing: _measured(kind)
                ? null
                : TextButton(
                    onPressed: cubit.syncShot,
                    child: const Text(measureLabel),
                  ),
          ),
          ClockPrompt(:final lastOffset, :final failure) => Padding(
            padding: const EdgeInsets.all(Spacing.large),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.schedule, color: colors.tertiary),
                    const SizedBox(width: Spacing.large),
                    Expanded(
                      child: Text(switch (failure) {
                        ClockSyncFailure.windowTooLong =>
                          'The sync photo took too long to appear. Try '
                              'again.',
                        ClockSyncFailure.timeout =>
                          'No sync photo found. Try again.',
                        ClockSyncFailure.noPhoto || null => promptText,
                      }),
                    ),
                  ],
                ),
                OverflowBar(
                  alignment: MainAxisAlignment.end,
                  spacing: Spacing.small,
                  children: [
                    TextButton(
                      onPressed: cubit.useLastOffset,
                      child: Text(
                        lastOffset == null ? 'Skip' : 'Use last offset',
                      ),
                    ),
                    FilledButton(
                      onPressed: cubit.syncShot,
                      child: const Text(syncLabel),
                    ),
                  ],
                ),
              ],
            ),
          ),
          ClockSyncing() => ListTile(
            leading: const Icon(Icons.photo_camera),
            title: const Text(syncingText),
            subtitle: const Text(syncingHint),
            trailing: TextButton(
              onPressed: cubit.cancelSync,
              child: const Text('Cancel'),
            ),
          ),
          ClockAwaitingMarkedPhoto(:final candidate) => Padding(
            padding: const EdgeInsets.all(Spacing.medium),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(Spacing.small),
                  child: SizedBox.square(
                    dimension: _thumbnailSize,
                    child: FutureBuilder<Uint8List?>(
                      future: client.thumbnail(
                        candidate.thumbnailSource.handle,
                      ),
                      builder: (context, snapshot) => switch (snapshot.data) {
                        final bytes? => Image.memory(
                          bytes,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              const Icon(Icons.broken_image_outlined),
                        ),
                        null => const Icon(Icons.image_outlined),
                      },
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.medium),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(markedQuestion),
                      OverflowBar(
                        children: [
                          TextButton(
                            onPressed: cubit.skipMarkedPhoto,
                            child: const Text('Skip'),
                          ),
                          TextButton(
                            onPressed: cubit.nextMarkedPhoto,
                            child: const Text('Next'),
                          ),
                          FilledButton(
                            onPressed: cubit.confirmMarkedPhoto,
                            child: const Text('Use this photo'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        },
      ),
    );
  }

  /// Read from the camera itself, or from a photo: measuring again would
  /// give the same offset.
  static bool _measured(ClockResolution kind) => switch (kind) {
    ClockResolution.fresh ||
    ClockResolution.corrected ||
    ClockResolution.syncShot ||
    ClockResolution.markedPhoto => true,
    ClockResolution.stored || ClockResolution.assumed => false,
  };

  static String _resolvedHint(ClockResolution kind, Duration offset) {
    if (kind == ClockResolution.assumed) return assumedHint;
    if (describeOffset(offset) == describeOffset(Duration.zero)) {
      return inSyncHint;
    }
    return _abs(offset) >= _setCameraFrom
        ? '$correctedHint $setCameraHint'
        : correctedHint;
  }

  static Duration _abs(Duration duration) =>
      duration.isNegative ? -duration : duration;
}
