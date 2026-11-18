import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'mode_cubit.dart';

/// The app bar's back arrow in a mode: it leaves the mode for the picker,
/// with the camera still connected, like the system back gesture does.
class ModeBackButton extends StatelessWidget {
  const ModeBackButton({super.key});

  static const tooltip = 'Back to modes';

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    icon: const BackButtonIcon(),
    onPressed: context.read<ModeCubit>().leave,
  );
}
