import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/camera_host_resolver.dart';
import '../../data/network_binder.dart';
import '../../data/settings_repository.dart';
import '../../data/upload_tunnel.dart';
import '../history/download_history_cubit.dart';
import '../spacing.dart';
import 'settings_cubit.dart';
import 'upload_settings_section.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const SettingsScreen());

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _hostController = TextEditingController(
    text: context.read<SettingsCubit>().state.hostOverride,
  );

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SettingsCubit>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(Spacing.large),
        children: [
          Text('Download format', style: theme.textTheme.titleMedium),
          const SizedBox(height: Spacing.small),
          BlocBuilder<SettingsCubit, SettingsState>(
            buildWhen: (previous, current) => previous.format != current.format,
            builder: (context, state) => SegmentedButton<DownloadFormat>(
              segments: const [
                ButtonSegment(value: DownloadFormat.jpeg, label: Text('JPEG')),
                ButtonSegment(value: DownloadFormat.raw, label: Text('RAW')),
                ButtonSegment(value: DownloadFormat.both, label: Text('Both')),
              ],
              selected: {state.format},
              onSelectionChanged: (selection) =>
                  cubit.setFormat(selection.single),
            ),
          ),
          const SizedBox(height: Spacing.small),
          Text(
            'Photos without the chosen format are skipped.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Spacing.extraLarge),
          Text('Preview quality', style: theme.textTheme.titleMedium),
          const SizedBox(height: Spacing.small),
          BlocBuilder<SettingsCubit, SettingsState>(
            buildWhen: (previous, current) =>
                previous.previewQuality != current.previewQuality,
            builder: (context, state) => SegmentedButton<PreviewQuality>(
              segments: const [
                ButtonSegment(
                  value: PreviewQuality.thumbnail,
                  label: Text('Thumbnail'),
                ),
                ButtonSegment(
                  value: PreviewQuality.full,
                  label: Text('Full resolution'),
                ),
              ],
              selected: {state.previewQuality},
              onSelectionChanged: (selection) =>
                  cubit.setPreviewQuality(selection.single),
            ),
          ),
          const SizedBox(height: Spacing.extraLarge),
          Text('Camera address', style: theme.textTheme.titleMedium),
          const SizedBox(height: Spacing.small),
          TextField(
            controller: _hostController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'IP address',
              hintText:
                  'Automatic (Wi-Fi gateway, '
                  'else ${CameraHostResolver.fallbackHost})',
            ),
            onChanged: cubit.setHostOverride,
          ),
          const UploadSettingsSection(),
          const SizedBox(height: Spacing.extraLarge),
          Text('Download history', style: theme.textTheme.titleMedium),
          const SizedBox(height: Spacing.small),
          Text(
            'Downloaded photos are marked and skipped on later downloads.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Spacing.small),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () => _confirmClearHistory(context),
              child: const Text('Clear download history'),
            ),
          ),
          if (kDebugMode) ...[
            const SizedBox(height: Spacing.extraLarge),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => _runTunnelTest(context),
                child: const Text('Tunnel test'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmClearHistory(BuildContext context) async {
    final history = context.read<DownloadHistoryCubit>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear download history?'),
        content: const Text('All photos will download again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await history.clear();
  }

  Future<void> _runTunnelTest(BuildContext context) async {
    const host = 'example.com';
    const port = 443;
    final stopwatch = Stopwatch()..start();
    String report;
    try {
      final gateway = await const PlatformNetworkBinder().bindToWifi();
      final tunnel = await const UploadTunnel().connect(
        host,
        port,
        allowMetered: true,
      );
      final tunnelled = stopwatch.elapsedMilliseconds;
      final socket = await SecureSocket.secure(tunnel.socket, host: host);
      final secured = stopwatch.elapsedMilliseconds;
      socket.write(
        'GET / HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n',
      );
      final statusLine = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      socket.destroy();
      report =
          '$statusLine\n'
          'network: ${tunnel.networkType}\n'
          'bound gateway: $gateway\n'
          'tunnel: $tunnelled ms, TLS: $secured ms, '
          'total: ${stopwatch.elapsedMilliseconds} ms';
    } catch (e) {
      report = 'Failed after ${stopwatch.elapsedMilliseconds} ms:\n$e';
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tunnel test'),
        content: SelectableText(report),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
