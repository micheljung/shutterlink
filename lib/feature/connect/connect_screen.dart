import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../brand/brand_intro.dart';
import '../../data/identity_repository.dart';
import '../../data/ssdp_discovery.dart';
import '../download/download_cubit.dart';
import '../download/download_state.dart';
import '../intervalometer/intervalometer_entry_card.dart';
import '../onboarding/setup_steps.dart';
import '../sessions/active_session_indicator.dart';
import '../settings/settings_screen.dart';
import '../spacing.dart';
import 'connect_cubit.dart';
import 'connect_state.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, this.usbExperimental = false});

  /// Owner of the USB watch while this screen shows.
  static const usbWatchOwner = 'connect';
  static const usbConnectingText = 'Connecting over USB…';
  static const usbExperimentalLabel = 'USB (experimental)';
  static const connectLabel = 'Connect';
  static const setupGuideLabel = 'Setup guide';
  static const demoLabel = 'Try without a camera';

  /// Leaves the pinned area at most this share of the screen, so the
  /// chooser scrolls instead of hiding the content above it.
  static const _chooserHeightFraction = 0.5;

  /// Labels USB as experimental, where it is not verified on hardware.
  final bool usbExperimental;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final _usbWatcher = context.read<ConnectCubit>().usbWatcher;

  /// In the background the cable needs no watching, so the watch can end.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _usbWatcher.start(ConnectScreen.usbWatchOwner);
    _lifecycle = AppLifecycleListener(
      onPause: () => _usbWatcher.stop(ConnectScreen.usbWatchOwner),
      onResume: () => _usbWatcher.start(ConnectScreen.usbWatchOwner),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _usbWatcher.stop(ConnectScreen.usbWatchOwner);
    super.dispose();
  }

  Future<void> _showSetupGuide() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => const _SetupGuide(),
  );

  static bool _showsDemo(ConnectState state) =>
      state is! ConnectConnecting && state is! ConnectChooseCamera;

  @override
  Widget build(BuildContext context) => Scaffold(
    extendBodyBehindAppBar: true,
    appBar: AppBar(
      forceMaterialTransparency: true,
      actions: [
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(context).push(SettingsScreen.route()),
        ),
        const SizedBox(width: Spacing.small),
      ],
    ),
    body: BlocBuilder<ConnectCubit, ConnectState>(
      builder: (context, state) => LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _Intro(
                state: state,
                usbExperimental: widget.usbExperimental,
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.extraLarge,
                  Spacing.small,
                  Spacing.extraLarge,
                  Spacing.medium,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (state is ConnectConnecting)
                      _ConnectingIndicator(
                        cameraName: state.cameraName,
                        usb: state.usb,
                      )
                    else if (state is ConnectChooseCamera)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight:
                              constraints.maxHeight *
                              ConnectScreen._chooserHeightFraction,
                        ),
                        child: SingleChildScrollView(
                          child: _CameraChooser(cameras: state.cameras),
                        ),
                      )
                    else
                      FilledButton.icon(
                        icon: const Icon(Icons.wifi),
                        label: const Text(ConnectScreen.connectLabel),
                        onPressed: context.read<ConnectCubit>().connect,
                      ),
                    const SizedBox(height: Spacing.small),
                    OverflowBar(
                      alignment: _showsDemo(state)
                          ? MainAxisAlignment.spaceBetween
                          : MainAxisAlignment.end,
                      overflowAlignment: OverflowBarAlignment.center,
                      children: [
                        if (_showsDemo(state))
                          TextButton(
                            onPressed: context.read<ConnectCubit>().connectDemo,
                            child: const Text(ConnectScreen.demoLabel),
                          ),
                        TextButton.icon(
                          icon: const Icon(Icons.auto_stories_outlined),
                          label: const Text(ConnectScreen.setupGuideLabel),
                          onPressed: _showSetupGuide,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Intro extends StatelessWidget {
  const _Intro({required this.state, required this.usbExperimental});

  final ConnectState state;
  final bool usbExperimental;

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    return BrandIntro(
      compact: state is ConnectPairingRequired || state is ConnectFailed,
      children: [
        const ActiveSessionIndicator(),
        if (state is ConnectPairingRequired) const _PairingCard(),
        if (state is ConnectFailed) _ErrorCard(message: state.message),
        const _PausedDownloadNotice(),
        if (state is! ConnectConnecting && state is! ConnectChooseCamera)
          const IntervalometerEntryCard(),
        if (usbExperimental)
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.usb),
            title: Text(ConnectScreen.usbExperimentalLabel),
            subtitle: Text('Or connect the camera with a USB cable.'),
          ),
      ],
    );
  }
}

