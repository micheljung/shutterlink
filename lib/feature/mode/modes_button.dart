import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'mode_cubit.dart';

/// Leaves the mode for the picker, with the camera still connected.
class ModesButton extends StatelessWidget {
  const ModesButton({super.key});

  static const tooltip = 'Modes';

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    icon: const Icon(Icons.apps),
    onPressed: context.read<ModeCubit>().leave,
  );
}
