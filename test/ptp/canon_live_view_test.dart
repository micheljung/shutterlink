import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptp/canon/canon_live_view.dart';
import 'package:shutterlink/ptpip/ptpip.dart';
import 'package:shutterlink/usb/usb_camera_client.dart';
import 'package:shutterlink/usb/usb_pipe.dart';

import '../fakes/fake_usb_pipe.dart';
import '../ptpip/fake_camera.dart';

const _frameDeadline = Duration(seconds: 5);
const _settle = Duration(milliseconds: 200);
const _frameCount = 3;
const _frameSize = 600;
const _frameInterval = Duration(milliseconds: 80);
const _timerSlack = Duration(milliseconds: 5);

typedef _Rig = ({
  FakePtpDevice device,
  PtpSession session,
  void Function() disconnect,
});

Future<_Rig> _overPtpIp() async {
  final camera = FakeCamera();
  await camera.start();
  final client = await PtpIpCameraClient.connect(
    host: InternetAddress.loopbackIPv4.address,
    port: camera.port,
    identity: pairedIdentity,
    responseTimeout: testResponseTimeout,
    eventPollInterval: testPollInterval,
  );
  addTearDown(() async {
    await client.close();
    await camera.stop();
  });
  return (
    device: camera.device,
    session: client.session,
    disconnect: camera.dropConnection,
  );
}

Future<_Rig> _overUsb() async {
  final device = FakePtpDevice();
  final pipe = FakeUsbPipe(device);
  final client = await connectUsb(
    BulkLink(pipe),
    responseTimeout: testResponseTimeout,
    options: const ProfileOptions(eventPollInterval: testPollInterval),
  );
  addTearDown(client.close);
  return (device: device, session: client.session, disconnect: pipe.unplug);
}

List<Uint8List> _frames() => [
  for (var i = 0; i < _frameCount; i++) patternBytes(_frameSize, seed: i),
];

(int, int) _decode(Uint8List payload) {
  final view = ByteData.sublistView(payload);
  return (view.getUint32(4, Endian.little), view.getUint32(8, Endian.little));
}

int _viewFinderRequests(FakePtpDevice device) => device.receivedOpcodes
    .where((op) => op == CanonEosOperation.getViewFinderData)
    .length;

