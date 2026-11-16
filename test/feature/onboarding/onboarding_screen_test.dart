import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/brand/brand_theme.dart';
import 'package:shutterlink/feature/onboarding/onboarding_screen.dart';

void main() {
  late List<String> platformCalls;

  Future<void> pumpOnboarding(WidgetTester tester) async {
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
        home: OnboardingScreen(onDone: () {}),
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
}
