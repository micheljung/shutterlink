import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/cr3_preview.dart';
import 'package:shutterlink/data/exif.dart';
import 'package:shutterlink/probe/probe_args.dart';
import 'package:shutterlink/probe/probe_measurements.dart';
import 'package:shutterlink/probe/remote_probe.dart';
import 'package:shutterlink/ptpip/ptpip.dart';
import 'package:uuid/uuid.dart';

export 'package:shutterlink/probe/probe_args.dart'
    show
        exitCameraBusy,
        exitCameraRefused,
        exitOk,
        exitPairingRequired,
        exitUnavailable,
        exitUsage;

const _defaultName = 'Shutterlink';
const _defaultGuidFileName = '.shutterlink_guid';
const _bytesPerMegabyte = 1024 * 1024;
const _microsecondsPerSecond = 1000000;
const _hexRadix = 16;
const _hexDigitsPerByte = 2;
const _packetTypeOffset = 4;

/// The remote modes poll GetEvent themselves, so the profile's poller must
/// not take their events.
const _profilePollerIdle = Duration(days: 1);
const pairingInstructions = '''
The camera does not know this computer yet. Pair it once:
  1. On the camera open MENU > Wireless communication settings > Wi-Fi function.
  2. Choose "Remote control (EOS Utility)".
  3. Either add a device and pick "Camera access point mode" (Easy
     connection), then join this computer to the Wi-Fi network the camera
     shows; or, with the camera on your Wi-Fi network, select the saved
     connection and press OK at "Start pairing devices".
  4. Run this probe again; when the camera shows the name
     "{name}", confirm it on the camera.
''';

ArgParser probeArgParser() => ArgParser()
  ..addOption('host', help: 'Camera IP address (camera access point).')
  ..addOption('port', defaultsTo: '$ptpIpDefaultPort')
  ..addOption('name', defaultsTo: _defaultName, help: 'Name shown on camera.')
  ..addOption('guid-file', help: 'Defaults to ~/$_defaultGuidFileName.')
  ..addOption('download-dir', defaultsTo: '.')
  ..addOption('dump', help: 'Write a hex dump of every PTP/IP packet here.')
  ..addOption('index', help: 'Index into the newest-first photo list.')
  ..addOption(
    'pair-timeout',
    defaultsTo: '${ptpIpDefaultPairingTimeout.inSeconds}',
    help: 'Seconds to wait while pairing is confirmed on the camera.',
  )
  ..addFlag(
    'watch-events',
    negatable: false,
    help: 'Log Canon GetEvent records every second until Ctrl-C (no download).',
  )
  ..addFlag(
    'clock',
    negatable: false,
    help: 'Print the device properties and camera clock, then exit.',
  )
  ..addOption(
    'liveview',
    valueHelp: 'seconds',
    help: 'Run Canon live view and report fps and frame timings.',
  )
  ..addOption(
    'evf-output',
    valueHelp: '2|3',
    help: 'EVF output while live view runs: 2 = PC, 3 = camera screen and PC.',
  )
  ..addOption(
    'save-frame',
    valueHelp: 'path',
    help: 'Write the last live-view JPEG here.',
  )
  ..addFlag(
    'props',
    negatable: false,
    help:
        'Print the core settings and every property in the initial '
        'GetEvent dump, then print changes until Ctrl-C or --duration.',
  )
  ..addOption('duration', valueHelp: 'seconds', help: 'How long --props runs.')
  ..addOption(
    'poll-interval',
    valueHelp: 'ms',
    help:
        'GetEvent interval for --liveview, --props, --release '
        '(default ${ProfileOptions.defaultEventPollInterval.inMilliseconds}).',
  )
  ..addFlag(
    'release',
    negatable: false,
    help:
        'With live view on, press the shutter and time trigger -> events '
        '-> new handle -> thumbnail.',
  )
  ..addOption(
    'release-params',
    valueHelp: 'half,full',
    help:
        'RemoteReleaseOn/Off p1 for half and full press '
        '(default ${CanonRemoteRelease.halfPress},'
        '${CanonRemoteRelease.fullPress}; unconfirmed).',
  )
  ..addOption(
    'shots',
    valueHelp: 'N',
    help: 'Shots for --release (default $defaultShots).',
  )
  ..addOption(
    'release-timeout',
    valueHelp: 'seconds',
    help:
        'Wait this long for 0xc185 after a release '
        '(default ${defaultReleaseTimeout.inSeconds}).',
  )
  ..addOption(
    'set',
    valueHelp: 'prop=value',
    help:
        'SetDevicePropValueEx, e.g. 0xd103=0x48, then time its echo at '
        'GetEvent intervals of '
        '${setPollIntervals.map((i) => i.inMilliseconds).join(', ')} ms '
        'against the fps cost.',
  )
  ..addOption(
    'trials',
    valueHelp: 'N',
    help: 'Sets per interval for --set (default $defaultSetTrials).',
  )
  ..addOption(
    'zoom',
    valueHelp: 'level',
    help: 'Experimental: send Zoom (0x9158) with live view on.',
  )
  ..addOption(
    'af',
    valueHelp: 'x,y',
    help:
        'Experimental: focus at a point from 0 to 1 with SetLiveAfFrame '
        '(0x915a), falling back to ZoomPosition + DoAf.',
  )
  ..addOption(
    'af-space',
    valueHelp: 'WxH',
    help:
        'Experimental: coordinate space for --af '
        '(default ${defaultAfSpace.width}x${defaultAfSpace.height}).',
  )
  ..addFlag('help', abbr: 'h', negatable: false);

