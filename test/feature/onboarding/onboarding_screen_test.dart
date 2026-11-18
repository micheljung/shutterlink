import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/brand/brand_theme.dart';
import 'package:shutterlink/feature/onboarding/onboarding_screen.dart';
import 'package:shutterlink/feature/onboarding/setup_steps.dart';
import 'package:shutterlink/usb/usb_camera_platform.dart';

void main() {
  late List<String> platformCalls;

  Future<void> pumpOnboarding(
    WidgetTester tester, {
    UsbSupport usbSupport = UsbSupport.none,
  }) async {
    platformCalls = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: BrandTheme.light(),
        home: OnboardingScreen(onDone: () {}, usbSupport: usbSupport),
      ),
    );
  }

  Future<void> pressBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  testWidgets('back on a later page goes to the previous page', (tester) async {
    await pumpOnboarding(tester);
    for (var page = 0; page < OnboardingScreen.pageCount - 1; page++) {
      await tester.tap(find.text(OnboardingScreen.nextLabel));
      await tester.pumpAndSettle();
    }
    expect(find.text(OnboardingScreen.phoneTitle), findsOneWidget);

    await pressBack(tester);
    expect(find.text(OnboardingScreen.progressText(1)), findsOneWidget);

    await pressBack(tester);
    expect(find.text(OnboardingScreen.progressText(0)), findsOneWidget);
    expect(platformCalls, isNot(contains('SystemNavigator.pop')));
  });

  testWidgets('back on the first page leaves the app', (tester) async {
    await pumpOnboarding(tester);

    await pressBack(tester);

    expect(platformCalls, contains('SystemNavigator.pop'));
  });

  Future<void> showPhonePage(WidgetTester tester, UsbSupport support) async {
    await pumpOnboarding(tester, usbSupport: support);
    for (var page = 0; page < OnboardingScreen.pageCount - 1; page++) {
      await tester.tap(find.text(OnboardingScreen.nextLabel));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('the phone page offers the cable where USB works', (
    tester,
  ) async {
    await showPhonePage(tester, UsbSupport.verified);
    await tester.ensureVisible(find.text(SetupSteps.usbReplug));

    expect(find.text(SetupSteps.usbFooterTitle), findsOneWidget);
    expect(find.text(SetupSteps.usbFooter), findsOneWidget);
    expect(find.text(SetupSteps.usbExperimentalLabel), findsNothing);
  });

  testWidgets('the phone page labels experimental USB', (tester) async {
    await showPhonePage(tester, UsbSupport.experimental);
    await tester.ensureVisible(find.text(SetupSteps.usbReplug));

    expect(find.text(SetupSteps.usbExperimentalLabel), findsOneWidget);
  });

  testWidgets('the phone page has no cable note without USB', (tester) async {
    await showPhonePage(tester, UsbSupport.none);

    expect(find.text(SetupSteps.usbFooterTitle), findsNothing);
  });
}
