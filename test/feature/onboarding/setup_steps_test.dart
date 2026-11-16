import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/onboarding/setup_steps.dart';

void main() {
  final steps = SetupSteps.all.join('\n');

  test('every emphasised term occurs in the steps', () {
    for (final term in SetupSteps.emphasisTerms) {
      expect(steps, contains(term));
    }
  });

  test('every camera menu item occurs in the steps', () {
    for (final item in SetupSteps.cameraMenu) {
      expect(steps, contains(item));
    }
  });
}