void main() {
  for (final (name, connect) in [('PTP/IP', _overPtpIp), ('USB', _overUsb)]) {
    group('over $name', () {
      late FakePtpDevice device;
      late PtpSession session;
      late void Function() disconnect;

      setUp(() async {
        (:device, :session, :disconnect) = await connect();
      });

      CanonLiveViewLoop loop({
        int output = CanonEvfOutput.pc,
        Duration? minFrameInterval,
      }) {
        final loop = CanonLiveViewLoop(
          session,
          output: output,
          minFrameInterval: minFrameInterval,
        );
        addTearDown(loop.stop);
        return loop;
      }

      CanonLiveViewLoop listening({int output = CanonEvfOutput.pc}) =>
          loop(output: output)..frames.listen(null);

      test('start turns the EVF on, then routes it to the PC', () async {
        await listening().start();

        expect(device.canonPropertyPayloads.map(_decode), [
          (CanonEosProperty.evfMode, CanonEvfMode.on),
          (CanonEosProperty.evfOutputDevice, CanonEvfOutput.pc),
        ]);
        expect(device.canonPropertyPayloads.first, [
          ...[12, 0, 0, 0],
          ...[0xB1, 0xD1, 0, 0],
          ...[1, 0, 0, 0],
        ]);
        expect(device.canonPropertyPayloads.last, [
          ...[12, 0, 0, 0],
          ...[0xB0, 0xD1, 0, 0],
          ...[2, 0, 0, 0],
        ]);
      });

      test('the EVF output is a parameter', () async {
        await listening(output: CanonEvfOutput.tftAndPc).start();

        expect(
          device.canonProperties[CanonEosProperty.evfOutputDevice],
          CanonEvfOutput.tftAndPc,
        );
      });

      test('frames arrive in order, without the non-JPEG records', () async {
        final frames = _frames();
        device.liveViewFrames.addAll(frames);
        final live = loop();
        final received = live.frames.take(_frameCount).toList();
        await live.start();

        expect(await received.timeout(_frameDeadline), frames);
        expect(live.errorCount, 0);
      });

      test('not ready backs off, then frames resume', () async {
        final live = loop();
        final first = live.frames.first.timeout(_frameDeadline);
        await live.start();
        await Future<void>.delayed(_settle);

        final maxRequests =
            _settle.inMicroseconds ~/ canonLiveViewMinBackoff.inMicroseconds +
            1;
        expect(live.notReadyCount, greaterThan(1));
        expect(_viewFinderRequests(device), lessThanOrEqualTo(maxRequests));

        final frame = _frames().first;
        device.liveViewFrames.add(frame);
        expect(await first, frame);
      });

      test('busy is retried like not ready', () async {
        device
          ..viewFinderCodes.addAll([
            PtpResponseCode.deviceBusy,
            PtpResponseCode.deviceBusy,
          ])
          ..liveViewFrames.addAll(_frames());
        final live = loop();
        final first = live.frames.first.timeout(_frameDeadline);
        await live.start();

        expect(await first, _frames().first);
        expect(live.busyCount, 2);
        expect(live.notReadyCount, 0);
      });

      test('cancelling the frames stops fetching and restores TFT', () async {
        device.liveViewFrames.addAll(_frames());
        final live = loop();
        final first = live.frames.first.timeout(_frameDeadline);
        await live.start();
        await first;

        expect(
          device.canonProperties[CanonEosProperty.evfOutputDevice],
          CanonEvfOutput.tft,
        );
        final requests = _viewFinderRequests(device);
        await Future<void>.delayed(_settle);
        expect(_viewFinderRequests(device), requests);
      });

      test('stop closes the frames and restores TFT', () async {
        final live = loop();
        final done = live.frames.toList();
        await live.start();

        await live.stop();
        await live.stop();

        expect(await done.timeout(_frameDeadline), isEmpty);
        expect(device.canonPropertyPayloads.map(_decode).last, (
          CanonEosProperty.evfOutputDevice,
          CanonEvfOutput.tft,
        ));
        expect(
          () => live.start(),
          throwsStateError,
          reason: 'a stopped loop cannot restart',
        );
      });

      test('stop before start sends nothing', () async {
        final live = loop();
        await live.stop();

        expect(await live.frames.toList(), isEmpty);
        expect(device.canonPropertyPayloads, isEmpty);
      });

      test('another error surfaces on the stream and stops', () async {
        device.viewFinderCodes.add(PtpResponseCode.generalError);
        final live = loop();
        final events = live.frames.toList();
        await live.start();

        await expectLater(
          events.timeout(_frameDeadline),
          throwsA(
            isA<PtpResponseException>().having(
              (e) => e.responseCode,
              'responseCode',
              PtpResponseCode.generalError,
            ),
          ),
        );
        await live.stop();
        expect(live.errorCount, 1);
        expect(
          device.canonProperties[CanonEosProperty.evfOutputDevice],
          CanonEvfOutput.tft,
        );
      });

      test('a disconnect surfaces and stopping swallows the restore', () async {
        final live = loop();
        final events = live.frames.toList();
        await live.start();
        disconnect();

        await expectLater(events.timeout(_frameDeadline), throwsA(anything));
        await live.stop();
        expect(live.errorCount, 1);
        expect(
          device.canonProperties[CanonEosProperty.evfOutputDevice],
          CanonEvfOutput.pc,
        );
      });

      test('start fails and stops when the camera is gone', () async {
        disconnect();
        await Future<void>.delayed(Duration.zero);
        final live = loop();
        final frames = live.frames.toList();

        await expectLater(live.start(), throwsA(anything));
        expect(live.errorCount, 1);
        expect(await frames, isEmpty);
      });

      test('a minimum frame interval caps the frame rate', () async {
        device.liveViewFrames.addAll(_frames());
        final live = loop(minFrameInterval: _frameInterval);
        final clock = Stopwatch()..start();
        final arrivals = <Duration>[];
        final done = live.frames
            .take(_frameCount)
            .forEach((_) => arrivals.add(clock.elapsed));
        await live.start();
        await done.timeout(_frameDeadline);

        for (var i = 1; i < arrivals.length; i++) {
          expect(
            arrivals[i] - arrivals[i - 1],
            greaterThanOrEqualTo(_frameInterval - _timerSlack),
          );
        }
      });
    });
  }

  test('start twice is a state error', () async {
    final (:device, :session, disconnect: _) = await _overUsb();
    final live = CanonLiveViewLoop(session)..frames.listen(null);
    addTearDown(live.stop);
    await live.start();

    expect(live.start, throwsStateError);
    expect(device.canonPropertyPayloads, hasLength(2));
  });

  group('canonViewFinderJpegs', () {
    final jpeg = patternBytes(_frameSize);

    test('returns every JPEG record and skips the others', () {
      final data = Uint8List.fromList([
        ...viewFinderRecord(fakeViewFinderInfoRecordType, Uint8List(4)),
        ...viewFinderRecord(CanonViewFinder.jpegRecordType, jpeg),
        ...viewFinderRecord(CanonViewFinder.jpegRecordType, jpeg),
      ]);
      expect(canonViewFinderJpegs(data), [jpeg, jpeg]);
    });

    test('stops at a malformed record', () {
      final good = viewFinderRecord(CanonViewFinder.jpegRecordType, jpeg);
      final truncated = viewFinderRecord(
        CanonViewFinder.jpegRecordType,
        jpeg,
      ).sublist(0, _frameSize ~/ 2);
      final tooShort = Uint8List(8)..[0] = 4;

      expect(
        canonViewFinderJpegs(Uint8List.fromList([...good, ...truncated])),
        [jpeg],
      );
      expect(canonViewFinderJpegs(Uint8List.fromList([...good, ...tooShort])), [
        jpeg,
      ]);
      expect(canonViewFinderJpegs(Uint8List(0)), isEmpty);
    });
  });
}
