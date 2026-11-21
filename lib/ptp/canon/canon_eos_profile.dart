import 'dart:async';
import 'dart:typed_data';

import '../camera_client.dart';
import '../camera_profile.dart';
import '../dataset.dart';
import '../ptp_constants.dart';
import '../ptp_session.dart';
import 'canon_constants.dart';
import 'canon_events.dart';

const _canonVendorExtensionId = 0x0B;
const _remoteModeExitTimeout = Duration(seconds: 1);

/// The EOS R refuses connections for 12-15 s after one closes; later
/// retries only wait for the next attempt to succeed.
const _canonReconnectPolicy = ReconnectPolicy(
  first: Duration(seconds: 15),
  repeat: Duration(seconds: 5),
);

/// Per-model behaviour that differs between EOS bodies.
class CanonEosQuirks {
  const CanonEosQuirks({
    this.deleteBusyAttempts = 3,
    this.deleteBusyDelay = const Duration(milliseconds: 200),
  });

  /// The EOS answers busy while it updates its catalog after a removal.
  final int deleteBusyAttempts;
  final Duration deleteBusyDelay;
}

class CanonEosProfile implements CameraProfile {
  const CanonEosProfile({
    this.quirks = const CanonEosQuirks(),
    this.modelQuirks = const {},
  });

  final CanonEosQuirks quirks;

  /// Overrides of [quirks], keyed by the DeviceInfo model.
  final Map<String, CanonEosQuirks> modelQuirks;

  @override
  String get id => 'canon-eos';

  @override
  Set<int> get usbVendorIds => const {0x04A9};

  @override
  bool matches(PtpDeviceInfo info) =>
      info.vendorExtensionId == _canonVendorExtensionId ||
      info.manufacturer.startsWith('Canon');

  @override
  Future<ProfileConnection> attach(
    PtpSession session,
    PtpDeviceInfo info,
    ProfileOptions options,
  ) async {
    final supported = info.operationsSupported.toSet();
    Future<void> runIfSupported(int opcode, [List<int> params = const []]) =>
        supported.contains(opcode)
        ? session.execute(opcode, params: params)
        : Future.value();
    await runIfSupported(CanonEosOperation.setRemoteMode, const [
      CanonEosMode.remoteModeOn,
    ]);
    await runIfSupported(CanonEosOperation.setEventMode, const [
      CanonEosMode.eventModeOn,
    ]);
    final connection = _CanonEosConnection(
      id,
      session,
      supported,
      modelQuirks[info.model] ?? quirks,
      options.onEventData,
    );
    if (supported.contains(CanonEosOperation.getEvent)) {
      final initialEvents = (await session.execute(CanonEosOperation.getEvent))
          .data;
      options.onEventData?.call(initialEvents);
      connection
        .._noteClock(parseCanonEvents(initialEvents))
        .._startPolling(options.eventPollInterval);
    }
    return connection;
  }
}

class _CanonEosConnection implements ProfileConnection {
  _CanonEosConnection(
    this.profileId,
    this._session,
    this._supported,
    this._quirks,
    this._onEventData,
  ) {
    _session.disconnected.then((_) => _stop());
  }

  @override
  final String profileId;

  final PtpSession _session;
  final Set<int> _supported;
  final CanonEosQuirks _quirks;
  final void Function(Uint8List data)? _onEventData;
  final _events = StreamController<ProfileEvent>();
  Timer? _pollTimer;
  bool _pollInFlight = false;

  /// The last camera-time property and when it arrived.
  ({int seconds, Stopwatch age})? _clock;

  @override
  Stream<ProfileEvent> get events => _events.stream;

  void _startPolling(Duration interval) {
    _pollTimer = Timer.periodic(interval, (_) => _poll());
  }

  void _stop() {
    _pollTimer?.cancel();
    if (!_events.isClosed) {
      _events.close();
    }
  }

  Future<void> _poll() async {
    if (_pollInFlight) {
      return;
    }
    _pollInFlight = true;
    try {
      final result = await _session.execute(CanonEosOperation.getEvent);
      _onEventData?.call(result.data);
      final events = parseCanonEvents(result.data);
      _noteClock(events);
      for (final event in events) {
        final forwarded = switch (event) {
          CanonObjectAdded(:final format)
              when format == PtpObjectFormat.association =>
            null,
          CanonObjectAdded(:final handle) ||
          CanonTransferRequested(:final handle) => ObjectAdded(handle),
          CanonObjectRemoved(:final handle) => ObjectRemoved(handle),
          CanonStorageChanged() => const StorageChanged(),
          CanonPropertyChanged() || CanonAllowedValues() => null,
        };
        if (forwarded != null && !_events.isClosed) {
          _events.add(forwarded);
        }
      }
    } on PtpResponseException {
      return;
    } on CameraDisconnectedException {
      return;
    } finally {
      _pollInFlight = false;
    }
  }

  void _noteClock(List<CanonEvent> events) {
    for (final event in events) {
      if (event case CanonPropertyChanged(
        property: CanonEosProperty.cameraTime,
        u32: final seconds?,
      )) {
        _clock = (seconds: seconds, age: Stopwatch()..start());
      }
    }
  }

  /// The camera-time property advanced by the time since it arrived.
  @override
  Future<DateTime?> fallbackCameraTime() async {
    final clock = _clock;
    if (clock == null) {
      return null;
    }
    final wall = DateTime.fromMillisecondsSinceEpoch(
      clock.seconds * Duration.millisecondsPerSecond +
          clock.age.elapsedMilliseconds,
      isUtc: true,
    );
    return DateTime(
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
      wall.second,
      wall.millisecond,
    );
  }

  @override
  CameraObjectKind? kindOf(int format) => switch (format) {
    PtpObjectFormat.exifJpeg || PtpObjectFormat.jfif => CameraObjectKind.jpeg,
    CanonObjectFormat.cr3 => CameraObjectKind.raw,
    _ => null,
  };

  @override
  RetryPolicy get deleteBusyRetry => RetryPolicy(
    attempts: _quirks.deleteBusyAttempts,
    delay: _quirks.deleteBusyDelay,
  );

  @override
  ReconnectPolicy get reconnectPolicy => _canonReconnectPolicy;

  /// Hands the camera back in remote mode, as on connect.
  @override
  Future<void> detach() async {
    _stop();
    if (!_supported.contains(CanonEosOperation.setRemoteMode)) {
      return;
    }
    await _session
        .execute(
          CanonEosOperation.setRemoteMode,
          params: const [CanonEosMode.remoteModeOn],
        )
        .timeout(_remoteModeExitTimeout)
        .then<void>((_) {}, onError: (_) {});
  }
}
