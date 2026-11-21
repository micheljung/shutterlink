import 'package:args/args.dart';

import '../ptp/camera_profile.dart';
import '../ptp/canon/canon_constants.dart';

const exitOk = 0;
const exitUsage = 64;
const exitUnavailable = 69;
const exitCameraBusy = 75;
const exitCameraRefused = 76;
const exitPairingRequired = 77;

const _hexPrefix = '0x';
const _hexRadix = 16;
const _decimalRadix = 10;
const _pairParts = 2;

/// The EOS R's full sensor, as AF coordinates without `--af-space`.
const defaultAfSpace = (width: 6720, height: 4480);
const defaultReleaseTimeout = Duration(seconds: 10);
const defaultSetTrials = 3;
const defaultShots = 1;
const defaultReleaseParams = (
  half: CanonRemoteRelease.halfPress,
  full: CanonRemoteRelease.fullPress,
);

enum RemoteProbeMode { liveView, props, release, set, zoom, af }

typedef ProbePoint = ({double x, double y});
typedef ProbeSize = ({int width, int height});
typedef ReleaseParams = ({int half, int full});
typedef PropertyAssignment = ({int property, int value});

/// The options of the remote-shooting probe modes.
class RemoteProbeOptions {
  const RemoteProbeOptions({
    required this.mode,
    this.liveViewSeconds = 0,
    this.evfOutput = CanonEvfOutput.pc,
    this.saveFrame,
    this.duration,
    this.pollInterval = ProfileOptions.defaultEventPollInterval,
    this.releaseParams = defaultReleaseParams,
    this.shots = defaultShots,
    this.releaseTimeout = defaultReleaseTimeout,
    this.assignment,
    this.trials = defaultSetTrials,
    this.zoom,
    this.af,
    this.afSpace = defaultAfSpace,
  });

  final RemoteProbeMode mode;
  final int liveViewSeconds;
  final int evfOutput;
  final String? saveFrame;
  final Duration? duration;
  final Duration pollInterval;
  final ReleaseParams releaseParams;
  final int shots;
  final Duration releaseTimeout;
  final PropertyAssignment? assignment;
  final int trials;
  final int? zoom;
  final ProbePoint? af;
  final ProbeSize afSpace;

  /// Null when no remote mode is chosen. Throws a [FormatException] naming
  /// the bad option.
  static RemoteProbeOptions? fromArgs(ArgResults args) {
    final liveView = args.option('liveview');
    final set = args.option('set');
    final zoom = args.option('zoom');
    final af = args.option('af');
    final modes = [
      if (liveView != null) RemoteProbeMode.liveView,
      if (args.flag('props')) RemoteProbeMode.props,
      if (args.flag('release')) RemoteProbeMode.release,
      if (set != null) RemoteProbeMode.set,
      if (zoom != null) RemoteProbeMode.zoom,
      if (af != null) RemoteProbeMode.af,
    ];
    if (modes.isEmpty) {
      return null;
    }
    if (modes.length > 1) {
      throw const FormatException(
        'Choose one of --liveview, --props, --release, --set, --zoom, --af.',
      );
    }
    final evfOutput = args.option('evf-output');
    final duration = args.option('duration');
    final pollInterval = args.option('poll-interval');
    final releaseParams = args.option('release-params');
    final shots = args.option('shots');
    final releaseTimeout = args.option('release-timeout');
    final trials = args.option('trials');
    final afSpace = args.option('af-space');
    return RemoteProbeOptions(
      mode: modes.single,
      liveViewSeconds: liveView == null
          ? 0
          : _parsePositive(liveView, 'liveview'),
      evfOutput: evfOutput == null
          ? CanonEvfOutput.pc
          : _parseEvfOutput(evfOutput),
      saveFrame: args.option('save-frame'),
      duration: duration == null
          ? null
          : Duration(seconds: _parsePositive(duration, 'duration')),
      pollInterval: pollInterval == null
          ? ProfileOptions.defaultEventPollInterval
          : Duration(
              milliseconds: _parsePositive(pollInterval, 'poll-interval'),
            ),
      releaseParams: releaseParams == null
          ? defaultReleaseParams
          : _parseReleaseParams(releaseParams),
      shots: shots == null ? defaultShots : _parsePositive(shots, 'shots'),
      releaseTimeout: releaseTimeout == null
          ? defaultReleaseTimeout
          : Duration(
              seconds: _parsePositive(releaseTimeout, 'release-timeout'),
            ),
      assignment: set == null ? null : _parsePropertyAssignment(set),
      trials: trials == null
          ? defaultSetTrials
          : _parsePositive(trials, 'trials'),
      zoom: zoom == null ? null : parseProbeInt(zoom, 'zoom'),
      af: af == null ? null : parseNormalizedPoint(af),
      afSpace: afSpace == null ? defaultAfSpace : parseSize(afSpace),
    );
  }
}

/// `0x`-prefixed text is hex, anything else decimal.
int parseProbeInt(String text, String option) {
  final trimmed = text.trim().toLowerCase();
  final hex = trimmed.startsWith(_hexPrefix);
  final value = int.tryParse(
    hex ? trimmed.substring(_hexPrefix.length) : trimmed,
    radix: hex ? _hexRadix : _decimalRadix,
  );
  if (value == null || value < 0) {
    throw FormatException('--$option: "$text" is not a number.');
  }
  return value;
}

int _parsePositive(String text, String option) {
  final value = parseProbeInt(text, option);
  if (value == 0) {
    throw FormatException('--$option must be above 0.');
  }
  return value;
}

int _parseEvfOutput(String text) {
  final value = parseProbeInt(text, 'evf-output');
  if (value != CanonEvfOutput.pc && value != CanonEvfOutput.tftAndPc) {
    throw const FormatException(
      '--evf-output must be ${CanonEvfOutput.pc} (PC) '
      'or ${CanonEvfOutput.tftAndPc} (camera screen and PC).',
    );
  }
  return value;
}

PropertyAssignment _parsePropertyAssignment(String text) {
  final parts = text.split('=');
  if (parts.length != _pairParts) {
    throw const FormatException('--set expects prop=value, e.g. 0xd103=0x48.');
  }
  return (
    property: parseProbeInt(parts[0], 'set'),
    value: parseProbeInt(parts[1], 'set'),
  );
}

ProbePoint parseNormalizedPoint(String text) {
  final parts = text.split(',').map((part) => double.tryParse(part.trim()));
  if (parts.length != _pairParts ||
      parts.any((part) => part == null || part < 0 || part > 1)) {
    throw const FormatException('--af expects x,y between 0 and 1.');
  }
  return (x: parts.first!, y: parts.last!);
}

ReleaseParams _parseReleaseParams(String text) {
  final parts = text.split(',');
  if (parts.length != _pairParts) {
    throw const FormatException(
      '--release-params expects half,full, e.g. 1,3.',
    );
  }
  return (
    half: parseProbeInt(parts[0], 'release-params'),
    full: parseProbeInt(parts[1], 'release-params'),
  );
}

ProbeSize parseSize(String text) {
  final parts = text.toLowerCase().split('x');
  if (parts.length != _pairParts) {
    throw const FormatException('--af-space expects WIDTHxHEIGHT.');
  }
  return (
    width: _parsePositive(parts[0], 'af-space'),
    height: _parsePositive(parts[1], 'af-space'),
  );
}
