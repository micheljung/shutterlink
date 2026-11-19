import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/identity_repository.dart';
import '../../remote/demo_remote.dart';
import '../../remote/remote_bluetooth.dart';
import '../../remote/shutter_remote.dart';
import '../spacing.dart';
import 'intervalometer_cubit.dart';

/// Pairs a camera as this phone's Bluetooth remote: the camera is put into
/// pairing, picked from the cameras found, and confirmed on the camera.
class CameraPairingSheet extends StatefulWidget {
  const CameraPairingSheet({super.key});

  static const title = 'Pair a camera';
  static const searchingText = 'Looking for cameras in pairing mode…';
  static const demoLabel = 'Try without a camera';
  static const confirmTitle = 'Press OK on the camera';
  static const doneLabel = 'Done';
  static const retryLabel = 'Try again';
  static const locationOffText =
      'Switch on Location to find the camera. This Android version needs it '
      'for Bluetooth.';
  static const failedText =
      'The camera did not answer. Check that it still shows the pairing '
      'screen, then try again.';

  static const cameraSteps = [
    'On the camera, open MENU → Wireless settings → Bluetooth function '
        '(Communication functions → Bluetooth settings on newer models).',
    'Choose Remote, then Pairing. Some models call it "Connect to Wireless '
        'Remote".',
    'Pick the camera below. If the phone asks to pair, allow it.',
  ];

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => BlocProvider.value(
      value: context.read<IntervalometerCubit>(),
      child: const CameraPairingSheet(),
    ),
  );

  @override
  State<CameraPairingSheet> createState() => _CameraPairingSheetState();
}

enum _Step { access, searching, connecting, confirm }

class _CameraPairingSheetState extends State<CameraPairingSheet> {
  _Step _step = _Step.access;
  bool _denied = false;
  bool _failed = false;
  List<RemoteCamera> _found = const [];
  StreamSubscription<List<RemoteCamera>>? _scan;
  RemoteCamera? _camera;
  ShutterRemote? _remote;

  /// Handed to the cubit; kept connected after the sheet closes.
  bool _kept = false;

  @override
  void initState() {
    super.initState();
    unawaited(_requestAccess());
  }

  @override
  void dispose() {
    unawaited(_scan?.cancel());
    if (!_kept) unawaited(_remote?.disconnect());
    super.dispose();
  }

  Future<void> _requestAccess() async {
    final bluetooth = context.read<IntervalometerCubit>().bluetooth;
    final granted = await bluetooth.requestAccess();
    if (!mounted) return;
    setState(() => _denied = !granted);
    if (granted) _search(bluetooth);
  }

  void _search(RemoteBluetooth bluetooth) {
    unawaited(_scan?.cancel());
    setState(() {
      _step = _Step.searching;
      _found = const [];
    });
    _scan = bluetooth.scan().listen(
      (found) {
        if (mounted) setState(() => _found = found);
      },
      // Bluetooth went off; the status card says so.
      onError: (Object _) {},
    );
  }

  Future<void> _pick(RemoteBluetooth bluetooth, RemoteCamera camera) async {
    if (_step == _Step.connecting || _step == _Step.confirm) return;
    unawaited(_scan?.cancel());
    _scan = null;
    final remote = bluetooth.remoteFor(camera);
    setState(() {
      _step = _Step.connecting;
      _camera = camera;
      _remote = remote;
      _failed = false;
    });
    try {
      await remote.connect();
    } on RemoteException {
      if (!mounted) return;
      setState(() => _failed = true);
      _search(bluetooth);
      return;
    }
    if (!mounted) return;
    if (bluetooth is DemoRemoteBluetooth) {
      await _finish();
      return;
    }
    setState(() => _step = _Step.confirm);
  }

