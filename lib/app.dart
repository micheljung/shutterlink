import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'data/camera_host_resolver.dart';
import 'data/destination_repository.dart';
import 'data/download_history.dart';
import 'data/identity_repository.dart';
import 'data/live_service.dart';
import 'data/network_binder.dart';
import 'data/photo_saver.dart';
import 'data/settings_repository.dart';
import 'feature/connect/connect_cubit.dart';
import 'feature/connect/connect_screen.dart';
import 'feature/connect/connect_state.dart';
import 'feature/download/download_cubit.dart';
import 'feature/gallery/gallery_screen.dart';
import 'feature/gallery/thumbnail_cache.dart';
import 'feature/history/download_history_cubit.dart';
import 'feature/live/ingest_coordinator.dart';
import 'feature/live/live_ingestor.dart';
import 'feature/live/live_screen.dart';
import 'feature/live/live_transfer_cubit.dart';
import 'feature/sessions/sessions_cubit.dart';
import 'feature/sessions/sessions_dependencies.dart';
import 'feature/sessions/sessions_upload_cubit.dart';
import 'feature/settings/settings_cubit.dart';
import 'feature/settings/upload_settings_cubit.dart';
import 'feature/upload/upload_status_cubit.dart';
import 'upload/upload_queue.dart';

class AppDependencies {
  const AppDependencies({
    required this.settings,
    required this.identity,
    required this.hostResolver,
    required this.networkBinder,
    required this.photoSaver,
    required this.connector,
    required this.thumbnailCache,
    required this.downloadDirectory,
    required this.downloadHistory,
    required this.destinations,
    required this.uploadQueue,
    required this.ingestCoordinator,
    required this.liveService,
    required this.connectionTester,
    required this.sessions,
  });

  final SettingsRepository settings;
  final IdentityRepository identity;
  final CameraHostResolver hostResolver;
  final NetworkBinder networkBinder;
  final PhotoSaver photoSaver;
  final CameraConnector connector;
  final ThumbnailCache thumbnailCache;
  final Directory downloadDirectory;
  final DownloadHistoryRepository downloadHistory;
  final DestinationRepository destinations;

  /// Started by the caller.
  final UploadQueue uploadQueue;
  final IngestCoordinator ingestCoordinator;
  final LiveService liveService;
  final ConnectionTester connectionTester;
  final SessionsDependencies sessions;
}

class ShutterlinkApp extends StatelessWidget {
  const ShutterlinkApp({super.key, required this.dependencies});

  static const _seedColor = Colors.red;

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) => MultiRepositoryProvider(
    providers: [
      RepositoryProvider.value(value: dependencies.thumbnailCache),
      RepositoryProvider.value(value: dependencies.networkBinder),
      RepositoryProvider.value(value: dependencies.sessions),
    ],
    child: MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (_) => SettingsCubit(
            dependencies.settings,
            credentials: dependencies.sessions.credentials,
          )..init(),
        ),
        BlocProvider(
          create: (_) => ConnectCubit(
            connector: dependencies.connector,
            identity: dependencies.identity,
            hostResolver: dependencies.hostResolver,
            networkBinder: dependencies.networkBinder,
          ),
        ),
        BlocProvider(
          create: (_) => DownloadCubit(
            saver: dependencies.photoSaver,
            workDirectory: dependencies.downloadDirectory,
            history: dependencies.downloadHistory,
            coordinator: dependencies.ingestCoordinator,
            uploadQueue: dependencies.uploadQueue,
          ),
        ),
        BlocProvider(
          create: (_) => DownloadHistoryCubit(dependencies.downloadHistory),
        ),
        BlocProvider(
          create: (_) => UploadSettingsCubit(
            dependencies.destinations,
            tester: dependencies.connectionTester,
          ),
        ),
        BlocProvider(
          create: (_) => UploadStatusCubit(dependencies.uploadQueue),
        ),
        BlocProvider(
          lazy: false,
          create: (context) => LiveTransferCubit(
            connect: context.read<ConnectCubit>(),
            connector: dependencies.connector,
            identity: dependencies.identity,
            hostResolver: dependencies.hostResolver,
            networkBinder: dependencies.networkBinder,
            service: dependencies.liveService,
            queue: dependencies.uploadQueue,
            ingestorFactory: (client, baseline) => LiveIngestor(
              client: client,
              format: dependencies.settings.format,
              baseline: baseline,
              history: dependencies.downloadHistory,
              queue: dependencies.uploadQueue,
              coordinator: dependencies.ingestCoordinator,
            ),
          ),
        ),
        BlocProvider(
          create: (_) => SessionsCubit(
            dependencies.sessions.repository,
            clock: dependencies.sessions.clock,
          ),
        ),
        BlocProvider(create: (_) => SessionsUploadCubit(dependencies.sessions)),
      ],
      child: _SessionsUploads(
        child: MaterialApp(
          title: 'Shutterlink',
          theme: ThemeData(colorSchemeSeed: _seedColor),
          darkTheme: ThemeData(
            colorSchemeSeed: _seedColor,
            brightness: Brightness.dark,
          ),
          home: const _Home(),
        ),
      ),
    ),
  );
}

class _SessionsUploads extends StatefulWidget {
  const _SessionsUploads({required this.child});

  final Widget child;

  @override
  State<_SessionsUploads> createState() => _SessionsUploadsState();
}

class _SessionsUploadsState extends State<_SessionsUploads>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final enabled = context.read<SettingsCubit>().state.sessionsEnabled;
    if (enabled) {
      context.read<SessionsUploadCubit>().setEnabled(enabled: enabled);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        context.read<SettingsCubit>().state.sessionsEnabled) {
      context.read<SessionsUploadCubit>().resumed();
    }
  }

  @override
  Widget build(BuildContext context) =>
      BlocListener<SettingsCubit, SettingsState>(
        listenWhen: (previous, current) =>
            previous.sessionsEnabled != current.sessionsEnabled ||
            previous.sessionsServerUrl != current.sessionsServerUrl ||
            previous.sessionsConfigured != current.sessionsConfigured ||
            previous.sessionsTokenRevision != current.sessionsTokenRevision,
        listener: (context, state) => context
            .read<SessionsUploadCubit>()
            .setEnabled(enabled: state.sessionsEnabled),
        child: widget.child,
      );
}

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) =>
      BlocConsumer<ConnectCubit, ConnectState>(
        listenWhen: (previous, current) =>
            (previous is ConnectConnected || previous is ConnectLiveOwned) &&
            current.runtimeType != previous.runtimeType,
        listener: (context, _) =>
            Navigator.of(context).popUntil((route) => route.isFirst),
        buildWhen: (previous, current) =>
            (previous is ConnectConnected) != (current is ConnectConnected) ||
            (previous is ConnectLiveOwned) != (current is ConnectLiveOwned) ||
            (previous is ConnectConnected &&
                current is ConnectConnected &&
                previous.client != current.client),
        builder: (context, state) => switch (state) {
          ConnectConnected(:final client) => GalleryScreen(
            key: ObjectKey(client),
            client: client,
          ),
          ConnectLiveOwned() => const LiveScreen(),
          _ => const ConnectScreen(),
        },
      );
}
