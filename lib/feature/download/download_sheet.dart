import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../ptpip/camera_client.dart';
import '../connect/connect_cubit.dart';
import '../connect/connect_state.dart';
import '../spacing.dart';
import 'download_cubit.dart';
import 'download_state.dart';

class DownloadSheet extends StatelessWidget {
  const DownloadSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => const DownloadSheet(),
  );

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<DownloadCubit, DownloadState>(
        builder: (context, state) => Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.extraLarge,
            0,
            Spacing.extraLarge,
            Spacing.extraLarge,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _title(state),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: Spacing.large),
              if (state.isActive) ..._progress(context, state),
              if (!state.isActive) _Summary(state: state),
              const SizedBox(height: Spacing.large),
              _actions(context, state),
            ],
          ),
        ),
      );

  String _title(DownloadState state) => switch (state.status) {
    DownloadStatus.running => 'Downloading',
    DownloadStatus.paused => 'Download paused',
    DownloadStatus.cancelled => 'Download cancelled',
    DownloadStatus.completed => 'Download finished',
    DownloadStatus.idle => 'No download',
  };

  List<Widget> _progress(BuildContext context, DownloadState state) {
    final current = state.nextTask < state.tasks.length
        ? state.nextTask + 1
        : state.tasks.length;
    return [
      if (state.error != null) ...[
        Text(
          state.error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        const SizedBox(height: Spacing.medium),
      ],
      Text(state.currentFile ?? ''),
      const SizedBox(height: Spacing.extraSmall),
      LinearProgressIndicator(value: state.fileProgress),
      const SizedBox(height: Spacing.large),
      Text('Photo $current of ${state.tasks.length}'),
      const SizedBox(height: Spacing.extraSmall),
      LinearProgressIndicator(value: state.overallProgress),
    ];
  }

  Widget _actions(BuildContext context, DownloadState state) {
    final cubit = context.read<DownloadCubit>();
    final client = context.select<ConnectCubit, CameraClient?>(
      (cubit) => switch (cubit.state) {
        ConnectConnected(:final client) => client,
        _ => null,
      },
    );
    return switch (state.status) {
      DownloadStatus.running => OutlinedButton(
        onPressed: cubit.cancel,
        child: const Text('Cancel'),
      ),
      DownloadStatus.paused => Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: cubit.cancel,
              child: const Text('Cancel'),
            ),
          ),
          const SizedBox(width: Spacing.medium),
          Expanded(
            child: FilledButton(
              onPressed: client == null ? null : () => cubit.resume(client),
              child: const Text('Resume'),
            ),
          ),
        ],
      ),
      _ => FilledButton(
        onPressed: () {
          cubit.dismiss();
          Navigator.of(context).pop();
        },
        child: const Text('Done'),
      ),
    };
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.state});

  final DownloadState state;

  static String _reasonLabel(DownloadFailureReason reason) => switch (reason) {
    DownloadFailureReason.saveFailed => 'Failed',
    DownloadFailureReason.photoChanged => 'Photo changed on the camera',
  };

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Saved: ${state.saved.length}'),
      if (state.skipped.isNotEmpty)
        Text(
          'Skipped (format not on card): '
          '${state.skipped.map((group) => group.baseName).join(', ')}',
        ),
      if (state.alreadyDownloaded.isNotEmpty)
        Text('${state.alreadyDownloaded.length} already downloaded, skipped'),
      for (final reason in DownloadFailureReason.values)
        if (state.failed.any((failure) => failure.reason == reason))
          Text(
            '${_reasonLabel(reason)}: '
            '${state.failed.where((failure) => failure.reason == reason).map((failure) => failure.group.baseName).join(', ')}',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
    ],
  );
}
