import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptpip/ptpip.dart';

import '../bin/probe.dart';
import 'ptpip/fake_camera.dart';

const _unknownEventRecord = [12, 0, 0, 0, 0x89, 0xC1, 0, 0, 1, 2, 3, 4];

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

  test('unreachable camera is reported', () async {
    final args = baseArgs();
    await camera.stop();
    final out = StringBuffer();
    expect(await runProbe(args, output: out), exitUnavailable);
    camera = FakeCamera();
    await camera.start();
  });
}
