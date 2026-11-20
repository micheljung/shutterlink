import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/feature/intervalometer/camera_pairing_sheet.dart';
import 'package:shutterlink/feature/intervalometer/interval_presets.dart';
import 'package:shutterlink/feature/intervalometer/intervalometer_cubit.dart';
import 'package:shutterlink/feature/intervalometer/intervalometer_entry_card.dart';
import 'package:shutterlink/feature/intervalometer/intervalometer_run_view.dart';
import 'package:shutterlink/feature/intervalometer/intervalometer_screen.dart';
import 'package:shutterlink/feature/intervalometer/intervalometer_text.dart';
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

  Future<void> startClouds(WidgetTester tester) async {
    await pair(tester);
    await tester.tap(find.text(IntervalPreset.clouds.label));
    await tester.pump();
    await tester.tap(
      find.widgetWithText(FilledButton, IntervalometerScreen.startLabel),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(IntervalometerRunView), findsOneWidget);
  }

  Future<void> pressBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('back during a run can stop it', (tester) async {
    await openIntervalometer(tester);
    await startClouds(tester);

    await pressBack(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(IntervalometerScreen), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(IntervalometerRunView.stopLabel),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(IntervalometerScreen), findsNothing);
    expect(find.text(IntervalometerEntryCard.subtitle), findsOneWidget);
  });

  testWidgets('back during a run can leave it shooting', (tester) async {
    await openIntervalometer(tester);
    await startClouds(tester);

    await pressBack(tester);
    await tester.tap(find.text(IntervalometerScreen.backgroundLabel));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(IntervalometerScreen), findsNothing);
    expect(find.textContaining('Running · shot'), findsOneWidget);

    // The run outlives the screen; end it so no timer is left.
    await tester
        .element(find.byType(IntervalometerEntryCard))
        .read<IntervalometerCubit>()
        .stop();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('waits for the pairing to be confirmed before shooting', (
    tester,
  ) async {
    final bluetooth = await openIntervalometer(tester);
    await pair(tester);
    bluetooth.remote.setLink(RemoteLink.pairing);
    await tester.pump();
    await tester.pump();
    expect(find.text(IntervalometerText.pairingText), findsOneWidget);
    final start = find.widgetWithText(
      FilledButton,
      IntervalometerScreen.startLabel,
    );
    expect(tester.widget<FilledButton>(start).onPressed, isNull);

    bluetooth.remote.setLink(RemoteLink.connected);
    await tester.pump();
    await tester.pump();
    expect(find.text('Ready to shoot'), findsOneWidget);
  });

  testWidgets('a camera that refuses the phone leads to pairing again', (
    tester,
  ) async {
    final bluetooth = await openIntervalometer(tester);
    await pair(tester);
    bluetooth.remote.setLink(RemoteLink.refused);
    await tester.pump();
    await tester.pump();
    expect(find.text(IntervalometerText.refusedTitle), findsOneWidget);
    for (final step in IntervalometerText.refusedSteps) {
      expect(find.textContaining(step), findsOneWidget);
    }

    final pairAgain = find.text(IntervalometerText.pairAgainLabel);
    await tester.ensureVisible(pairAgain);
    await tester.pump();
    await tester.tap(pairAgain);
    await tester.pumpAndSettle();
    expect(find.text(CameraPairingSheet.cameraSteps.first), findsOneWidget);
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

  testWidgets('a failed pick stops that camera reconnecting', (tester) async {
    final bluetooth = await openIntervalometer(tester);
    bluetooth.remote.connectError = const RemoteException('Refused.');
    await tester.tap(find.text(IntervalometerScreen.pairLabel));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(camera.name));
    await tester.pump();
    await tester.tap(find.text(camera.name));
    await tester.pumpAndSettle();
    expect(find.text(CameraPairingSheet.failedText), findsOneWidget);
    expect(bluetooth.remote.events, ['connect', 'disconnect']);
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