  Future<void> _finish() async {
    final camera = _camera;
    final remote = _remote;
    if (camera == null || remote == null || _kept) return;
    _kept = true;
    final navigator = Navigator.of(context);
    await context.read<IntervalometerCubit>().paired(camera, remote);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cubit = context.read<IntervalometerCubit>();
    final bluetoothState = context.select<IntervalometerCubit, BluetoothState>(
      (cubit) => cubit.state.bluetooth,
    );
    return BlocListener<IntervalometerCubit, IntervalometerState>(
      // Bluetooth switched on while looking: look again.
      listenWhen: (previous, current) =>
          previous.bluetooth != BluetoothState.ready &&
          current.bluetooth == BluetoothState.ready &&
          (_step == _Step.searching || _step == _Step.access),
      listener: (_, _) => unawaited(_requestAccess()),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          Spacing.extraLarge,
          0,
          Spacing.extraLarge,
          Spacing.extraLarge,
        ),
        child: AnimatedSize(
          duration: kThemeAnimationDuration,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _step == _Step.confirm
                    ? CameraPairingSheet.confirmTitle
                    : CameraPairingSheet.title,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: Spacing.large),
              ...switch (_step) {
                _Step.confirm => _confirm(context),
                _Step.connecting => [
                  _Progress(
                    text: 'Connecting to ${_camera?.name ?? 'camera'}…',
                  ),
                ],
                _ => [
                  if (_denied)
                    _Notice(
                      icon: Icons.bluetooth_disabled,
                      text:
                          'Shutterlink needs Bluetooth access to find the '
                          'camera.',
                      action: 'Open settings',
                      onAction: cubit.bluetooth.openSettings,
                    )
                  else if (bluetoothState == BluetoothState.locationOff)
                    const _Notice(
                      icon: Icons.location_off_outlined,
                      text: CameraPairingSheet.locationOffText,
                    )
                  else if (bluetoothState == BluetoothState.off)
                    const _Notice(
                      icon: Icons.bluetooth_disabled,
                      text: 'Switch on Bluetooth to find the camera.',
                    )
                  else if (bluetoothState == BluetoothState.unsupported)
                    const _Notice(
                      icon: Icons.bluetooth_disabled,
                      text: 'This phone has no Bluetooth Low Energy.',
                    ),
                  for (final (index, step)
                      in CameraPairingSheet.cameraSteps.indexed)
                    _CameraStep(number: index + 1, text: step),
                  const SizedBox(height: Spacing.medium),
                  if (_failed)
                    const _Notice(
                      icon: Icons.error_outline,
                      text: CameraPairingSheet.failedText,
                      error: true,
                    ),
                  if (_step == _Step.searching) ...[
                    for (final camera in _found)
                      _FoundCamera(
                        camera: camera,
                        onTap: () => _pick(cubit.bluetooth, camera),
                      ),
                    if (_found.isEmpty)
                      const _Progress(text: CameraPairingSheet.searchingText),
                  ],
                  const SizedBox(height: Spacing.small),
                  TextButton.icon(
                    icon: const Icon(Icons.science_outlined),
                    label: const Text(CameraPairingSheet.demoLabel),
                    onPressed: () =>
                        _pick(cubit.demoBluetooth, DemoRemoteBluetooth.camera),
                  ),
                ],
              },
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _confirm(BuildContext context) {
    final theme = Theme.of(context);
    return [
      Text(
        'The camera asks whether to pair with '
        '"${IdentityRepository.friendlyName}". Press OK (SET) on the camera, '
        'then tap Done.',
        style: theme.textTheme.bodyLarge,
      ),
      const SizedBox(height: Spacing.extraLarge),
      FilledButton(
        onPressed: _finish,
        child: const Text(CameraPairingSheet.doneLabel),
      ),
      const SizedBox(height: Spacing.small),
      TextButton(
        onPressed: () {
          unawaited(_remote?.disconnect());
          _remote = null;
          _search(context.read<IntervalometerCubit>().bluetooth);
        },
        child: const Text(CameraPairingSheet.retryLabel),
      ),
    ];
  }
}

class _CameraStep extends StatelessWidget {
  const _CameraStep({required this.number, required this.text});

  static const _badgeRadius = 13.0;

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.medium),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: _badgeRadius,
            backgroundColor: colors.primaryContainer,
            foregroundColor: colors.onPrimaryContainer,
            child: Text(
              '$number',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: Spacing.medium),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _FoundCamera extends StatelessWidget {
  const _FoundCamera({required this.camera, required this.onTap});

  final RemoteCamera camera;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card.filled(
      margin: const EdgeInsets.only(bottom: Spacing.small),
      color: colors.surfaceContainerHigh,
      child: ListTile(
        leading: const Icon(Icons.photo_camera_outlined),
        title: Text(camera.name),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.text});

  static const _size = 20.0;
  static const _stroke = 2.5;

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Spacing.medium),
    child: Row(
      children: [
        const SizedBox.square(
          dimension: _size,
          child: CircularProgressIndicator(strokeWidth: _stroke),
        ),
        const SizedBox(width: Spacing.medium),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
    this.error = false,
  });

  final IconData icon;
  final String text;
  final String? action;
  final Future<void> Function()? onAction;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = error ? colors.errorContainer : colors.tertiaryContainer;
    final foreground = error
        ? colors.onErrorContainer
        : colors.onTertiaryContainer;
    final action = this.action;
    final onAction = this.onAction;
    return Card.filled(
      margin: const EdgeInsets.only(bottom: Spacing.medium),
      color: background,
      child: ListTile(
        leading: Icon(icon, color: foreground),
        title: Text(text, style: TextStyle(color: foreground)),
        trailing: action == null || onAction == null
            ? null
            : TextButton(onPressed: onAction, child: Text(action)),
      ),
    );
  }
}
