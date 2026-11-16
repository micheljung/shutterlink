import 'package:flutter/material.dart';

import '../../data/identity_repository.dart';
import '../spacing.dart';

abstract final class SetupSteps {
  static const title = 'Set up the camera';
  static const all = [
    'On the camera, open MENU → Wireless communication settings → '
        'Wi-Fi function.',
    'Choose Remote control (EOS Utility) → Add a device.',
    'Select Camera access point mode → Easy connection.',
    "On this phone, join the Wi-Fi network shown on the camera's screen.",
    'Come back here and tap Connect.',
    'The first time, confirm "${IdentityRepository.friendlyName}" on the '
        'camera when it asks to pair.',
  ];

  static const cameraMenu = [
    'MENU',
    'Wireless communication settings',
    'Wi-Fi function',
    'Remote control (EOS Utility)',
    'Add a device',
  ];

  /// The parts the user looks for on the camera or in the app.
  static const emphasisTerms = [
    'MENU → Wireless communication settings → Wi-Fi function',
    'Remote control (EOS Utility) → Add a device',
    'Camera access point mode → Easy connection',
    'Connect',
    '"${IdentityRepository.friendlyName}"',
  ];

  static TextSpan emphasized(String step, TextStyle emphasis) {
    final spans = <TextSpan>[];
    var rest = step;
    while (rest.isNotEmpty) {
      (int, String)? next;
      for (final term in emphasisTerms) {
        final index = rest.indexOf(term);
        if (index >= 0 && (next == null || index < next.$1)) {
          next = (index, term);
        }
      }
      if (next == null) {
        spans.add(TextSpan(text: rest));
        break;
      }
      final (index, term) = next;
      if (index > 0) spans.add(TextSpan(text: rest.substring(0, index)));
      spans.add(TextSpan(text: term, style: emphasis));
      rest = rest.substring(index + term.length);
    }
    return TextSpan(children: spans);
  }
}

class SetupStepList extends StatelessWidget {
  const SetupStepList({super.key, required this.first, required this.count});

  final int first;
  final int count;

  static const _badgeSize = 28.0;

  /// Aligns the first text line with the badge's centre.
  static const _textTopInset = 3.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = theme.textTheme.bodyLarge?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final emphasis = TextStyle(
      fontWeight: FontWeight.w700,
      color: colors.onSurface,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = first; index < first + count; index++)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.medium),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: _badgeSize,
                  height: _badgeSize,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${index + 1}',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.onPrimaryContainer,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.medium),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: _textTopInset),
                    child: Text.rich(
                      SetupSteps.emphasized(SetupSteps.all[index], emphasis),
                      style: style,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
