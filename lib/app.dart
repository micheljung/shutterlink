import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'data/camera_host_resolver.dart';
import 'data/download_history.dart';
import 'data/identity_repository.dart';
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
import 'feature/settings/settings_cubit.dart';

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
}

class ShutterlinkApp extends StatelessWidget {
  const ShutterlinkApp({super.key, required this.dependencies});

  static const _seedColor = Colors.red;

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) => MultiRepositoryProvider(
    providers: [RepositoryProvider.value(value: dependencies.thumbnailCache)],
    child: MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => SettingsCubit(dependencies.settings)),
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
          ),
        ),
        BlocProvider(
          create: (_) => DownloadHistoryCubit(dependencies.downloadHistory),
        ),
      ],
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
  );
}

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) =>
      BlocConsumer<ConnectCubit, ConnectState>(
        listenWhen: (previous, current) =>
            previous is ConnectConnected && current is! ConnectConnected,
        listener: (context, _) =>
            Navigator.of(context).popUntil((route) => route.isFirst),
        buildWhen: (previous, current) =>
            (previous is ConnectConnected) != (current is ConnectConnected) ||
            (previous is ConnectConnected &&
                current is ConnectConnected &&
                previous.client != current.client),
        builder: (context, state) => switch (state) {
          ConnectConnected(:final client) => GalleryScreen(
            key: ObjectKey(client),
            client: client,
          ),
          _ => const ConnectScreen(),
        },
      );
}
