import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/probe/libusb_pipe.dart';
import 'package:shutterlink/probe/probe_args.dart';
import 'package:shutterlink/probe/probe_measurements.dart';
import 'package:shutterlink/ptp/canon/canon_live_view_stats.dart';
import 'package:shutterlink/ptpip/ptpip.dart';
import 'package:shutterlink/usb/usb_pipe.dart';

import '../bin/probe.dart';
import 'fakes/fake_usb_pipe.dart';
import 'ptpip/fake_camera.dart';

const _unknownEventRecord = [12, 0, 0, 0, 0x89, 0xC1, 0, 0, 1, 2, 3, 4];
const _statusRecord = [12, 0, 0, 0, 0x8B, 0xC1, 0, 0, 1, 2, 3, 4];
const _fastPoll = ['--poll-interval', '20'];
const _slowObject = Duration(milliseconds: 200);
const _measureWindow = Duration(milliseconds: 100);

RemoteProbeOptions? _remote(List<String> args) =>
    RemoteProbeOptions.fromArgs(probeArgParser().parse(args));

Uint8List _frame(int seed) => patternBytes(500 + seed, seed: seed);

void main() {
  late FakeCamera camera;
  late Directory temp;
  late File guidFile;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('probe_test');
    guidFile = File('${temp.path}/guid');
    camera = FakeCamera(pairedGuids: [pairedGuid]);
    await camera.start();
  });

  tearDown(() async {
    await camera.stop();
    await temp.delete(recursive: true);
  });

  List<String> baseArgs() => [
    '--host',
    InternetAddress.loopbackIPv4.address,
    '--port',
    '${camera.port}',
    '--guid-file',
    guidFile.path,
    '--download-dir',
    '${temp.path}/out',
  ];

  String hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  test('--help prints usage', () async {
    final out = StringBuffer();
    expect(await runProbe(['--help'], output: out), exitOk);
    expect(out.toString(), contains('--guid-file'));
  });

  test('missing host or bad options are usage errors', () async {
    final out = StringBuffer();
    expect(await runProbe([], output: out), exitUsage);
    expect(await runProbe(['--bogus'], output: out), exitUsage);
    expect(
      await runProbe(['--host', 'x', '--index', 'abc'], output: out),
      exitUsage,
    );
    expect(
      await runProbe(['--host', 'x', '--pair-timeout', 'soon'], output: out),
      exitUsage,
    );
  });

  test('unpaired GUID prints pairing instructions', () async {
    final out = StringBuffer();
    final code = await runProbe([
      ...baseArgs(),
      '--name',
      'Laptop',
    ], output: out);
    expect(code, exitPairingRequired);
    expect(out.toString(), contains('Remote control (EOS Utility)'));
    expect(out.toString(), contains('"Laptop"'));
    final guid = (await guidFile.readAsString()).trim();
    expect(guid, hasLength(32));
    expect(await loadOrCreateGuid(guidFile), hasLength(16));
    expect(hex(await loadOrCreateGuid(guidFile)), guid);
  });

  test('paired probe downloads the newest photo and dumps packets', () async {
    await guidFile.writeAsString(hex(pairedGuid));
    final dump = '${temp.path}/dump.txt';
    final out = StringBuffer();
    final code = await runProbe([...baseArgs(), '--dump', dump], output: out);
    expect(code, exitOk, reason: out.toString());
    final text = out.toString();
    expect(text, contains('Model:        Canon EOS R'));
    expect(text, contains('JPEG: 3'));
    expect(text, contains('RAW: 1'));
    expect(text, contains('MB/s'));
    final newest = camera.objects.firstWhere(
      (o) => o.handle == FakeCamera.largeJpegHandle,
    );
    final file = File('${temp.path}/out/${newest.filename}');
    expect(await file.readAsBytes(), newest.content);
    final dumped = await File(dump).readAsString();
    expect(dumped, contains('sent command InitCommandRequest'));
    expect(dumped, contains('received command EndData'));
  });

  test('--index selects another photo, out of range is rejected', () async {
    await guidFile.writeAsString(hex(pairedGuid));
    final out = StringBuffer();
    expect(
      await runProbe([...baseArgs(), '--index', '1'], output: out),
      exitOk,
    );
    expect(out.toString(), contains('Thumbnail of IMG_0001.JPG: 100 bytes'));
    expect(
      out.toString(),
      contains('Thumbnail: size unknown, EXIF orientation none'),
    );
    expect(out.toString(), contains('Photo orientation: none'));
    expect(
      File('${temp.path}/out/IMG_0001.JPG.thumb.jpg').existsSync(),
      isTrue,
    );
    expect(
      await runProbe([...baseArgs(), '--index', '9'], output: out),
      exitUsage,
    );
  });

  test(
    '--watch-events logs event records and highlights new objects',
    () async {
      await camera.stop();
      final shot = FakeObject(
        handle: 0xDEADBEEF,
        format: PtpObjectFormat.exifJpeg,
        filename: 'IMG_0042.JPG',
        parent: FakeCamera.folderHandle,
        content: Uint8List(3000),
      );
      final records = Uint8List.fromList([
        ...objectAddedRecord(shot),
        ...transferRequestRecord(shot),
        ..._unknownEventRecord,
      ]);
      camera = FakeCamera(pairedGuids: [pairedGuid], eventRecords: records);
      await camera.start();
      await guidFile.writeAsString(hex(pairedGuid));
      final out = StringBuffer();
      final code = await runProbe(
        [...baseArgs(), '--watch-events'],
        output: out,
        watchPolls: 2,
        watchInterval: const Duration(milliseconds: 20),
      );
      final text = out.toString();
      expect(code, exitOk, reason: text);
      expect(text, contains('initial dump'));
      expect(text, contains('poll 2'));
      expect(
        text,
        contains(
          '>>> ObjectAdded handle 0xdeadbeef storage 0x20001 format 0x3801 '
          'size 3000 parent 0x11 >>> record 0xc181 size 53',
        ),
      );
      expect(text, contains('ef be ad de'));
      expect(
        text,
        contains(
          '>>> TransferRequested handle 0xdeadbeef >>> record 0xc186 size 41',
        ),
      );
      expect(text, contains(' record 0xc189 size 12'));
      expect(text, isNot(contains('Thumbnail')));
    },
  );

  test('--watch-events reports a malformed record', () async {
    await camera.stop();
    camera = FakeCamera(
      pairedGuids: [pairedGuid],
      eventRecords: Uint8List.fromList([64, 0, 0, 0, 1, 0, 0, 0]),
    );
    await camera.start();
    await guidFile.writeAsString(hex(pairedGuid));
    final out = StringBuffer();
    await runProbe(
      [...baseArgs(), '--watch-events'],
      output: out,
      watchPolls: 0,
      watchInterval: const Duration(milliseconds: 20),
    );
    expect(out.toString(), contains('malformed: Malformed Canon event at 0'));
  });

  test('--clock prints device properties and the camera time', () async {
    await camera.stop();
    camera = FakeCamera(
      pairedGuids: [pairedGuid],
      devicePropertyValues: {
        PtpDeviceProperty.dateTime: ptpStringValue('20261113T095830Z'),
      },
    );
    await camera.start();
    await guidFile.writeAsString(hex(pairedGuid));
    final out = StringBuffer();
    expect(await runProbe([...baseArgs(), '--clock'], output: out), exitOk);
    expect(out.toString(), contains('Properties:   0x5011'));
    expect(out.toString(), contains('Camera time:  2026-11-13T09:58:30.000Z'));
    expect(out.toString(), contains('Phone time:'));
    expect(
      camera.receivedOpcodes,
      isNot(contains(PtpOperation.getPartialObject)),
    );
  });

  test('--clock without clock support prints none', () async {
    await guidFile.writeAsString(hex(pairedGuid));
    final out = StringBuffer();
    expect(await runProbe([...baseArgs(), '--clock'], output: out), exitOk);
    expect(out.toString(), contains('Camera time:  none'));
  });

  test('a busy camera is reported', () async {
    await camera.stop();
    camera = FakeCamera(
      pairedGuids: const [],
      initFailReason: PtpIpInitFailReason.busy,
    );
    await camera.start();
    final out = StringBuffer();
    final code = await runProbe([
      ...baseArgs(),
      '--pair-timeout',
      '1',
    ], output: out);
    expect(code, exitCameraBusy);
    expect(out.toString(), contains('busy'));
  });

  test('a camera without photos reports so', () async {
    await camera.stop();
    camera = FakeCamera(objects: []);
    await camera.start();
    final out = StringBuffer();
    expect(await runProbe(baseArgs(), output: out), exitOk);
    expect(out.toString(), contains('No photos'));
  });

  group('remote option parsing', () {
    test('no remote flag yields no remote options', () {
      expect(_remote(['--host', 'x']), isNull);
    });

    test('defaults', () {
      final options = _remote(['--release'])!;
      expect(options.mode, RemoteProbeMode.release);
      expect(options.releaseParams, (half: 1, full: 3));
      expect(options.shots, defaultShots);
      expect(options.evfOutput, CanonEvfOutput.pc);
      expect(options.pollInterval, ProfileOptions.defaultEventPollInterval);
      expect(options.releaseTimeout, defaultReleaseTimeout);
      expect(options.afSpace, defaultAfSpace);
      expect(options.trials, defaultSetTrials);
      expect(options.duration, isNull);
    });

    test('every flag is read', () {
      final liveView = _remote([
        '--liveview',
        '30',
        '--evf-output',
        '3',
        '--save-frame',
        'f.jpg',
        '--poll-interval',
        '250',
      ])!;
      expect(liveView.mode, RemoteProbeMode.liveView);
      expect(liveView.liveViewSeconds, 30);
      expect(liveView.evfOutput, CanonEvfOutput.tftAndPc);
      expect(liveView.saveFrame, 'f.jpg');
      expect(liveView.pollInterval, const Duration(milliseconds: 250));
      final props = _remote(['--props', '--duration', '5'])!;
      expect(props.mode, RemoteProbeMode.props);
      expect(props.duration, const Duration(seconds: 5));
      final release = _remote([
        '--release',
        '--release-params',
        '2,4',
        '--shots',
        '10',
        '--release-timeout',
        '40',
      ])!;
      expect(release.releaseParams, (half: 2, full: 4));
      expect(release.shots, 10);
      expect(release.releaseTimeout, const Duration(seconds: 40));
      final set = _remote(['--set', '0xD103=72', '--trials', '5'])!;
      expect(set.mode, RemoteProbeMode.set);
      expect(set.assignment, (property: 0xD103, value: 72));
      expect(set.trials, 5);
      expect(_remote(['--zoom', '5'])!.zoom, 5);
      final af = _remote(['--af', '0.5, 0.25', '--af-space', '600X400'])!;
      expect(af.mode, RemoteProbeMode.af);
      expect(af.af, (x: 0.5, y: 0.25));
      expect(af.afSpace, (width: 600, height: 400));
    });

    test('bad values are usage errors naming the option', () async {
      const bad = {
        '--liveview': ['--liveview', 'soon'],
        'above 0': ['--liveview', '0'],
        '--evf-output': ['--liveview', '1', '--evf-output', '1'],
        '--duration': ['--props', '--duration', '-1'],
        '--poll-interval': ['--props', '--poll-interval', 'x'],
        '--release-params': ['--release', '--release-params', '1'],
        '--shots': ['--release', '--shots', 'many'],
        '--release-timeout': ['--release', '--release-timeout', 'x'],
        '--set expects': ['--set', '0xd103'],
        '--set:': ['--set', 'iso=1'],
        '--trials': ['--set', '1=2', '--trials', '0'],
        '--zoom': ['--zoom', 'big'],
        '--af expects': ['--af', '1.5,0'],
        '--af-space': ['--af', '0,0', '--af-space', '600'],
        'Choose one': ['--props', '--release'],
      };
      for (final MapEntry(key: message, value: args) in bad.entries) {
        final out = StringBuffer();
        expect(
          await runProbe(['--host', 'x', ...args], output: out),
          exitUsage,
          reason: args.join(' '),
        );
        expect(out.toString(), contains(message), reason: args.join(' '));
      }
    });

    test('pure parsers', () {
      expect(parseProbeInt('0x1F', 'o'), 31);
      expect(parseProbeInt(' 12 ', 'o'), 12);
      expect(() => parseProbeInt('0xZZ', 'o'), throwsFormatException);
      expect(() => parseSize('0x10'), throwsFormatException);
      expect(() => parseNormalizedPoint('0.1'), throwsFormatException);
      expect(() => parseNormalizedPoint('a,b'), throwsFormatException);
    });

    test('help marks zoom and af as experimental', () async {
      final out = StringBuffer();
      expect(await runProbe(['--help'], output: out), exitOk);
      final text = out.toString();
      for (final flag in [
        '--liveview',
        '--props',
        '--release',
        '--release-params',
        '--set',
        '--trials',
        '--save-frame',
        '--evf-output',
      ]) {
        expect(text, contains(flag));
      }
      expect(text, contains('Experimental: send Zoom (0x9158)'));
      expect(text, contains('Experimental: focus at a point'));
    });
  });

  group('measurements', () {
    test('live view report', () {
      const summary = LiveViewSummary(
        elapsed: Duration(seconds: 2),
        frames: 2,
        fps: 0,
        averageFps: 0,
        counts: (notReady: 3, busy: 1, errors: 0),
        watchdogAborts: 2,
        timeToFirstByte: LiveViewSpread(
          mean: Duration(milliseconds: 10),
          p95: Duration(milliseconds: 10),
        ),
        transfer: LiveViewSpread(
          mean: Duration(milliseconds: 30),
          p95: Duration(milliseconds: 30),
        ),
        meanFrameBytes: 2048,
      );
      expect(
        liveViewReport(summary),
        'Live view 2.0 s: 2 frames, average 1.00 fps\n'
        'Time to first byte: mean 10.0 ms, p95 10.0 ms\n'
        'Transfer: mean 30.0 ms, p95 30.0 ms\n'
        'Frame size: mean 2.0 KiB\n'
        'Not ready (0xa102) 3, busy (0x2019) 1, errors 0, '
        'watchdog aborts 2\n',
      );
      expect(
        liveViewReport(
          const LiveViewSummary(
            elapsed: Duration.zero,
            frames: 0,
            fps: 0,
            averageFps: 0,
            counts: (notReady: 0, busy: 0, errors: 0),
            watchdogAborts: 0,
          ),
        ),
        allOf(
          contains('average 0.00 fps'),
          contains('Time to first byte: mean -, p95 -'),
          contains('Frame size: mean 0.0 KiB'),
          isNot(contains('Channel overhead')),
        ),
      );
      expect(
        liveViewReport(
          const LiveViewSummary(
            elapsed: Duration(seconds: 2),
            frames: 20,
            fps: 0,
            averageFps: 0,
            counts: (notReady: 0, busy: 0, errors: 0),
            watchdogAborts: 0,
            channelOverhead: LiveViewSpread(
              mean: Duration(milliseconds: 10),
              p95: Duration(milliseconds: 25),
            ),
          ),
        ),
        endsWith(
          'Channel overhead: mean 10.0 ms, p95 25.0 ms, '
          '10.0 % of the frame time\n',
        ),
      );
    });

    test('records are described with raw type and names', () {
      String describe(List<int> bytes) =>
          describeCanonRecord(canonEventRecords(Uint8List.fromList(bytes))[0]);
      expect(
        describe(propertyChangedRecord(CanonEosProperty.aperture, 0x30)),
        '0xc189 Av (0xd101) = 0x30',
      );
      expect(
        describe(propertyBytesChangedRecord(0xD1FF, [1, 2])),
        '0xc189 0xd1ff = [01 02]',
      );
      expect(
        describe(allowedValuesRecord(CanonEosProperty.iso, 6, [0x48, 0x50])),
        '0xc18a ISO (0xd103) allowed [0x48 0x50] (type 0x6)',
      );
      expect(
        describe(objectRemovedRecord(0x21)),
        '0xc182 ObjectRemoved handle 0x21',
      );
      expect(describe(_statusRecord), '0xc18b size 12: 01 02 03 04');
      expect(
        describe([48, 0, 0, 0, 0x8B, 0xC1, 0, 0, ...List.filled(40, 0)]),
        endsWith('00 …'),
      );
    });

    test('release timeline finishes on the new file, not on 0xc185', () {
      final timeline = ReleaseTimeline(const Duration(seconds: 1));
      CanonEventRecord record(List<int> bytes) =>
          canonEventRecords(Uint8List.fromList(bytes))[0];
      final photo = FakeObject(
        handle: 0x30,
        format: PtpObjectFormat.exifJpeg,
        filename: 'IMG_0030.JPG',
      );
      expect(
        timeline.note(
          const Duration(seconds: 2),
          record(cameraStatusRecord(CanonCameraStatus.capturing)),
        ),
        const Duration(seconds: 1),
      );
      timeline.note(
        const Duration(seconds: 3),
        record(cameraStatusRecord(CanonCameraStatus.capturing)),
      );
      timeline.note(
        const Duration(milliseconds: 3500),
        record(storageChangedRecord(fakeStorageId)),
      );
      timeline.note(
        const Duration(seconds: 4),
        record(
          objectAddedRecord(
            FakeObject(
              handle: 0x11,
              format: PtpObjectFormat.association,
              filename: '100CANON',
            ),
          ),
        ),
      );
      expect(timeline.isFinished, isFalse);
      timeline.note(
        const Duration(milliseconds: 4500),
        record(objectAddedRecord(photo, sixtyFourBit: true)),
      );
      expect(timeline.isFinished, isTrue);
      expect(timeline.addedHandle, 0x30);
      timeline.note(
        const Duration(seconds: 5),
        record(cameraStatusRecord(CanonCameraStatus.idle)),
      );
      expect(timeline.row(1), [
        '1',
        '-',
        '1000.0 ms',
        '2500.0 ms',
        '3500.0 ms',
        '4000.0 ms',
        '-',
        '-',
        '-',
        '-',
      ]);
    });

    test('release timeline finishes when the camera goes idle', () {
      final timeline = ReleaseTimeline(Duration.zero);
      CanonEventRecord record(int status) =>
          canonEventRecords(Uint8List.fromList(cameraStatusRecord(status)))[0];
      timeline.note(const Duration(seconds: 1), record(CanonCameraStatus.idle));
      expect(timeline.isFinished, isFalse);
      timeline
        ..note(const Duration(seconds: 2), record(CanonCameraStatus.capturing))
        ..note(const Duration(seconds: 3), record(CanonCameraStatus.idle));
      expect(timeline.isFinished, isTrue);
      expect(timeline.captureDone, const Duration(seconds: 3));
    });

    test('tables pad their columns', () {
      expect(
        formatTable(
          ['A', 'Long'],
          [
            ['wide', '1'],
          ],
        ),
        'A     Long\nwide  1\n',
      );
    });
  });

  group('remote modes', () {
    setUp(() => guidFile.writeAsString(hex(pairedGuid)));

    test('--liveview reports fps and saves the last frame', () async {
      final frames = [for (var i = 0; i < 20; i++) _frame(i)];
      camera.device.liveViewFrames.addAll(frames);
      final saved = '${temp.path}/frame.jpg';
      final out = StringBuffer();
      final code = await runProbe([
        ...baseArgs(),
        '--liveview',
        '1',
        '--evf-output',
        '3',
        '--save-frame',
        saved,
        ..._fastPoll,
      ], output: out);
      final text = out.toString();
      expect(code, exitOk, reason: text);
      expect(text, contains('Live view on (EVF output 3).'));
      expect(text, contains('1s: 20 fps'));
      expect(text, contains('20 frames, average'));
      expect(text, contains('Time to first byte: mean'));
      expect(text, isNot(contains('Time to first byte: mean -')));
      expect(text, contains('watchdog aborts 0'));
      expect(await File(saved).readAsBytes(), frames.last);
      expect(
        camera.device.canonProperties[CanonEosProperty.evfOutputDevice],
        CanonEvfOutput.tft,
      );
      expect(camera.getEventCount, greaterThan(2));
    });

    test('--liveview refused by the camera exits cleanly', () async {
      camera.device.responseOverrides[CanonEosOperation.setDevicePropValueEx] =
          PtpResponseCode.deviceBusy;
      final out = StringBuffer();
      final code = await runProbe([
        ...baseArgs(),
        '--liveview',
        '1',
      ], output: out);
      expect(code, exitCameraRefused);
      expect(
        out.toString(),
        contains('Live view refused: 0x2019 (operation 0x9110)'),
      );
    });

    test('--liveview without frames has nothing to save', () async {
      final out = StringBuffer();
      final code = await runProbe([
        ...baseArgs(),
        '--liveview',
        '1',
        '--save-frame',
        '${temp.path}/none.jpg',
      ], output: out);
      expect(code, exitOk, reason: out.toString());
      expect(out.toString(), contains('No frame to save.'));
    });

    test('--props prints the dump and timestamped changes', () async {
      await camera.stop();
      camera = FakeCamera(
        pairedGuids: [pairedGuid],
        initialDump: Uint8List.fromList([
          ...propertyChangedRecord(CanonEosProperty.aperture, 0x30),
          ...allowedValuesRecord(CanonEosProperty.aperture, 3, [0x28, 0x30]),
          ...propertyChangedRecord(0xD1FE, 7),
        ]),
        eventRecords: Uint8List.fromList(
          propertyChangedRecord(CanonEosProperty.iso, 0x48),
        ),
      );
      await camera.start();
      final out = StringBuffer();
      final code = await runProbe([
        ...baseArgs(),
        '--props',
        '--duration',
        '1',
        '--poll-interval',
        '200',
      ], output: out);
      final text = out.toString();
      expect(code, exitOk, reason: text);
      expect(text, contains('  Av (0xd101) = 0x30, allowed [0x28 0x30]'));
      expect(text, contains('  Tv (0xd102) = -'));
      expect(text, contains('  0xc189 0xd1fe = 0x7'));
      expect(text, contains('Polling GetEvent every 200 ms'));
      final changes = text
          .split('\n')
          .where((line) => line.endsWith('0xc189 ISO (0xd103) = 0x48'))
          .toList();
      expect(changes.length, greaterThan(2));
      expect(changes.last, matches(RegExp(r'^\d{4}-\d\d-\d\dT')));
    });

    test('--props without a dump still polls', () async {
      await camera.stop();
      camera = FakeCamera(
        pairedGuids: [pairedGuid],
        supportedOperations: [
          ...FakeCamera.defaultOperations.where(
            (op) => op != CanonEosOperation.getEvent,
          ),
        ],
      );
      await camera.start();
      camera.device.responseOverrides[CanonEosOperation.getEvent] =
          PtpResponseCode.operationNotSupported;
      final out = StringBuffer();
      final code = await runProbe([
        ...baseArgs(),
        '--props',
        '--duration',
        '1',
        ..._fastPoll,
      ], output: out);
      expect(code, exitOk, reason: out.toString());
      expect(out.toString(), contains('no initial GetEvent dump'));
      expect(
        RegExp('GetEvent refused: 0x2005').allMatches(out.toString()),
        hasLength(1),
      );
    });

    test('--release times events, diff and thumbnail per shot', () async {
      camera.device
        ..captureObjectDelay = _slowObject
        ..liveViewFrames.addAll([for (var i = 0; i < 10; i++) _frame(i)]);
      final out = StringBuffer();
      final code = await runProbe([
        ...baseArgs(),
        '--release',
        '--shots',
        '3',
        ..._fastPoll,
      ], output: out);
      final text = out.toString();
      expect(code, exitOk, reason: text);
      expect(text, contains('Shot 1:'));
      expect(text, contains('Shot 2:'));
      expect(text, contains(' 0xc18b size 12: 01 00 00 00'));
      expect(text, contains(' RemoteReleaseOn(1) -> 0x2001'));
      expect(text, contains(' RemoteReleaseOff(3) -> 0x2001'));
      expect(text, contains(' 0xc185 StorageInfoChanged'));
      expect(text, contains(' 0xc181 ObjectAdded handle 0x30 format 0x3801'));
      expect(text, contains('New handles: 0x30'));
      expect(text, contains('New handles: 0x31'));
      expect(text, contains('New handles: 0x32'));
      expect(text, contains('GetThumb 0x32 -> 0x2001, 100 bytes'));
      expect(text, isNot(contains('0x2019')));
      expect(text, isNot(contains('no capture')));
      expect(camera.device.busyRefusals, 0);
      expect(text, contains('Diff cold: 7 transactions in '));
      expect(text, contains('warm: 7 transactions'));
      final table = text.substring(text.indexOf('Shot  Release'));
      expect(table.split('\n').where((l) => l.isNotEmpty), hasLength(4));
      expect(table, contains('7 tx'));
      final releases = camera.device.vendorCalls;
      expect(releases.map((c) => c.opcode), [
        for (var shot = 0; shot < 3; shot++) ...[
          CanonEosOperation.remoteReleaseOn,
          CanonEosOperation.remoteReleaseOn,
          CanonEosOperation.remoteReleaseOff,
          CanonEosOperation.remoteReleaseOff,
        ],
      ]);
      expect(releases.take(4).map((c) => c.params), [
        [1, 0],
        [3, 0],
        [3],
        [1],
      ]);
    });

    test('--release retries a busy release, then records it as busy', () async {
      camera.device.responseOverrides[CanonEosOperation.remoteReleaseOn] =
          PtpResponseCode.deviceBusy;
      final out = StringBuffer();
      final code = await runProbe([
        ...baseArgs(),
        '--release',
        '--release-params',
        '2,4',
        '--release-timeout',
        '1',
        ..._fastPoll,
      ], output: out);
      final text = out.toString();
      expect(code, exitOk, reason: text);
      expect(text, contains('RemoteReleaseOn(2) -> 0x2019, retry 5'));
      expect(text, contains('RemoteReleaseOn(2) -> 0x2019\n'));
      expect(text, contains('RemoteReleaseOff(4) -> 0x2001'));
      expect(text, contains('Camera busy'));
      expect(text, contains('New handles: \n'));
    });

    test('--release reports a shot whose autofocus failed', () async {
      camera.device
        ..failedAutofocusReleases = 1
        ..captureObjectDelay = _slowObject;
      final out = StringBuffer();
      final code = await runProbe([
        ...baseArgs(),
        '--release',
        '--shots',
        '2',
        '--release-timeout',
        '1',
        ..._fastPoll,
      ], output: out);
      final text = out.toString();
      expect(code, exitOk, reason: text);
      expect(
        RegExp(r'no capture \(AF failed\?\)').allMatches(text),
        hasLength(1),
      );
      expect(text.indexOf('no capture'), lessThan(text.indexOf('Shot 2:')));
      expect(text, contains('New handles: 0x30'));
      expect(camera.device.busyRefusals, 0);
    });

    test('--release without live view still measures', () async {
      camera.device.responseOverrides[CanonEosOperation.setDevicePropValueEx] =
          PtpResponseCode.deviceBusy;
      final out = StringBuffer();
      final code = await runProbe([
        ...baseArgs(),
        '--release',
        ..._fastPoll,
      ], output: out);
      expect(code, exitOk, reason: out.toString());
      expect(out.toString(), contains('Measuring without live view.'));
      expect(out.toString(), contains('New handles: 0x30'));
    });

    test('a refusal outside a measured step exits cleanly', () async {
      camera.device.responseOverrides[PtpOperation.getStorageIds] =
          PtpResponseCode.deviceBusy;
      final out = StringBuffer();
      final code = await runProbe([
        ...baseArgs(),
        '--release',
        ..._fastPoll,
      ], output: out);
      expect(code, exitCameraRefused);
      expect(
        out.toString(),
        contains('Camera refused: 0x2019 (operation 0x1004)'),
      );
    });

    test('--set times the echo at each poll interval', () async {
      await camera.stop();
      camera = FakeCamera(
        pairedGuids: [pairedGuid],
        initialDump: Uint8List.fromList(
          propertyChangedRecord(CanonEosProperty.iso, 0x40),
        ),
      );
      await camera.start();
      camera.device
        ..echoCanonProperties = true
        ..liveViewFrames.addAll([for (var i = 0; i < 5; i++) _frame(i)]);
      final out = StringBuffer();
      final code = await runProbe(
        [...baseArgs(), '--set', '0xd103=0x48', '--trials', '1'],
        output: out,
        measureWindow: _measureWindow,
      );
      final text = out.toString();
      expect(code, exitOk, reason: text);
      expect(text, contains('ISO (0xd103) is 0x40; setting 0x48.'));
      expect(text, contains('Without GetEvent polling: '));
      expect(text, contains('250 ms trial 1 0x48: echo after'));
      expect(text, contains('500 ms trial 1 0x48: echo after'));
      expect(text, contains('Restored 0x40 -> 0x2001'));
      expect(text, contains('Interval  Echo mean'));
      expect(text, contains('\n350 ms'));
      expect(camera.device.canonProperties[CanonEosProperty.iso], 0x40);
    });

    test('--set reports refusals and missing echoes', () async {
      camera.device.liveViewFrames.add(_frame(1));
      final out = StringBuffer();
      final code = await runProbe(
        [...baseArgs(), '--set', '0xd103=0x48', '--trials', '1'],
        output: out,
        measureWindow: _measureWindow,
      );
      expect(code, exitOk, reason: out.toString());
      expect(out.toString(), contains('not in the initial dump'));
      expect(out.toString(), contains('250 ms trial 1 0x48: no echo'));

      final refused = StringBuffer();
      camera.device.responseOverrides[CanonEosOperation.setDevicePropValueEx] =
          PtpResponseCode.deviceBusy;
      expect(
        await runProbe(
          [...baseArgs(), '--set', '0xd103=0x48', '--trials', '2'],
          output: refused,
          measureWindow: _measureWindow,
        ),
        exitOk,
      );
      expect(refused.toString(), contains('Measuring echo without live view'));
      expect(refused.toString(), contains('trial 2 0x48: refused 0x2019'));
    });

    test('--zoom sends the level and reports the code', () async {
      camera.device.liveViewFrames.add(_frame(1));
      final out = StringBuffer();
      final code = await runProbe(
        [...baseArgs(), '--zoom', '5', '--save-frame', '${temp.path}/z.jpg'],
        output: out,
        measureWindow: _measureWindow,
      );
      expect(code, exitOk, reason: out.toString());
      expect(out.toString(), contains('Zoom 5 (0x9158) -> 0x2001'));
      expect(out.toString(), contains('frames in the next 100 ms'));
      expect(camera.device.vendorCalls.single.params, [5]);
    });

    test('--af sends the frame, falling back to zoom position', () async {
      final out = StringBuffer();
      final code = await runProbe(
        [...baseArgs(), '--af', '0.5,0.25', '--af-space', '600x400'],
        output: out,
        measureWindow: _measureWindow,
      );
      expect(code, exitOk, reason: out.toString());
      expect(
        out.toString(),
        contains('SetLiveAfFrame 300,100 (0x915a) -> 0x2001'),
      );
      final call = camera.device.vendorCalls.single;
      expect(call.opcode, CanonEosOperation.setLiveAfFrame);
      expect(call.dataOut, canonAfFramePayload(300, 100));

      camera.device.responseOverrides[CanonEosOperation.setLiveAfFrame] =
          PtpResponseCode.operationNotSupported;
      final fallback = StringBuffer();
      await runProbe(
        [...baseArgs(), '--af', '0.5,0.25', '--af-space', '600x400'],
        output: fallback,
        measureWindow: _measureWindow,
      );
      expect(fallback.toString(), contains('(0x915a) -> 0x2005'));
      expect(
        fallback.toString(),
        contains('ZoomPosition 300,100 (0x9159) -> 0x2001'),
      );
      expect(fallback.toString(), contains('DoAf (0x9154) -> 0x2001'));
      final fallbackCalls = camera.device.vendorCalls.skip(1);
      expect(fallbackCalls.map((c) => c.opcode), [
        CanonEosOperation.zoomPosition,
        CanonEosOperation.doAf,
      ]);
      expect(fallbackCalls.map((c) => c.params), [
        [300, 100],
        <int>[],
      ]);
    });
  });

  group('USB', () {
    const canon = (vendorId: 0x04a9, productId: 0x32da);
    late FakePtpDevice device;
    late FakeUsbPipe pipe;
    late List<UsbDeviceId?> opened;

    setUp(() {
      device = FakePtpDevice();
      pipe = FakeUsbPipe(device);
      opened = [];
    });

    Future<int> probeUsb(List<String> args, StringBuffer out) => runProbe(
      ['--usb', ...args],
      output: out,
      openUsb: (id) async {
        opened.add(id);
        return pipe;
      },
    );

    test('device ids are hex vid:pid', () {
      expect(parseUsbDeviceId('04a9:32DA'), canon);
      expect(formatUsbDeviceId(canon), '04a9:32da');
      for (final bad in ['04a9', '04a9:32da:1', 'canon:1', '10000:1']) {
        expect(() => parseUsbDeviceId(bad), throwsFormatException);
      }
    });

    test('usage errors name the conflicting options', () async {
      Future<String> usage(List<String> args) async {
        final out = StringBuffer();
        expect(await runProbe(args, output: out), exitUsage);
        return out.toString();
      }

      expect(
        await usage(['--host', 'x', '--usb']),
        startsWith('Choose one of --host and --usb.'),
      );
      expect(
        await usage(['--usb-device', '04a9:32da']),
        startsWith('--usb-device needs --usb.'),
      );
      expect(
        await usage(['--usb', '--usb-device', 'canon']),
        startsWith('--usb-device expects vid:pid'),
      );
      expect(
        await usage(['--usb', '--dump', 'x']),
        startsWith('--dump works with --host only.'),
      );
      expect(await usage([]), contains('--usb [--usb-device vid:pid]'));
      final help = StringBuffer();
      expect(await runProbe(['--help'], output: help), exitOk);
      expect(
        help.toString(),
        allOf(contains('--usb-device'), contains('--list-usb')),
      );
    });

    test('--list-usb prints each device or why it cannot', () async {
      final out = StringBuffer();
      expect(
        await runProbe(
          ['--list-usb'],
          output: out,
          listUsb: () => const [
            UsbStillImageDevice(
              id: canon,
              bus: 1,
              address: 2,
              manufacturer: 'Canon Inc.',
              product: 'Canon Digital Camera',
            ),
            UsbStillImageDevice(
              id: canon,
              bus: 3,
              address: 14,
              openError: 'no access to /dev/bus/usb/003/014',
            ),
          ],
          openUsb: (_) => fail('--list-usb must not open a device'),
        ),
        exitOk,
      );
      expect(
        out.toString(),
        '04a9:32da bus 1 address 2 (/dev/bus/usb/001/002), '
        'Canon Inc. Canon Digital Camera\n'
        '04a9:32da bus 3 address 14 (/dev/bus/usb/003/014), '
        'open: no access to /dev/bus/usb/003/014\n',
      );

      final none = StringBuffer();
      expect(
        await runProbe(['--list-usb'], output: none, listUsb: () => const []),
        exitOk,
      );
      expect(none.toString(), 'No USB still-image devices.\n');

      final missing = StringBuffer();
      expect(
        await runProbe(
          ['--list-usb'],
          output: missing,
          listUsb: () =>
              throw const UsbTransferException('libusb is not available'),
        ),
        exitUnavailable,
      );
      expect(
        missing.toString(),
        'Cannot list USB devices: libusb is not available\n',
      );
    });

    test('a camera that cannot be opened is reported cleanly', () async {
      final out = StringBuffer();
      final code = await runProbe(
        ['--usb', '--props', '--duration', '1'],
        output: out,
        openUsb: (_) => throw const UsbTransferException(
          'no access to /dev/bus/usb/001/002: the device node is missing',
        ),
      );
      expect(code, exitUnavailable);
      expect(
        out.toString(),
        'Opening the USB camera...\n'
        'USB camera unavailable: no access to /dev/bus/usb/001/002: '
        'the device node is missing\n',
      );
    });

    test('--usb-device picks the camera; --clock works over USB', () async {
      final out = StringBuffer();
      final code = await probeUsb([
        '--usb-device',
        '04a9:32da',
        '--clock',
      ], out);
      expect(code, exitOk, reason: out.toString());
      expect(opened, [canon]);
      expect(out.toString(), contains('Opening the USB camera 04a9:32da...'));
      expect(out.toString(), contains('Camera time:'));
      expect(pipe.isClosed, isTrue);
    });

    test('--liveview reports the channel overhead', () async {
      device.liveViewFrames.addAll([for (var i = 0; i < 20; i++) _frame(i)]);
      final out = StringBuffer();
      final code = await probeUsb(['--liveview', '1', ..._fastPoll], out);
      final text = out.toString();
      expect(code, exitOk, reason: text);
      expect(opened, [null]);
      expect(text, contains('20 frames, average'));
      expect(text, contains('Channel overhead: mean '));
      expect(text, isNot(contains('Channel overhead: mean -')));
      expect(pipe.bulkInTiming, contains(true));
    });

    test('--release prints the trigger-to-thumbnail timeline', () async {
      device
        ..captureObjectDelay = _slowObject
        ..liveViewFrames.addAll([for (var i = 0; i < 10; i++) _frame(i)]);
      final out = StringBuffer();
      final code = await probeUsb(['--release', ..._fastPoll], out);
      final text = out.toString();
      expect(code, exitOk, reason: text);
      expect(text, contains(' RemoteReleaseOn(1) -> 0x2001'));
      expect(text, contains(' 0xc185 StorageInfoChanged'));
      expect(text, contains('New handles: 0x30'));
      expect(text, contains('GetThumb 0x30 -> 0x2001, 100 bytes'));
      expect(text, contains('Diff cold: 7 transactions in '));
      expect(text, contains('Shot  Release'));
    });

    test('every other remote mode runs over USB', () async {
      for (final args in [
        ['--props', '--duration', '1'],
        ['--set', '0xd103=0x48', '--trials', '1'],
        ['--zoom', '5'],
        ['--af', '0.5,0.5'],
      ]) {
        device = FakePtpDevice();
        pipe = FakeUsbPipe(device);
        final out = StringBuffer();
        final code = await probeUsb([...args, ..._fastPoll], out);
        expect(code, exitOk, reason: '$args: $out');
        expect(pipe.isClosed, isTrue, reason: '$args');
      }
    });
  });

  test('unreachable camera is reported', () async {
    final args = baseArgs();
    await camera.stop();
    final out = StringBuffer();
    expect(await runProbe(args, output: out), exitUnavailable);
    camera = FakeCamera();
    await camera.start();
  });
}
