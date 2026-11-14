import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../ptpip/camera_client.dart';
import '../download/download_cubit.dart';
import '../gallery/gallery_cubit.dart';
import '../gallery/gallery_state.dart';
import '../settings/settings_cubit.dart';
import 'clock_sync_cubit.dart';
import 'session_collector.dart';
import 'sessions_dependencies.dart';

class SessionsConnection extends StatelessWidget {
  const SessionsConnection({
    super.key,
    required this.client,
    required this.child,
  });

  final CameraClient client;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final configured = context.select<SettingsCubit, bool>(
      (cubit) => cubit.state.sessionsConfigured,
    );
    if (!configured) return child;
    return BlocProvider(
      create: (context) =>
          context.read<SessionsDependencies>().createClockSync(client)..start(),
      child: _Collector(client: client, child: child),
    );
  }
}

class _Collector extends StatefulWidget {
  const _Collector({required this.client, required this.child});

  final CameraClient client;
  final Widget child;

  @override
  State<_Collector> createState() => _CollectorState();
}

class _CollectorState extends State<_Collector> {
  late final SessionCollector _collector;

  @override
  void initState() {
    super.initState();
    final downloads = context.read<DownloadCubit>();
    final gallery = context.read<GalleryCubit>();
    _collector = context.read<SessionsDependencies>().createCollector(
      widget.client,
      context.read<ClockSyncCubit>(),
      isBusy: () => downloads.state.isActive || gallery.state.deleting,
    )..start();
    _onGallery(gallery.state);
  }

  @override
  void dispose() {
    _collector.dispose();
    super.dispose();
  }

  void _onGallery(GalleryState state) {
    if (state.status == GalleryStatus.loaded) {
      _collector.onGroups(state.groups);
    }
  }

  @override
  Widget build(BuildContext context) =>
      BlocListener<GalleryCubit, GalleryState>(
        listenWhen: (previous, current) =>
            current.status == GalleryStatus.loaded &&
            previous.groups != current.groups,
        listener: (_, state) => _onGallery(state),
        child: widget.child,
      );
}