Future<void> main(List<String> args) async {
  exitCode = await runProbe(args);
}

Future<int> runProbe(
  List<String> args, {
  StringSink? output,
  int? watchPolls,
  Duration watchInterval = PtpIpCameraClient.defaultEventPollInterval,
  Duration measureWindow = probeMeasureWindow,
}) async {
  final out = output ?? stdout;
  final parser = probeArgParser();
  final ArgResults options;
  final RemoteProbeOptions? remote;
  try {
    options = parser.parse(args);
    remote = RemoteProbeOptions.fromArgs(options);
  } on FormatException catch (error) {
    out
      ..writeln(error.message)
      ..writeln(parser.usage);
    return exitUsage;
  }
  final host = options.option('host');
  final port = int.tryParse(options.option('port')!);
  final indexOption = options.option('index');
  final index = indexOption == null ? null : int.tryParse(indexOption);
  final pairSeconds = int.tryParse(options.option('pair-timeout')!);
  if (options.flag('help') ||
      host == null ||
      port == null ||
      pairSeconds == null ||
      (indexOption != null && index == null)) {
    out
      ..writeln('Usage: dart run bin/probe.dart --host <camera-ip> [options]')
      ..writeln(parser.usage);
    return options.flag('help') ? exitOk : exitUsage;
  }
  final name = options.option('name')!;
  final guid = await loadOrCreateGuid(
    File(options.option('guid-file') ?? _defaultGuidPath()),
  );
  final dumpPath = options.option('dump');
  final dump = dumpPath == null ? null : File(dumpPath).openWrite();
  try {
    return await _probe(
      out,
      host: host,
      port: port,
      identity: CameraIdentity(guid: guid, name: name),
      downloadDir: Directory(options.option('download-dir')!),
      index: index,
      clockOnly: options.flag('clock'),
      pairingTimeout: Duration(seconds: pairSeconds),
      watch: options.flag('watch-events'),
      watchPolls: watchPolls,
      watchInterval: watchInterval,
      remote: remote,
      measureWindow: measureWindow,
      dump: dump,
    );
  } on PairingRequiredException catch (error) {
    out
      ..writeln('Pairing required (InitFail reason ${error.reason}).')
      ..write(pairingInstructions.replaceAll('{name}', name));
    return exitPairingRequired;
  } on CameraBusyException catch (error) {
    out.writeln(
      'Camera is busy (InitFail reason ${error.reason}); '
      'close other apps connected to it and retry.',
    );
    return exitCameraBusy;
  } on CameraDisconnectedException catch (error) {
    out.writeln('Camera unreachable or disconnected: ${error.cause}');
    return exitUnavailable;
  } on PtpProtocolException catch (error) {
    out.writeln('Camera sent something unexpected: $error');
    return exitUnavailable;
  } on PtpResponseException catch (error) {
    out.writeln('Camera refused: ${describeRefusal(error)}');
    return exitCameraRefused;
  } finally {
    await dump?.close();
  }
}

