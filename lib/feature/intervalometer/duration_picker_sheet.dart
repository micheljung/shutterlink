import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../spacing.dart';
import 'intervalometer_text.dart';

/// Picks a duration with quick picks for the usual values and wheels for
/// any other.
class DurationPickerSheet extends StatefulWidget {
  const DurationPickerSheet({
    super.key,
    required this.title,
    required this.initial,
    required this.quickPicks,
    this.min = Duration.zero,
    this.max = const Duration(hours: 24),
    this.hint,
  });

  static const doneLabel = 'Done';

  final String title;
  final Duration initial;
  final List<Duration> quickPicks;
  final Duration min;
  final Duration max;
  final String? hint;

  static Future<Duration?> show(
    BuildContext context, {
    required String title,
    required Duration initial,
    required List<Duration> quickPicks,
    Duration min = Duration.zero,
    Duration max = const Duration(hours: 24),
    String? hint,
  }) => showModalBottomSheet<Duration>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => DurationPickerSheet(
      title: title,
      initial: initial,
      quickPicks: quickPicks,
      min: min,
      max: max,
      hint: hint,
    ),
  );

  @override
  State<DurationPickerSheet> createState() => _DurationPickerSheetState();
}

class _DurationPickerSheetState extends State<DurationPickerSheet> {
  static const _wheelHeight = 168.0;
  static const _itemExtent = 44.0;
  static const _wheelWidth = 72.0;
  static const _maxHours = 23;
  static const _readoutTracking = -1.0;
  static const _wheelCurvature = 1.4;

  late Duration _value = _clamp(widget.initial);
  late final _hours = FixedExtentScrollController(initialItem: _value.inHours);
  late final _minutes = FixedExtentScrollController(
    initialItem: _value.inMinutes.remainder(Duration.minutesPerHour),
  );
  late final _seconds = FixedExtentScrollController(
    initialItem: _value.inSeconds.remainder(Duration.secondsPerMinute),
  );

  /// Wheels moved by a quick pick report back; those reports are not edits.
  bool _syncing = false;

  @override
  void dispose() {
    _hours.dispose();
    _minutes.dispose();
    _seconds.dispose();
    super.dispose();
  }

  Duration _clamp(Duration value) {
    if (value < widget.min) return widget.min;
    if (value > widget.max) return widget.max;
    return value;
  }

  void _fromWheels() {
    if (_syncing) return;
    final value = Duration(
      hours: _hours.selectedItem,
      minutes: _minutes.selectedItem,
      seconds: _seconds.selectedItem,
    );
    HapticFeedback.selectionClick();
    setState(() => _value = value);
  }

  Future<void> _pick(Duration value) async {
    setState(() => _value = value);
    _syncing = true;
    await Future.wait([
      _jump(_hours, value.inHours),
      _jump(_minutes, value.inMinutes.remainder(Duration.minutesPerHour)),
      _jump(_seconds, value.inSeconds.remainder(Duration.secondsPerMinute)),
    ]);
    _syncing = false;
  }

  static Future<void> _jump(FixedExtentScrollController controller, int item) =>
      controller.animateToItem(
        item,
        duration: kThemeAnimationDuration,
        curve: Curves.easeOutCubic,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final valid = _value >= widget.min && _value <= widget.max;
    final hint = widget.hint;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        Spacing.extraLarge,
        0,
        Spacing.extraLarge,
        Spacing.extraLarge,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: Spacing.extraSmall),
            Text(
              hint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: Spacing.large),
          Text(
            IntervalometerText.duration(_value),
            textAlign: TextAlign.center,
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: _readoutTracking,
              color: valid ? colors.onSurface : colors.error,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: Spacing.large),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: Spacing.small,
            runSpacing: Spacing.small,
            children: [
              for (final pick in widget.quickPicks)
                ChoiceChip(
                  label: Text(IntervalometerText.duration(pick)),
                  selected: pick == _value,
                  onSelected: (_) => _pick(pick),
                ),
            ],
          ),
          const SizedBox(height: Spacing.large),
          SizedBox(
            height: _wheelHeight,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Wheel(
                  controller: _hours,
                  count: _maxHours + 1,
                  unit: 'h',
                  onChanged: _fromWheels,
                ),
                _Wheel(
                  controller: _minutes,
                  count: Duration.minutesPerHour,
                  unit: 'min',
                  onChanged: _fromWheels,
                ),
                _Wheel(
                  controller: _seconds,
                  count: Duration.secondsPerMinute,
                  unit: 's',
                  onChanged: _fromWheels,
                ),
              ],
            ),
          ),
          const SizedBox(height: Spacing.large),
          FilledButton(
            onPressed: valid ? () => Navigator.of(context).pop(_value) : null,
            child: const Text(DurationPickerSheet.doneLabel),
          ),
        ],
      ),
    );
  }
}

class _Wheel extends StatelessWidget {
  const _Wheel({
    required this.controller,
    required this.count,
    required this.unit,
    required this.onChanged,
  });

  final FixedExtentScrollController controller;
  final int count;
  final String unit;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: _DurationPickerSheetState._wheelWidth,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            height: _DurationPickerSheetState._itemExtent,
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(Spacing.medium),
            ),
          ),
          ListWheelScrollView.useDelegate(
            controller: controller,
            itemExtent: _DurationPickerSheetState._itemExtent,
            physics: const FixedExtentScrollPhysics(),
            diameterRatio: _DurationPickerSheetState._wheelCurvature,
            onSelectedItemChanged: (_) => onChanged(),
            childDelegate: ListWheelChildBuilderDelegate(
              childCount: count,
              builder: (context, index) => Center(
                child: Text(
                  '$index $unit',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
