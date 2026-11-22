import 'dart:async';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../ptp/canon/canon_constants.dart';
import '../../ptp/canon/canon_eos_profile.dart';
import '../../ptp/canon/canon_live_view.dart';
import '../../ptp/canon/canon_live_view_stats.dart';
import '../../ptp/ptp_camera_client.dart';
import '../../ptp/ptp_session.dart';
import '../../ptpip/camera_client.dart';
import '../connect/connect_cubit.dart';
import '../connect/connect_state.dart';
import '../spacing.dart';

/// Measures Canon live view on the connected camera; a debug tool, not
/// part of release builds.
class LiveViewProbeScreen extends StatelessWidget {
  const LiveViewProbeScreen({super.key});

  static const routeName = '/live-view-probe';

  static Route<void> route() => MaterialPageRoute(
    settings: const RouteSettings(name: routeName),
    builder: (_) => const LiveViewProbeScreen(),
  );

  @override
  Widget build(BuildContext context) => BlocBuilder<ConnectCubit, ConnectState>(
    builder: (context, state) => switch (state) {
      ConnectConnected(:final client, :final target) => LiveViewProbe(
        client: client,
        usb: target is UsbTarget,
      ),
      ConnectReconnecting(:final usb, :final notResponding) => LiveViewProbe(
        client: null,
        usb: usb,
        notResponding: notResponding,
      ),
      _ => const LiveViewProbe(client: null, usb: false),
    },
  );
}

/// Runs live view on [client] while mounted and owns its session's timing
/// tap. Stats survive a reconnect: the loop restarts on the next client.
class LiveViewProbe extends StatefulWidget {
  const LiveViewProbe({
    super.key,
    required this.client,
    required this.usb,
    this.notResponding = false,
    this.clock = const Clock(),
  });

  static const title = 'Live view probe';
  static const notCanonText =
      'The live view probe needs a Canon camera connected over PTP.';
  static const waitingText = 'Waiting for the camera…';
  static const notRespondingText = ConnectCubit.notRespondingMessage;
  static const copiedText = 'Stats copied';
  static const statsInterval = Duration(milliseconds: 500);

  /// Null while the camera reconnects.
  final CameraClient? client;
  final bool usb;

  /// The camera keeps not answering while it reconnects.
  final bool notResponding;
  final Clock clock;

  @override
  State<LiveViewProbe> createState() => _LiveViewProbeState();
}

class _LiveViewProbeState extends State<LiveViewProbe> {
  static const _outputs = [CanonEvfOutput.pc, CanonEvfOutput.tftAndPc];
  static const _overlayAlpha = 0.7;
  static const _overlayRadius = 12.0;

  late final _stats = LiveViewStats(clock: widget.clock);
  final _image = ValueNotifier<ui.Image?>(null);
  late final Timer _ticker;
  CanonLiveViewLoop? _loop;
  StreamSubscription<Uint8List>? _frames;
  PtpSession? _timedSession;
  Future<void> _settled = Future.value();
  int _output = CanonEvfOutput.pc;
  bool _wantRunning = true;
  bool _decoding = false;

  PtpCameraClient? get _canon => switch (widget.client) {
    final PtpCameraClient client
        when client.profileId == const CanonEosProfile().id =>
      client,
    _ => null,
  };

  LiveViewCounts get _running => _loop?.counts ?? noLiveViewCounts;