Future<int> _probe(
  StringSink out, {
  required String host,
  required int port,
  required CameraIdentity identity,
  required Directory downloadDir,
  required int? index,
  required bool clockOnly,
  required Duration pairingTimeout,
  required bool watch,
  required int? watchPolls,
  required Duration watchInterval,
  required RemoteProbeOptions? remote,
  required Duration measureWindow,
  required IOSink? dump,
}) async {
  out.writeln('Connecting to $host:$port as "${identity.name}"...');
  final events = watch && remote == null
      ? _EventWatcher(out, watchPolls)
      : null;
  final ledger = TransactionLedger();
  Uint8List? initialDump;
  final client = await PtpIpCameraClient.connect(
    host: host,
    port: port,
    identity: identity,
    pairingTimeout: pairingTimeout,
    packetTap: dump == null && remote == null
        ? null
        : (channel, direction, frame) {
            if (dump != null) {
              _dumpPacket(dump, channel, direction, frame);
            }
            ledger.onPacket(channel, frame);
          },
    eventPollInterval: remote == null ? watchInterval : _profilePollerIdle,
    onEventData: remote == null
        ? events?.onData
        : (data) => initialDump ??= data,
  );
  try {
    final info = client.deviceInfo;
    out
      ..writeln('Manufacturer: ${info.manufacturer}')
      ..writeln('Model:        ${info.model}')
      ..writeln('Version:      ${info.deviceVersion}')
      ..writeln('Serial:       ${info.serialNumber}')
      ..writeln('Operations:   ${info.operationsSupported.map(hex).join(' ')}');
    if (remote != null) {
      return await RemoteProbe(
        out,
        client,
        ledger,
        remote,
        initialDump: initialDump,
        measureWindow: measureWindow,
      ).run();
    }
    if (clockOnly) {
      final properties = client.ptpDeviceInfo.devicePropertiesSupported;
      final cameraTime = await client.cameraTime();
      out
        ..writeln('Properties:   ${properties.map(hex).join(' ')}')
        ..writeln('Camera time:  ${cameraTime?.toIso8601String() ?? 'none'}')
        ..writeln('Phone time:   ${DateTime.now().toIso8601String()}');
      return exitOk;
    }

    if (events != null) {
      out.writeln('Watching GetEvent; press Ctrl-C to stop.');
      await events.done;
      return exitOk;
    }

    final photos = (await client.listPhotos()).sorted(_newestFirst);
    for (final kind in CameraObjectKind.values) {
      final count = photos.where((o) => o.kind == kind).length;
      out.writeln('${kind.name.toUpperCase()}: $count');
    }
    if (photos.isEmpty) {
      out.writeln('No photos on the card.');
      return exitOk;
    }
    final selected = index ?? 0;
    if (selected < 0 || selected >= photos.length) {
      out.writeln('--index must be between 0 and ${photos.length - 1}.');
      return exitUsage;
    }
    final target = photos[selected];

    final thumbWatch = Stopwatch()..start();
    final thumb = await client.thumbnail(target.handle);
    out.writeln(
      thumb == null
          ? 'Thumbnail of ${target.filename}: none'
          : 'Thumbnail of ${target.filename}: ${thumb.length} bytes '
                'in ${thumbWatch.elapsedMilliseconds} ms',
    );
    await downloadDir.create(recursive: true);
    if (thumb != null) {
      final thumbFile = File(
        p.join(downloadDir.path, '${p.basename(target.filename)}.thumb.jpg'),
      );
      await thumbFile.writeAsBytes(thumb);
      final size = _jpegSize(thumb);
      out.writeln(
        'Thumbnail: ${size == null ? 'size unknown' : '${size.width}x${size.height}'}, '
        'EXIF orientation ${exifOrientation(thumb) ?? 'none'} -> ${thumbFile.path}',
      );
    }

    final file = File(p.join(downloadDir.path, target.filename));
    final sink = await file.open(mode: FileMode.write);
    final watch = Stopwatch()..start();
    try {
      await client.download(target, (chunk) => sink.writeFrom(chunk));
    } finally {
      await sink.close();
    }
    watch.stop();
    out.writeln(
      'Photo orientation: ${await _orientationOf(file, target) ?? 'none'}',
    );
    final seconds = watch.elapsedMicroseconds / _microsecondsPerSecond;
    final megabytes = target.size / _bytesPerMegabyte;
    out.writeln(
      'Downloaded ${target.filename} (${megabytes.toStringAsFixed(2)} MB) '
      'in ${seconds.toStringAsFixed(2)} s: '
      '${(megabytes / seconds).toStringAsFixed(2)} MB/s -> ${file.path}',
    );
    return exitOk;
  } finally {
    await client.close();
  }
}

/// The EXIF orientation of the downloaded [file]: from a JPEG's APP1, or a
/// CR3's CMT1 box.
Future<int?> _orientationOf(File file, CameraObject object) async {
  final handle = await file.open();
  try {
    final head = await handle.read(
      min(cr3PreviewReadCap, await handle.length()),
    );
    return object.kind == CameraObjectKind.jpeg
        ? exifOrientation(head)
        : cr3Orientation(head);
  } finally {
    await handle.close();
  }
}

