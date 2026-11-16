import 'package:flutter/material.dart';

import '../../brand/brand_intro.dart';
import '../../brand/brand_theme.dart';
import '../spacing.dart';
import 'setup_steps.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});

  static const skipLabel = 'Skip';
  static const nextLabel = 'Next';
  static const doneLabel = 'Get started';
  static const phoneTitle = 'Connect this phone';
  static const pageCount = 3;
  static const cameraStepCount = 3;

  static String progressText(int page) => '${page + 1} of $pageCount';

  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _pageDuration = Duration(milliseconds: 300);
  static const _pageCurve = Curves.easeOutCubic;
  static const _dotSize = 8.0;
  static const _activeDotWidth = 24.0;
  static const _buttonPadding = 28.0;

  final _controller = PageController();
  int _page = 0;

  bool get _last => _page == OnboardingScreen.pageCount - 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_last) {
      widget.onDone();
      return;
    }
    _controller.nextPage(duration: _pageDuration, curve: _pageCurve);
  }

  void _previous() =>
      _controller.previousPage(duration: _pageDuration, curve: _pageCurve);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return PopScope(
      canPop: _page == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _previous();
      },
      child: Scaffold(
        appBar: AppBar(
          forceMaterialTransparency: true,
          automaticallyImplyLeading: false,
          titleSpacing: Spacing.extraLarge,
          title: Text(
            OnboardingScreen.progressText(_page),
            style: theme.textTheme.labelLarge?.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          actions: [
            if (!_last)
              TextButton(
                onPressed: widget.onDone,
                child: const Text(OnboardingScreen.skipLabel),
              ),
            const SizedBox(width: Spacing.medium),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: PageView(
                  controller: _controller,
                  onPageChanged: (page) => setState(() => _page = page),
                  children: const [_WelcomePage(), _CameraPage(), _PhonePage()],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.extraLarge,
                  Spacing.small,
                  Spacing.extraLarge,
                  Spacing.extraLarge,
                ),
                child: Row(
                  children: [
                    for (
                      var page = 0;
                      page < OnboardingScreen.pageCount;
                      page++
                    )
                      AnimatedContainer(
                        duration: _pageDuration,
                        width: page == _page ? _activeDotWidth : _dotSize,
                        height: _dotSize,
                        margin: const EdgeInsets.only(right: Spacing.small),
                        decoration: BoxDecoration(
                          color: page == _page
                              ? colors.primary
                              : colors.outlineVariant,
                          borderRadius: BorderRadius.circular(_dotSize / 2),
                        ),
                      ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: _buttonPadding,
                            ),
                          ),
                          iconAlignment: IconAlignment.end,
                          icon: Icon(_last ? Icons.check : Icons.arrow_forward),
                          label: Text(
                            _last
                                ? OnboardingScreen.doneLabel
                                : OnboardingScreen.nextLabel,
                          ),
                          onPressed: _next,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context) =>
      const BrandIntro(padding: EdgeInsets.all(Spacing.extraLarge));
}

class _CameraPage extends StatelessWidget {
  const _CameraPage();

  static const _screenRadius = 22.0;
  static const _screenBorderWidth = 2.0;

  @override
  Widget build(BuildContext context) => _StepsPage(
    title: SetupSteps.title,
    first: 0,
    count: OnboardingScreen.cameraStepCount,
    illustration: Container(
      padding: const EdgeInsets.all(Spacing.large),
      decoration: BoxDecoration(
        color: BrandColors.cameraScreen,
        borderRadius: BorderRadius.circular(_screenRadius),
        border: Border.all(
          color: BrandColors.cameraScreenBorder,
          width: _screenBorderWidth,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, item) in SetupSteps.cameraMenu.indexed)
            _MenuRow(
              text: item,
              depth: index,
              selected: index == SetupSteps.cameraMenu.length - 1,
            ),
        ],
      ),
    ),
  );
}

class _PhonePage extends StatelessWidget {
  const _PhonePage();

  static const _iconSize = 96.0;

  @override
  Widget build(BuildContext context) => _StepsPage(
    title: OnboardingScreen.phoneTitle,
    first: OnboardingScreen.cameraStepCount,
    count: SetupSteps.all.length - OnboardingScreen.cameraStepCount,
    illustration: Icon(
      Icons.wifi_tethering,
      size: _iconSize,
      color: Theme.of(context).colorScheme.primary,
    ),
  );
}

class _StepsPage extends StatelessWidget {
  const _StepsPage({
    required this.title,
    required this.first,
    required this.count,
    required this.illustration,
  });

  final String title;
  final int first;
  final int count;
  final Widget illustration;

  static const _titleSpacing = -0.8;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(
      Spacing.extraLarge,
      Spacing.medium,
      Spacing.extraLarge,
      Spacing.large,
    ),
    children: [
      illustration,
      const SizedBox(height: Spacing.extraLarge),
      Text(
        title,
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: _titleSpacing,
        ),
      ),
      const SizedBox(height: Spacing.large),
      SetupStepList(first: first, count: count),
    ],
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.text,
    required this.depth,
    required this.selected,
  });

  final String text;
  final int depth;
  final bool selected;

  static const _indent = 10.0;
  static const _radius = 8.0;
  static const _borderWidth = 1.5;
  static const _iconSize = 16.0;
  static const _fontSize = 14.0;
  static const _selectedFill = 0.16;
  static const _verticalPadding = 7.0;

  @override
  Widget build(BuildContext context) {
    const accent = BrandColors.cameraScreenAccent;
    return Container(
      margin: EdgeInsets.only(
        left: depth * _indent,
        top: depth == 0 ? 0 : Spacing.small,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: _indent,
        vertical: _verticalPadding,
      ),
      decoration: BoxDecoration(
        color: selected
            ? accent.withValues(alpha: _selectedFill)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(_radius),
        border: Border.all(
          color: selected ? accent : Colors.transparent,
          width: _borderWidth,
        ),
      ),
      child: Row(
        children: [
          Icon(
            depth == 0 ? Icons.menu : Icons.subdirectory_arrow_right,
            size: _iconSize,
            color: selected ? accent : BrandColors.cameraScreenDim,
          ),
          const SizedBox(width: Spacing.small),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _fontSize,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? accent : BrandColors.cameraScreenText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
