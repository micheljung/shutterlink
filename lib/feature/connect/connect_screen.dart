import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/identity_repository.dart';
import '../../data/ssdp_discovery.dart';
import '../download/download_cubit.dart';
import '../download/download_state.dart';
import '../sessions/active_session_indicator.dart';
import '../sessions/sessions_screen.dart';
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

  static const _setupSteps = [
    'On the camera, open MENU → Wireless communication settings → '
        'Wi-Fi function.',
    'Choose Remote control (EOS Utility) → Add a device.',
    'Select Camera access point mode → Easy connection.',
    "On this phone, join the Wi-Fi network shown on the camera's screen.",
    'Come back here and tap Connect.',
    'The first time, confirm "${IdentityRepository.friendlyName}" on the '
        'camera when it asks to pair.',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shutterlink'),
        actions: [
          const SessionsAction(),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(SettingsScreen.route()),
          ),
        ],
      ),
      body: BlocBuilder<ConnectCubit, ConnectState>(
        builder: (context, state) => ListView(
          padding: const EdgeInsets.all(Spacing.large),
          children: [
            const ActiveSessionIndicator(),
            if (state is ConnectPairingRequired) const _PairingCard(),
            if (state is ConnectFailed) _ErrorCard(message: state.message),
            const _PausedDownloadNotice(),
            Text('Set up the camera', style: theme.textTheme.titleMedium),
            const SizedBox(height: Spacing.small),
            for (final (index, step) in _setupSteps.indexed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(child: Text('${index + 1}')),
                title: Text(step),
              ),
            const SizedBox(height: Spacing.large),
            if (widget.usbExperimental)
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.usb),
                title: Text(ConnectScreen.usbExperimentalLabel),
                subtitle: Text('Or connect the camera with a USB cable.'),
              ),
            if (state is ConnectConnecting)
              _ConnectingIndicator(cameraName: state.cameraName, usb: state.usb)
            else if (state is ConnectChooseCamera)
              _CameraChooser(cameras: state.cameras)
            else
              FilledButton.icon(
                icon: const Icon(Icons.wifi),
                label: const Text('Connect'),
                onPressed: context.read<ConnectCubit>().connect,
              ),
          ],
        ),
      ),
    );
  }
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.large),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Pair this phone on the camera',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: Spacing.small),
            const Text(
              'The camera does not know this phone yet. On the camera, go to '
              'Remote control (EOS Utility) and add a device, or select the '
              'saved connection and press OK at "Start pairing devices". '
              'Then tap Connect and confirm '
              '"${IdentityRepository.friendlyName}" on the camera.',
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
