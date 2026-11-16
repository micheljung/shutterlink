import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../ptpip/camera_client.dart';
import '../auto_upload/auto_upload_screen.dart';
import '../connect/connect_cubit.dart';
import '../connect/connect_state.dart';
import '../download/download_cubit.dart';
import '../download/download_state.dart';
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

  /// The new client a download still running on the dead one resumes on,
  /// once it notices the drop and pauses.
  CameraClient? _resumeOn;

  @override
  Widget build(BuildContext context) {
    final connection = context.watch<ConnectCubit>().state;
    final mode = context.watch<ModeCubit>().state;
    if (connection case ConnectConnected(:final client)) _client = client;
    final client = _client;
    final reconnecting = connection is ConnectReconnecting ? connection : null;
    return MultiBlocListener(
      listeners: [
        BlocListener<ConnectCubit, ConnectState>(
          listenWhen: (previous, current) =>
              current is ConnectConnected &&
              (previous is! ConnectConnected ||
                  previous.client != current.client),
          listener: (context, state) =>
              _attach((state as ConnectConnected).client),
        ),
        BlocListener<DownloadCubit, DownloadState>(
          listenWhen: (previous, current) => previous.status != current.status,
          listener: (context, state) {
            if (state.status == DownloadStatus.paused) {
              _resumePaused();
            } else if (state.status != DownloadStatus.running) {
              _resumeOn = null;
            }
          },
        ),
      ],
      // A mode replaces the picker in place, so back leaves the mode
      // instead of popping the app's only route.
      child: PopScope(
        canPop: mode == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) context.read<ModeCubit>().leave();
        },
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
              if (reconnecting != null)
                ReconnectingOverlay(state: reconnecting),
            ],
          ),
        ),
      ),
    );
  }

  /// A new client keeps the mode going: Browse resumes a paused download.
  /// A download still running on the dead client resumes once it pauses.
  void _attach(CameraClient client) {
    final status = context.read<DownloadCubit>().state.status;
    _resumeOn =
        status == DownloadStatus.running || status == DownloadStatus.paused
        ? client
        : null;
    _resumePaused();
  }

  /// Resumes a paused download once on the client that came after it, while
  /// that client is still the connected one.
  void _resumePaused() {
    final client = _resumeOn;
    final download = context.read<DownloadCubit>();
    final connection = context.read<ConnectCubit>().state;
    if (client == null ||
        download.state.status != DownloadStatus.paused ||
        connection is! ConnectConnected ||
        connection.client != client) {
      return;
    }
    _resumeOn = null;
    if (context.read<ModeCubit>().state != OperatingMode.browse) return;
    unawaited(download.resume(client));
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