  String get _transport => widget.usb ? 'USB' : 'Wi-Fi';

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(LiveViewProbe.statsInterval, (_) {
      if (mounted) setState(() {});
    });
    _start();
  }

  @override
  void didUpdateWidget(LiveViewProbe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.client != oldWidget.client) {
      _settle(() async {
        await _stop();
        _own(_canon?.session);
        if (_wantRunning) _start();
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _ticker.cancel();
    unawaited(_stop());
    _own(null);
    _image.value?.dispose();
    _image.dispose();
    super.dispose();
  }

  /// Runs [step] after the previous one, so a loop's shutdown, which hands
  /// the viewfinder back to the camera, never lands after the next start.
  void _settle(Future<void> Function() step) {
    _settled = _settled.then((_) => mounted ? step() : null);
  }

  void _own(PtpSession? session) {
    if (session == _timedSession) return;
    _timedSession?.onTiming = null;
    _timedSession = session;
    session?.onTiming = _stats.onTiming;
  }

  void _start() {
    final client = _canon;
    if (client == null || _loop != null) return;
    _own(client.session);
    final loop = _loop = CanonLiveViewLoop(client.session, output: _output);
    _frames = loop.frames.listen(
      _onFrame,
      onError: _onError,
      onDone: () {
        _retire(loop);
        if (mounted) setState(() {});
      },
    );
    unawaited(loop.start().catchError(_onError));
  }

  Future<void> _stop() async {
    final loop = _loop;
    if (loop == null) return;
    _retire(loop);
    await _frames?.cancel();
    _frames = null;
    await loop.stop();
  }

  void _retire(CanonLiveViewLoop loop) {
    if (loop != _loop) return;
    _stats.retireLoop(loop.counts);
    _loop = null;
  }

  void _onFrame(Uint8List jpeg) {
    _stats.recordFrame(jpeg);
    if (_decoding) return;
    _decoding = true;
    unawaited(_decode(jpeg));
  }

  Future<void> _decode(Uint8List jpeg) async {
    try {
      final codec = await ui.instantiateImageCodec(jpeg);
      final ui.FrameInfo frame;
      try {
        frame = await codec.getNextFrame();
      } finally {
        codec.dispose();
      }
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      final previous = _image.value;
      _image.value = frame.image;
      previous?.dispose();
    } on Exception {
      return;
    } finally {
      _decoding = false;
    }
  }

  void _onError(Object error) => _stats.recordError(error);

  void _toggleRunning() {
    _wantRunning = _loop == null;
    _settle(() async {
      if (_wantRunning) {
        _start();
      } else {
        await _stop();
      }
      if (mounted) setState(() {});
    });
  }

  void _selectOutput(int output) {
    setState(() => _output = output);
    _settle(() async {
      if (_loop == null) return;
      await _stop();
      _start();
      if (mounted) setState(() {});
    });
  }

  void _resetStats() => setState(() => _stats.reset(_running));

  Future<void> _copyStats() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _statsText()));
    messenger.showSnackBar(
      const SnackBar(content: Text(LiveViewProbe.copiedText)),
    );
  }

  String _statsText() =>
      _stats.summarize(_running).toText(transport: _transport, output: _output);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final client = widget.client;
    return Scaffold(
      appBar: AppBar(
        title: const Text(LiveViewProbe.title),
        actions: [
          IconButton(
            tooltip: 'Copy stats',
            icon: const Icon(Icons.copy_outlined),
            onPressed: _copyStats,
          ),
          const SizedBox(width: Spacing.small),
        ],
      ),
      body: SafeArea(
        top: false,
        child: client != null && _canon == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.extraLarge),
                  child: Text(
                    LiveViewProbe.notCanonText,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _viewfinder(theme, waiting: client == null)),
                  _controls(),
                ],
              ),
      ),
    );
  }

  Widget _viewfinder(ThemeData theme, {required bool waiting}) {
    final colors = theme.colorScheme;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ValueListenableBuilder(
            valueListenable: _image,
            builder: (context, image, _) =>
                RawImage(image: image, fit: BoxFit.contain),
          ),
          if (waiting)
            Center(
              child: Text(
                widget.notResponding
                    ? LiveViewProbe.notRespondingText
                    : LiveViewProbe.waitingText,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white),
              ),
            ),
          Positioned(
            left: Spacing.medium,
            top: Spacing.medium,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface.withValues(alpha: _overlayAlpha),
                borderRadius: BorderRadius.circular(_overlayRadius),
              ),
              child: Padding(
                padding: const EdgeInsets.all(Spacing.medium),
                child: Text(
                  _statsText(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls() => Padding(
    padding: const EdgeInsets.all(Spacing.large),
    child: Wrap(
      spacing: Spacing.small,
      runSpacing: Spacing.small,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton(
          onPressed: _canon == null ? null : _toggleRunning,
          child: Text(_loop == null ? 'Start' : 'Stop'),
        ),
        SegmentedButton<int>(
          segments: [
            for (final output in _outputs)
              ButtonSegment(value: output, label: Text('EVF $output')),
          ],
          selected: {_output},
          onSelectionChanged: (selected) => _selectOutput(selected.single),
        ),
        OutlinedButton(onPressed: _resetStats, child: const Text('Reset')),
      ],
    ),
  );
}
