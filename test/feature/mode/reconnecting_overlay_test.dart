import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/connect/connect_state.dart';
import 'package:shutterlink/feature/mode/reconnecting_overlay.dart';

void main() {
  Future<void> pumpOverlay(WidgetTester tester, ConnectReconnecting state) =>
      tester.pumpWidget(MaterialApp(home: ReconnectingOverlay(state: state)));

  testWidgets('a camera that does not answer asks for a power-cycle', (
    tester,
  ) async {
    await pumpOverlay(
      tester,
      const ConnectReconnecting(
        notResponding: true,
        unreachable: true,
        usb: true,
      ),
    );

    expect(find.text(ReconnectingOverlay.notRespondingText), findsOneWidget);
    expect(find.text(ReconnectingOverlay.unreachableText), findsNothing);
  });

  testWidgets('a reconnecting USB camera just reconnects', (tester) async {
    await pumpOverlay(tester, const ConnectReconnecting(usb: true));

    expect(find.text(ReconnectingOverlay.reconnectingText), findsOneWidget);
    expect(find.text(ReconnectingOverlay.notRespondingText), findsNothing);
  });
}
