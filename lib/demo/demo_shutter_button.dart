import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../ptpip/camera_client.dart';
import 'demo_camera_client.dart';
import 'phone_camera.dart';

/// Takes a photo with the phone's camera and puts it on the demo camera's
/// card as a new shot. Shows only when [client] is the demo camera.
class DemoShutterButton extends StatefulWidget {
  const DemoShutterButton({super.key, required this.client, this.onShot});

  static const label = 'Take photo';
  static const failedText = 'Could not take a photo.';

  /// Room a list leaves at its end so the button covers none of it.
  static const clearance = 96.0;

  static bool showsFor(CameraClient? client) => client is DemoCameraClient;

  final CameraClient? client;

  /// Called once a shot is on the card.
  final VoidCallback? onShot;

  @override
  State<DemoShutterButton> createState() => _DemoShutterButtonState();
}

class _DemoShutterButtonState extends State<DemoShutterButton> {
  /// The camera is open; a second one would fail.
  bool _taking = false;

  Future<void> _take(DemoCameraClient client) async {
    if (_taking) return;
    final messenger = ScaffoldMessenger.of(context);
    final camera = context.read<PhoneCamera>();
    setState(() => _taking = true);
    try {
      final shot = await camera.takePhoto();
      if (shot == null) return;
      await client.addShot(shot);
      if (mounted) widget.onShot?.call();
    } on PlatformException {
      _failed(messenger);
    } on FileSystemException {
      _failed(messenger);
    } finally {
      if (mounted) setState(() => _taking = false);
    }
  }

  static void _failed(ScaffoldMessengerState messenger) =>
      messenger.showSnackBar(
        const SnackBar(content: Text(DemoShutterButton.failedText)),
      );

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    if (client is! DemoCameraClient) return const SizedBox.shrink();
    return FloatingActionButton.extended(
      icon: const Icon(Icons.photo_camera_outlined),
      label: const Text(DemoShutterButton.label),
      onPressed: _taking ? null : () => _take(client),
    );
  }
}
