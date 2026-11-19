import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'brand/brand_theme.dart';
import 'data/camera_host_resolver.dart';
import 'data/destination_repository.dart';
import 'data/download_history.dart';
import 'data/identity_repository.dart';
import 'data/live_service.dart';
import 'data/network_binder.dart';
import 'data/photo_saver.dart';
import 'data/settings_repository.dart';
import 'demo/phone_camera.dart';
import 'feature/auto_upload/auto_upload_cubit.dart';
import 'feature/connect/connect_cubit.dart';
import 'feature/connect/connect_screen.dart';
import 'feature/connect/connect_state.dart';
import 'feature/download/download_cubit.dart';
import 'feature/gallery/thumbnail_cache.dart';
import 'feature/history/download_history_cubit.dart';
import 'feature/live/ingest_coordinator.dart';
import 'feature/live/live_ingestor.dart';
import 'feature/live_share/live_share_cubit.dart';
import 'feature/mode/mode_cubit.dart';
import 'feature/mode/mode_host.dart';
import 'feature/onboarding/onboarding_screen.dart';
import 'feature/sessions/sessions_cubit.dart';
import 'feature/sessions/sessions_dependencies.dart';
import 'feature/sessions/sessions_upload_cubit.dart';
import 'feature/settings/sessions_setup_screen.dart';
import 'feature/settings/settings_cubit.dart';
import 'feature/settings/upload_settings_cubit.dart';
import 'feature/settings/upload_setup_screen.dart';
import 'feature/upload/upload_status_cubit.dart';
import 'upload/upload_queue.dart';
import 'usb/usb_camera_platform.dart';

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
    required this.claimsUsbVendor,
    this.usb = const NoUsbCameraPlatform(),
    this.phoneCamera = const PhoneCamera(),
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

  /// Built from the profile registry in main, so features never import it.
  final UsbVendorClaim claimsUsbVendor;
  final UsbCameraPlatform usb;

  /// Shoots for the demo camera.
  final PhoneCamera phoneCamera;
}

class ShutterlinkApp extends StatelessWidget {
  const ShutterlinkApp({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) => MultiRepositoryProvider(
    providers: [
      RepositoryProvider.value(value: dependencies.thumbnailCache),
      RepositoryProvider.value(value: dependencies.networkBinder),
      RepositoryProvider.value(value: dependencies.sessions),
      RepositoryProvider.value(value: dependencies.phoneCamera),
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
            claimsUsbVendor: dependencies.claimsUsbVendor,
            usbWatcher: dependencies.usb.watcher,
          ),
        ),
        BlocProvider(create: (_) => ModeCubit()),
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
          create: (context) => AutoUploadCubit(
            connect: context.read<ConnectCubit>(),
            modes: context.read<ModeCubit>(),
            service: dependencies.liveService,
            queue: dependencies.uploadQueue,
            format: () => dependencies.settings.format,
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
          lazy: false,
          create: (context) => LiveShareCubit(
            connect: context.read<ConnectCubit>(),
            modes: context.read<ModeCubit>(),
            service: dependencies.liveService,
            sessions: dependencies.sessions,
            clock: dependencies.sessions.clock,
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
          theme: BrandTheme.light(),
          darkTheme: BrandTheme.dark(),
          home: _Home(usbExperimental: dependencies.usb.isExperimental),
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
    final configured = context.read<SettingsCubit>().state.sessionsConfigured;
    if (configured) {
      context.read<SessionsUploadCubit>().setEnabled(enabled: configured);
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
        context.read<SettingsCubit>().state.sessionsConfigured) {
      context.read<SessionsUploadCubit>().resumed();
    }
  }

  @override
  Widget build(BuildContext context) =>
      BlocListener<SettingsCubit, SettingsState>(
        listenWhen: (previous, current) =>
            previous.sessionsServerUrl != current.sessionsServerUrl ||
            previous.sessionsConfigured != current.sessionsConfigured ||
            previous.sessionsTokenRevision != current.sessionsTokenRevision,
        listener: (context, state) => context
            .read<SessionsUploadCubit>()
            .setEnabled(enabled: state.sessionsConfigured),
        child: widget.child,
      );
}

class _Home extends StatefulWidget {
  const _Home({required this.usbExperimental});

  final bool usbExperimental;

  @override
  State<_Home> createState() => _HomeState();
}

enum _HomeScreen { connect, modes }

class _HomeState extends State<_Home> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    final connect = context.read<ConnectCubit>();
    _lifecycle = AppLifecycleListener(
      onPause: connect.appPaused,
      onResume: connect.appResumed,
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  static _HomeScreen _screenOf(ConnectState state) => switch (state) {
    ConnectConnected() || ConnectReconnecting() => _HomeScreen.modes,
    _ => _HomeScreen.connect,
  };

  /// No camera any more: back to the connect screen, and a fresh connect
  /// shows the picker again.
  static bool _lost(ConnectState previous, ConnectState current) =>
      _screenOf(previous) != _HomeScreen.connect &&
      switch (current) {
        ConnectIdle() || ConnectFailed() || ConnectPairingRequired() => true,
        _ => false,
      };

  /// The camera dropped. Pushed screens go, since they would cover the
  /// overlay and may hold the dead client. A setup screen stays, so typed
  /// credentials survive a brief drop.
  static const _survivesDrop = {
    UploadSetupScreen.routeName,
    SessionsSetupScreen.routeName,
  };

  static bool _dropped(ConnectState previous, ConnectState current) =>
      current is ConnectReconnecting && previous is! ConnectReconnecting;

  @override
  Widget build(BuildContext context) =>
      BlocConsumer<ConnectCubit, ConnectState>(
        listenWhen: (previous, current) =>
            _lost(previous, current) || _dropped(previous, current),
        listener: (context, state) {
          final dropped = state is ConnectReconnecting;
          Navigator.of(context).popUntil(
            (route) =>
                route.isFirst ||
                (dropped && _survivesDrop.contains(route.settings.name)),
          );
          if (state is! ConnectReconnecting) {
            context.read<ModeCubit>().connectionLost();
          }
        },
        buildWhen: (previous, current) =>
            _screenOf(previous) != _screenOf(current),
        builder: (context, state) => switch (_screenOf(state)) {
          _HomeScreen.modes => const ModeHost(),
          _HomeScreen.connect =>
            BlocSelector<SettingsCubit, SettingsState, bool>(
              selector: (state) => state.onboardingSeen,
              builder: (context, seen) => seen
                  ? ConnectScreen(usbExperimental: widget.usbExperimental)
                  : OnboardingScreen(
                      onDone: context.read<SettingsCubit>().markOnboardingSeen,
                    ),
            ),
        },
      );
}
