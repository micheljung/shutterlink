import 'package:flutter/material.dart';

import '../../data/identity_repository.dart';
import '../../usb/usb_camera_platform.dart';
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

  /// USB copy, kept out of [all] so it is not numbered as a Wi-Fi step.
  static const usbHint =
      'Or plug the camera in with a USB cable while Shutterlink is open.';
  static const usbExperimentalLabel = 'USB (experimental)';
  static const usbFooterTitle = 'Prefer a cable?';
  static const usbFooter =
      'Open Shutterlink, switch the camera on and plug it into this phone '
      'with a USB data cable, through an OTG adapter if needed. Allow USB '
      'access when asked.';
  static const usbReplug =
      'Nothing happens? Unplug the cable and push it back in firmly at both '
      'ends.';

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

/// How to connect with a cable instead, after the Wi-Fi steps. Shows nothing
/// where the platform has no USB support.
class UsbCableNote extends StatelessWidget {
  const UsbCableNote({super.key, required this.support});

  final UsbSupport support;

  @override
  Widget build(BuildContext context) {
    if (support == UsbSupport.none) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: Spacing.medium),
        Row(
          children: [
            Icon(Icons.usb, color: theme.colorScheme.primary),
            const SizedBox(width: Spacing.small),
            Expanded(
              child: Text(
                SetupSteps.usbFooterTitle,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        if (support == UsbSupport.experimental)
          Text(
            SetupSteps.usbExperimentalLabel,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        const SizedBox(height: Spacing.small),
        Text(SetupSteps.usbFooter, style: body),
        const SizedBox(height: Spacing.small),
        Text(SetupSteps.usbReplug, style: body),
      ],
    );
  }
}
