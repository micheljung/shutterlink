import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/feature/intervalometer/camera_pairing_sheet.dart';
import 'package:shutterlink/feature/intervalometer/interval_presets.dart';
import 'package:shutterlink/feature/intervalometer/intervalometer_entry_card.dart';
import 'package:shutterlink/feature/intervalometer/intervalometer_run_view.dart';
import 'package:shutterlink/feature/intervalometer/intervalometer_screen.dart';
import 'package:shutterlink/feature/intervalometer/plan_editor.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/remote/shutter_remote.dart';

import '../../fakes/fake_shutter_remote.dart';
import '../../fakes/test_app.dart';

void main() {
  const camera = RemoteCamera(id: 'AA:BB', name: 'EOS R6');

  Future<FakeRemoteBluetooth> openIntervalometer(WidgetTester tester) async {
    final bluetooth = FakeRemoteBluetooth(cameras: const [camera]);
    final dependencies = await testDependencies(
      (_) => throw const PairingRequiredException(),
      remoteBluetooth: bluetooth,
    );
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await tester.tap(find.byType(IntervalometerEntryCard));
    await tester.pumpAndSettle();
    return bluetooth;
  }

  Future<void> pair(WidgetTester tester) async {
    await tester.tap(find.text(IntervalometerScreen.pairLabel));
    await tester.pumpAndSettle();
    expect(find.text(CameraPairingSheet.cameraSteps.first), findsOneWidget);
    await tester.ensureVisible(find.text(camera.name));
    await tester.pump();
    await tester.tap(find.text(camera.name));
    await tester.pumpAndSettle();
    expect(find.text(CameraPairingSheet.confirmTitle), findsOneWidget);
    await tester.tap(find.text(CameraPairingSheet.doneLabel));
    await tester.pumpAndSettle();
  }

  testWidgets('pairs a camera, runs a preset and stops it', (tester) async {
    final bluetooth = await openIntervalometer(tester);
    final start = find.widgetWithText(
      FilledButton,
      IntervalometerScreen.startLabel,
    );
    expect(tester.widget<FilledButton>(start).onPressed, isNull);

    await pair(tester);
    expect(find.text('Ready to shoot'), findsOneWidget);

    await tester.tap(find.text(IntervalPreset.clouds.label));
    await tester.pump();
    await tester.tap(start);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(IntervalometerRunView), findsOneWidget);
    expect(find.text('of ${IntervalPreset.clouds.plan.shots}'), findsOneWidget);
    expect(bluetooth.remote.events, ['connect', 'shoot']);

    await tester.tap(find.text(IntervalometerRunView.stopLabel));
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(IntervalometerRunView.stopLabel),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Stopped'), findsOneWidget);
    await tester.tap(find.text(IntervalometerRunView.newRunLabel));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(PlanEditor), findsOneWidget);
  });

  testWidgets('bulb shows the gap and flags an interval that is too short', (
    tester,
  ) async {
    await openIntervalometer(tester);
    await tester.tap(find.text('Bulb'));
    await tester.pump();
    expect(find.text(PlanEditor.gapLabel), findsOneWidget);
    expect(find.text(PlanEditor.rampLabel), findsOneWidget);

    await tester.ensureVisible(find.text(PlanEditor.exposureLabel).first);
    await tester.pump();
    await tester.tap(find.text(PlanEditor.exposureLabel).first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '30 s'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    // The interval grew to fit, so nothing is flagged.
    expect(find.text('31 s'), findsOneWidget);
    expect(find.textContaining('Make the interval'), findsNothing);
  });

  testWidgets('the demo camera needs no Bluetooth', (tester) async {
    await openIntervalometer(tester);
    await tester.tap(find.text(IntervalometerScreen.pairLabel));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(CameraPairingSheet.demoLabel));
    await tester.pump();
    await tester.tap(find.text(CameraPairingSheet.demoLabel));
    await tester.pumpAndSettle();
    expect(find.text('Demo camera'), findsOneWidget);
    expect(find.text('Ready to shoot'), findsOneWidget);
  });
}
