import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../sessions/sessions_upload_cubit.dart';
import '../settings/upload_settings_cubit.dart';
import 'upload_status_cubit.dart';
import 'upload_status_sheet.dart';

/// Shows whether uploads are waiting, in every mode. It stands out while
/// the destination queue or the Sessions queue has photos left, stays plain
/// while a destination is set, and is hidden otherwise.
class UploadStatusIndicator extends StatelessWidget {
  const UploadStatusIndicator({super.key});

  static const tooltip = 'Uploads';

  @override
  Widget build(BuildContext context) {
    final destination = context.select<UploadSettingsCubit, bool>(
      (cubit) => cubit.state.destination != null,
    );
    final pending =
        context.select<UploadStatusCubit, int>((cubit) => cubit.state.pending) +
        context.select<SessionsUploadCubit, int>(
          (cubit) => cubit.state.pending,
        );
    if (!destination && pending == 0) return const SizedBox.shrink();
    return IconButton(
      tooltip: tooltip,
      isSelected: pending > 0,
      icon: const Icon(Icons.cloud_upload_outlined),
      selectedIcon: Badge(
        label: Text('$pending'),
        child: const Icon(Icons.cloud_upload),
      ),
      onPressed: () => UploadStatusSheet.show(context),
    );
  }
}