const _startOfFrameMarkers = {
  0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, //
  0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
};

/// The stored pixel size of a JPEG, before any EXIF orientation, from its
/// start-of-frame segment.
({int width, int height})? _jpegSize(Uint8List jpeg) {
  final data = ByteData.sublistView(jpeg);
  var position = 2;
  while (position + 9 <= jpeg.length && jpeg[position] == 0xFF) {
    final marker = jpeg[position + 1];
    if (_startOfFrameMarkers.contains(marker)) {
      return (
        width: data.getUint16(position + 7),
        height: data.getUint16(position + 5),
      );
    }
    position += 2 + data.getUint16(position + 2);
  }
  return null;
}

class _EventWatcher {
  _EventWatcher(this._out, this._maxPolls);

  final StringSink _out;
  final int? _maxPolls;
  final _done = Completer<void>();
  var _batches = 0;

  Future<void> get done {
    final subscription = ProcessSignal.sigint.watch().listen((_) => _finish());
    return _done.future.whenComplete(subscription.cancel);
  }

  void onData(Uint8List data) {
    final stamp = DateTime.now().toIso8601String();
    _out.writeln(
      _batches == 0
          ? '$stamp initial dump (${data.length} bytes)'
          : '$stamp poll $_batches (${data.length} bytes)',
    );
    _logRecords(_out, stamp, data);
    final limit = _maxPolls;
    if (limit != null && _batches >= limit) {
      _finish();
    }
    _batches++;
  }

  void _finish() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}

void _logRecords(StringSink out, String stamp, Uint8List data) {
  final records = canonEventRecords(
    data,
    onMalformed: (offset, size) => out.writeln(
      '$stamp malformed: Malformed Canon event at $offset: '
      'size $size of ${data.length}\n'
      '${hexDump(data)}',
    ),
  );
  for (final record in records) {
    final event = switch (parseCanonEvent(record)) {
      final CanonObjectAdded added =>
        '>>> ObjectAdded handle ${hex(added.handle)} '
            'storage ${hex(added.storageId)} format ${hex(added.format)} '
            'size ${added.size} parent ${hex(added.parent)} >>> ',
      CanonTransferRequested(:final handle) =>
        '>>> TransferRequested handle ${hex(handle)} >>> ',
      CanonObjectRemoved(:final handle) =>
        '>>> ObjectRemoved handle ${hex(handle)} >>> ',
      CanonStorageChanged() => '>>> StorageChanged >>> ',
      CanonPropertyChanged() || CanonAllowedValues() || null => '',
    };
    out
      ..writeln(
        '$stamp ${event}record ${hex(record.type)} size ${record.bytes.length}',
      )
      ..write(
        hexDump(Uint8List.sublistView(record.bytes, canonEventHeaderSize)),
      );
  }
}

int _newestFirst(CameraObject a, CameraObject b) {
  final left = a.captureDate;
  final right = b.captureDate;
  if (left == null || right == null) {
    return (right == null ? 0 : 1) - (left == null ? 0 : 1);
  }
  return right.compareTo(left);
}

String _defaultGuidPath() {
  final home =
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';
  return p.join(home, _defaultGuidFileName);
}

Future<Uint8List> loadOrCreateGuid(File file) async {
  if (await file.exists()) {
    final text = (await file.readAsString()).trim();
    if (text.length == ptpIpGuidSize * _hexDigitsPerByte) {
      return Uint8List.fromList([
        for (var i = 0; i < text.length; i += _hexDigitsPerByte)
          int.parse(text.substring(i, i + _hexDigitsPerByte), radix: _hexRadix),
      ]);
    }
  }
  final guid = UuidValue.fromString(const Uuid().v4()).toBytes();
  await file.writeAsString(
    guid
        .map((b) => b.toRadixString(_hexRadix).padLeft(_hexDigitsPerByte, '0'))
        .join(),
  );
  return guid;
}

void _dumpPacket(
  IOSink sink,
  PtpIpChannel channel,
  PacketDirection direction,
  Uint8List frame,
) {
  final type = ByteData.sublistView(frame)
      .getUint32(_packetTypeOffset, Endian.little);
  sink
    ..writeln(
      '${DateTime.now().toIso8601String()} ${direction.name} ${channel.name} '
      '${describePacketType(type)} ${frame.length} bytes',
    )
    ..write(hexDump(frame));
}
