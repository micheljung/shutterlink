import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../ptpip/camera_client.dart';
import '../spacing.dart';
import 'clock_sync_cubit.dart';
import 'clock_sync_state.dart';

String describeOffset(Duration offset) {
  final seconds = offset.inMilliseconds / Duration.millisecondsPerSecond;
  final rounded = seconds.abs().round();
  if (rounded == 0) return 'in sync';
  return '$rounded s ${seconds > 0 ? 'behind' : 'ahead'}';
}

class ClockSyncBanner extends StatelessWidget {
  const ClockSyncBanner({super.key, required this.client});

  static const _thumbnailSize = 96.0;

  final CameraClient client;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ClockSyncCubit>();
    return BlocConsumer<ClockSyncCubit, ClockState>(
      listenWhen: (_, current) =>
          current is ClockResolved &&
          current.kind != ClockResolution.stored &&
          current.kind != ClockResolution.fresh,
      listener: (context, state) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Camera clock ${describeOffset((state as ClockResolved).offset)}'
            '${state.kind == ClockResolution.assumed ? '' : ', corrected'}.',
          ),
        ),
      ),
      builder: (context, state) => switch (state) {
        ClockPending() => const ListTile(
          dense: true,
          leading: SizedBox.square(
            dimension: Spacing.large,
            child: CircularProgressIndicator(strokeWidth: Spacing.tiny),
          ),
          title: Text('Checking the camera clock…'),
        ),
        ClockResolved(:final offset) => ListTile(
          dense: true,
          leading: const Icon(Icons.schedule),
          title: Text('Camera clock ${describeOffset(offset)}'),
          trailing: TextButton(
            onPressed: cubit.syncShot,
            child: const Text('Sync clock'),
          ),
        ),
        ClockPrompt(:final lastOffset, :final failure) => Card(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.medium),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(switch (failure) {
                  ClockSyncFailure.windowTooLong =>
                    'The sync photo took too long to appear. Try again.',
                  ClockSyncFailure.timeout => 'No sync photo found. Try again.',
                  ClockSyncFailure.noPhoto || null =>
                    'Sync the camera clock so photos go to the right '
                        'Session: tap Sync clock, then take a photo.',
                }),
                OverflowBar(
                  alignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: cubit.useLastOffset,
                      child: Text(
                        lastOffset == null ? 'Skip' : 'Use last offset',
                      ),
                    ),
                    FilledButton(
                      onPressed: cubit.syncShot,
                      child: const Text('Sync clock'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        ClockSyncing() => ListTile(
          leading: const Icon(Icons.photo_camera),
          title: const Text('Take a photo now.'),
          trailing: TextButton(
            onPressed: cubit.cancelSync,
            child: const Text('Cancel'),
          ),
        ),
        ClockAwaitingMarkedPhoto(:final candidate) => Card(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.medium),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: _thumbnailSize,
                  child: FutureBuilder<Uint8List?>(
                    future: client.thumbnail(candidate.thumbnailSource.handle),
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
                const SizedBox(width: Spacing.medium),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Is this the photo you took after Mark now?'),
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
        ),
      },
    );
  }
}
