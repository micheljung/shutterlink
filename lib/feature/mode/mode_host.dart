import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../ptpip/camera_client.dart';
import '../auto_upload/auto_upload_screen.dart';
import '../connect/connect_cubit.dart';
import '../connect/connect_state.dart';
import '../download/download_cubit.dart';
import '../gallery/gallery_screen.dart';
import '../qr_session/qr_session_screen.dart';
import 'attached_client.dart';
import 'mode_cubit.dart';
import 'mode_picker_screen.dart';
import 'operating_mode.dart';
import 'reconnecting_overlay.dart';

/// Shows the picker or the active mode for the connected camera. While the
/// camera reconnects, the mode stays mounted under an overlay but makes no
/// calls on the dead client; the next client is attached to it.
class ModeHost extends StatefulWidget {
  const ModeHost({super.key});

  @override
  State<ModeHost> createState() => _ModeHostState();
}

class _ModeHostState extends State<ModeHost> {
  /// The last client that connected; dead while reconnecting.
  CameraClient? _client;

  @override
  Widget build(BuildContext context) {
    final connection = context.watch<ConnectCubit>().state;
    final mode = context.watch<ModeCubit>().state;
    if (connection case ConnectConnected(:final client)) _client = client;
    final client = _client;
    final reconnecting = connection is ConnectReconnecting ? connection : null;
    return BlocListener<ConnectCubit, ConnectState>(
      listenWhen: (previous, current) =>
          current is ConnectConnected &&
          (previous is! ConnectConnected || previous.client != current.client),
      listener: (context, state) => _attach((state as ConnectConnected).client),
      child: AttachedClient(
        client: reconnecting == null ? client : null,
        child: Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              ignoring: reconnecting != null,
              child: client == null
                  ? const SizedBox.shrink()
                  : _screenFor(mode, client),
            ),
            if (reconnecting != null) ReconnectingOverlay(state: reconnecting),
          ],
        ),
      ),
    );
  }

  /// A new client keeps the mode going: Browse resumes a paused download.
  void _attach(CameraClient client) {
    if (context.read<ModeCubit>().state != OperatingMode.browse) return;
    unawaited(context.read<DownloadCubit>().resume(client));
  }

  static Widget _screenFor(OperatingMode? mode, CameraClient client) =>
      switch (mode) {
        null => const ModePickerScreen(),
        // Keyed by client: a reconnect lists the card again, since handles
        // may be renumbered per session.
        OperatingMode.browse => GalleryScreen(
          key: ObjectKey(client),
          client: client,
        ),
        OperatingMode.autoUpload => const AutoUploadScreen(),
        OperatingMode.qrSession => const QrSessionScreen(),
      };
}