class _SetupGuide extends StatelessWidget {
  const _SetupGuide();

  @override
  Widget build(BuildContext context) => ListView(
    shrinkWrap: true,
    padding: const EdgeInsets.fromLTRB(
      Spacing.extraLarge,
      0,
      Spacing.extraLarge,
      Spacing.extraLarge,
    ),
    children: [
      Text(
        SetupSteps.title,
        style: Theme.of(context).textTheme.headlineSmall
            ?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: Spacing.large),
      SetupStepList(first: 0, count: SetupSteps.all.length),
    ],
  );
}

class _ConnectingIndicator extends StatelessWidget {
  const _ConnectingIndicator({this.cameraName, this.usb = false});

  final String? cameraName;
  final bool usb;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const CircularProgressIndicator(),
      const SizedBox(height: Spacing.medium),
      Text(
        usb
            ? ConnectScreen.usbConnectingText
            : '${cameraName == null ? 'Connecting…' : 'Connecting to $cameraName…'} '
                  'If the camera asks to pair, confirm '
                  '"${IdentityRepository.friendlyName}" on the camera.',
        textAlign: TextAlign.center,
      ),
    ],
  );
}

class _CameraChooser extends StatelessWidget {
  const _CameraChooser({required this.cameras});

  final List<DiscoveredCamera> cameras;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ConnectCubit>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Choose a camera', style: Theme.of(context).textTheme.titleMedium),
        for (final camera in cameras)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(camera.name),
            subtitle: Text(camera.host),
            onTap: () => cubit.chooseCamera(camera),
          ),
        TextButton(onPressed: cubit.cancelChoice, child: const Text('Cancel')),
      ],
    );
  }
}

class _PairingCard extends StatelessWidget {
  const _PairingCard();

  static const _radius = 20.0;
  static const _bodyLineHeight = 1.4;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: Spacing.extraSmall),
      color: colors.tertiaryContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.large),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.phonelink_lock_outlined,
              color: colors.onTertiaryContainer,
            ),
            const SizedBox(width: Spacing.medium),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pair this phone on the camera',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colors.onTertiaryContainer,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: Spacing.extraSmall),
                  Text(
                    'The camera does not know this phone yet. On the camera, '
                    'go to Remote control (EOS Utility) and add a device, or '
                    'select the saved connection and press OK at "Start '
                    'pairing devices". Then tap Connect and confirm '
                    '"${IdentityRepository.friendlyName}" on the camera.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onTertiaryContainer,
                      height: _bodyLineHeight,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: colors.errorContainer,
      child: ListTile(
        leading: Icon(Icons.error_outline, color: colors.onErrorContainer),
        title: Text(message, style: TextStyle(color: colors.onErrorContainer)),
      ),
    );
  }
}

class _PausedDownloadNotice extends StatelessWidget {
  const _PausedDownloadNotice();

  @override
  Widget build(BuildContext context) {
    final paused = context.select<DownloadCubit, bool>(
      (cubit) => cubit.state.status == DownloadStatus.paused,
    );
    if (!paused) return const SizedBox.shrink();
    return const Card(
      child: ListTile(
        leading: Icon(Icons.pause_circle_outline),
        title: Text('Download paused. Reconnect to resume it.'),
      ),
    );
  }
}
