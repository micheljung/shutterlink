import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/live_view_probe/live_view_probe_screen.dart';
import 'package:shutterlink/ptp/camera_profile.dart';
import 'package:shutterlink/ptp/canon/canon_constants.dart';
import 'package:shutterlink/ptp/canon/canon_live_view.dart';
import 'package:shutterlink/ptp/ptp_camera_client.dart';
import 'package:shutterlink/usb/usb_camera_client.dart';
import 'package:shutterlink/usb/usb_pipe.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_usb_pipe.dart';
import '../../ptpip/fake_camera.dart';

const _pollInterval = Duration(milliseconds: 10);
const _fakeStep = Duration(milliseconds: 20);
const _maxPolls = 500;
const _frameCount = 50;
const _frameSide = 8;
const _nativeMicros = 100;
const _shutdownPumps = 3;

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, _frameSide * 1.0, _frameSide * 1.0),
    Paint()..color = Colors.red,
  );
  final image = await recorder.endRecording().toImage(_frameSide, _frameSide);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < _maxPolls && !condition(); i++) {
      await tester.runAsync(() => Future<void>.delayed(_pollInterval));
      await tester.pump(_fakeStep);
    }
    expect(condition(), isTrue);
  }

  bool rendered(WidgetTester tester) =>
      tester.widget<RawImage>(find.byType(RawImage)).image != null;

  group('on a Canon over USB', () {
    late FakePtpDevice device;
    late FakeUsbPipe pipe;
    late PtpCameraClient client;

    setUp(() {
      device = FakePtpDevice();
    });

    Future<void> connect(WidgetTester tester) async {
      await tester.runAsync(() async {
        client = await connectUsb(
          BulkLink(pipe = FakeUsbPipe(device, nativeMicros: _nativeMicros)),
          responseTimeout: testResponseTimeout,
          options: const ProfileOptions(eventPollInterval: testPollInterval),
        );
        final frame = await _png();
        device.liveViewFrames.addAll(List.filled(_frameCount, frame));
      });
    }

    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < _shutdownPumps; i++) {
        await tester.runAsync(() => Future<void>.delayed(_pollInterval));
        await tester.pump(canonLiveViewMaxBackoff);
      }
      await tester.runAsync(client.close);
    }

    testWidgets('renders frames, shows the stats and owns the timing tap', (
      tester,
    ) async {
      await connect(tester);
      await tester.pumpWidget(
        MaterialApp(home: LiveViewProbe(client: client, usb: true)),
      );

      await pumpUntil(tester, () => rendered(tester));
      await pumpUntil(
        tester,
        () =>
            find.textContaining('Frame     ').evaluate().isNotEmpty &&
            !find.textContaining('Frame     -').evaluate().isNotEmpty,
      );

      expect(find.textContaining('Transport USB'), findsOneWidget);
      expect(find.textContaining('TTFB      mean'), findsOneWidget);
      expect(find.textContaining('Overhead  mean'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
      expect(
        device.canonProperties[CanonEosProperty.evfOutputDevice],
        CanonEvfOutput.pc,
      );
      expect(
        () => client.session.onTiming = (_, _) {},
        throwsA(isA<AssertionError>()),
      );

      await unmount(tester);

      client.session.onTiming = (_, _) {};
      client.session.onTiming = null;
    });

    testWidgets('a session timeout counts as a watchdog abort', (tester) async {
      await connect(tester);
      await tester.pumpWidget(
        MaterialApp(home: LiveViewProbe(client: client, usb: true)),
      );
      await pumpUntil(tester, () => rendered(tester));

      pipe.hang = true;
      await pumpUntil(
        tester,
        () => find.textContaining('Watchdog  1').evaluate().isNotEmpty,
      );

      expect(find.text('Start'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('the EVF output toggle restarts live view on 3', (
      tester,
    ) async {
      await connect(tester);
      await tester.pumpWidget(
        MaterialApp(home: LiveViewProbe(client: client, usb: true)),
      );
      await pumpUntil(tester, () => rendered(tester));

      await tester.tap(find.text('EVF ${CanonEvfOutput.tftAndPc}'));
      await pumpUntil(
        tester,
        () =>
            device.canonProperties[CanonEosProperty.evfOutputDevice] ==
            CanonEvfOutput.tftAndPc,
      );

      expect(find.textContaining('EVF out   3'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('Stop hands the viewfinder back to the camera', (tester) async {
      await connect(tester);
      await tester.pumpWidget(
        MaterialApp(home: LiveViewProbe(client: client, usb: true)),
      );
      await pumpUntil(tester, () => rendered(tester));

      await tester.tap(find.text('Stop'));
      await pumpUntil(tester, () => find.text('Start').evaluate().isNotEmpty);
      await pumpUntil(
        tester,
        () =>
            device.canonProperties[CanonEosProperty.evfOutputDevice] ==
            CanonEvfOutput.tft,
      );
      await unmount(tester);
    });
  });

  testWidgets('a camera that is not a Canon over PTP shows a message', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LiveViewProbe(client: FakeCameraClient([]), usb: false),
      ),
    );

    expect(find.text(LiveViewProbe.notCanonText), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
