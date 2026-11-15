import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../upload/network_policy.dart';
import '../sessions/sessions_upload_cubit.dart';
import '../spacing.dart';
import 'upload_status_cubit.dart';

/// The destination queue and the Sessions queue.
class UploadStatusSheet extends StatelessWidget {
  const UploadStatusSheet({super.key});

  static const sessionsTitle = 'Sessions server';

  static Future<void> show(BuildContext context) {
    final cubit = context.read<UploadStatusCubit>();
    final sessions = context.read<SessionsUploadCubit>();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => MultiBlocProvider(
        providers: [
          BlocProvider.value(value: cubit),
          BlocProvider.value(value: sessions),
        ],
        child: const UploadStatusSheet(),
      ),
    );
  }

  static String sessionsText(int pending) =>
      pending == 1 ? '1 photo waiting' : '$pending photos waiting';

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
              const _SessionsQueue(),
            ],
          ),
        );
      },
    );
  }
}

class _SessionsQueue extends StatelessWidget {
  const _SessionsQueue();

  @override
  Widget build(BuildContext context) {
    final pending = context.select<SessionsUploadCubit, int>(
      (cubit) => cubit.state.pending,
    );
    if (pending == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.large),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            UploadStatusSheet.sessionsTitle,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: Spacing.small),
          Text(UploadStatusSheet.sessionsText(pending)),
        ],
      ),
    );
  }
}
