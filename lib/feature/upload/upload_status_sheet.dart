import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../upload/network_policy.dart';
import '../spacing.dart';
import 'upload_status_cubit.dart';

class UploadStatusSheet extends StatelessWidget {
  const UploadStatusSheet({super.key});

  static Future<void> show(BuildContext context) {
    final cubit = context.read<UploadStatusCubit>();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          BlocProvider.value(value: cubit, child: const UploadStatusSheet()),
    );
  }

  static String waitText(WaitReason reason) => switch (reason) {
    WaitReason.noDestination => 'No upload destination set',
    WaitReason.network => 'Waiting for Wi-Fi/mobile data',
    WaitReason.unmeteredNetwork => 'Waiting for Wi-Fi',
    WaitReason.backoff => 'Retrying soon',
    WaitReason.attention => 'Upload failed. Check the destination in Settings.',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return BlocBuilder<UploadStatusCubit, UploadStatusState>(
      builder: (context, state) {
        final cubit = context.read<UploadStatusCubit>();
        final uploading = state.uploadingFile;
        final waitReason = state.waitReason;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(
              Spacing.large,
              0,
              Spacing.large,
              Spacing.large,
            ),
            children: [
              Text('Uploads', style: theme.textTheme.titleMedium),
              const SizedBox(height: Spacing.small),
              if (uploading != null) ...[
                Text('Uploading $uploading'),
                const SizedBox(height: Spacing.small),
                LinearProgressIndicator(value: state.progress),
              ] else if (waitReason != null)
                Text(waitText(waitReason))
              else if (state.pending == 0)
                const Text('All photos are uploaded.'),
              const SizedBox(height: Spacing.small),
              Text(
                '${state.pending} waiting · ${state.completed} uploaded',
                style: theme.textTheme.bodySmall,
              ),
              for (final item in state.failed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.error_outline,
                    color: theme.colorScheme.error,
                  ),
                  title: Text(item.filename),
                  subtitle: Text(item.lastError ?? ''),
                ),
              const SizedBox(height: Spacing.small),
              Wrap(
                spacing: Spacing.small,
                runSpacing: Spacing.small,
                children: [
                  if (state.pending > 0 && uploading == null)
                    OutlinedButton(
                      onPressed: cubit.retryNow,
                      child: const Text('Retry now'),
                    ),
                  if (state.keptCopies > 0)
                    OutlinedButton(
                      onPressed: cubit.removeKeptCopies,
                      child: Text(
                        state.keptCopies == 1
                            ? 'Remove 1 kept copy'
                            : 'Remove ${state.keptCopies} kept copies',
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
