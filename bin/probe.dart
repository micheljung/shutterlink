import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/ptpip/ptpip.dart';
import 'package:uuid/uuid.dart';

const exitOk = 0;
const exitUsage = 64;
const exitUnavailable = 69;
const exitCameraBusy = 75;
const exitPairingRequired = 77;

const _defaultName = 'Shutterlink';
const _defaultGuidFileName = '.shutterlink_guid';
const _bytesPerMegabyte = 1024 * 1024;
const _microsecondsPerSecond = 1000000;
const _hexRadix = 16;
const _hexDigitsPerByte = 2;
const _packetTypeOffset = 4;
const pairingInstructions = '''
The camera does not know this computer yet. Pair it once:
  1. On the camera open MENU > Wireless communication settings > Wi-Fi function.
  2. Choose "Remote control (EOS Utility)".
  3. Add a device and pick "Camera access point mode" (Easy connection).
  4. Join this computer to the Wi-Fi network the camera shows.
  5. Run this probe again; when the camera shows the name
     "{name}", confirm it on the camera.
''';

ArgParser _parser() => ArgParser()
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
  ..addFlag('help', abbr: 'h', negatable: false);

Future<void> main(List<String> args) async {
  exitCode = await runProbe(args);
}

Future<int> runProbe(
  List<String> args, {
  StringSink? output,
  int? watchPolls,
  Duration watchInterval = PtpIpCameraClient.defaultEventPollInterval,
}) async {
  final out = output ?? stdout;
  final parser = _parser();
  final ArgResults options;
  try {
    options = parser.parse(args);
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
      tap: dump == null ? null : (c, d, f) => _dumpPacket(dump, c, d, f),
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
  required PacketTap? tap,
}) async {
  out.writeln('Connecting to $host:$port as "${identity.name}"...');
  final events = watch ? _EventWatcher(out, watchPolls) : null;
  final client = await PtpIpCameraClient.connect(
    host: host,
    port: port,
    identity: identity,
    pairingTimeout: pairingTimeout,
    packetTap: tap,
    eventPollInterval: watchInterval,
    onEventData: events?.onData,
  );
  try {
    final info = client.deviceInfo;
    out
      ..writeln('Manufacturer: ${info.manufacturer}')
      ..writeln('Model:        ${info.model}')
      ..writeln('Version:      ${info.deviceVersion}')
      ..writeln('Serial:       ${info.serialNumber}')
      ..writeln(
        'Operations:   ${info.operationsSupported.map(_hex).join(' ')}',
      );
    if (clockOnly) {
      final properties = client.ptpDeviceInfo.devicePropertiesSupported;
      final cameraTime = await client.cameraTime();
      out
        ..writeln('Properties:   ${properties.map(_hex).join(' ')}')
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
    final file = File(p.join(downloadDir.path, target.filename));
    final sink = await file.open(mode: FileMode.write);
    final watch = Stopwatch()..start();
    try {
      await client.download(target, (chunk) => sink.writeFrom(chunk));
    } finally {
      await sink.close();
    }
    watch.stop();
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
  final List<CanonEventRecord> records;
  try {
    records = canonEventRecords(data);
  } on PtpIpProtocolException catch (error) {
    out.writeln('$stamp malformed: ${error.message}\n${hexDump(data)}');
    return;
  }
  for (final record in records) {
    final event = switch (parseCanonEvent(record)) {
      final CanonObjectAdded added =>
        '>>> ObjectAdded handle ${_hex(added.handle)} '
            'storage ${_hex(added.storageId)} format ${_hex(added.format)} '
            'size ${added.size} parent ${_hex(added.parent)} >>> ',
      CanonTransferRequested(:final handle) =>
        '>>> TransferRequested handle ${_hex(handle)} >>> ',
      CanonObjectRemoved(:final handle) =>
        '>>> ObjectRemoved handle ${_hex(handle)} >>> ',
      CanonStorageChanged() => '>>> StorageChanged >>> ',
      CanonPropertyChanged() || null => '',
    };
    out
      ..writeln(
        '$stamp ${event}record ${_hex(record.type)} size ${record.bytes.length}',
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

String _hex(int value) => '0x${value.toRadixString(_hexRadix)}';
