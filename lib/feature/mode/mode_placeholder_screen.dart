import 'package:flutter/material.dart';

import '../spacing.dart';
import 'modes_button.dart';
import 'operating_mode.dart';

/// A mode that is not built yet.
class ModePlaceholderScreen extends StatelessWidget {
  const ModePlaceholderScreen({super.key, required this.mode});

  static const comingText = 'Coming in this release.';

  final OperatingMode mode;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(mode.label), actions: const [ModesButton()]),
    body: const Center(
      child: Padding(
        padding: EdgeInsets.all(Spacing.large),
        child: Text(comingText),
      ),
    ),
  );
}
