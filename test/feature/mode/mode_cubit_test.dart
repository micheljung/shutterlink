import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/mode/mode_cubit.dart';
import 'package:shutterlink/feature/mode/operating_mode.dart';

void main() {
  test('starts on the picker', () => expect(ModeCubit().state, isNull));

  blocTest<ModeCubit, OperatingMode?>(
    'selects a mode and leaves it for the picker',
    build: ModeCubit.new,
    act: (cubit) => cubit
      ..select(OperatingMode.browse)
      ..leave()
      ..select(OperatingMode.liveShare),
    expect: () => [OperatingMode.browse, null, OperatingMode.liveShare],
  );

  group('connection loss', () {
    late ModeCubit modes;

    setUp(() => modes = ModeCubit());
    tearDown(() => modes.close());

    test('a lost camera ends the mode, and says so', () {
      modes
        ..select(OperatingMode.liveShare)
        ..connectionLost();

      expect(modes.state, isNull);
      expect(modes.leftForConnectionLoss, isTrue);
    });

    test(
      'a mode the user left stays left by the user when the camera goes',
      () {
        modes
          ..select(OperatingMode.liveShare)
          ..leave()
          ..connectionLost();

        expect(modes.leftForConnectionLoss, isFalse);
      },
    );

    test('picking a mode clears a connection loss', () {
      modes
        ..select(OperatingMode.liveShare)
        ..connectionLost()
        ..select(OperatingMode.browse);

      expect(modes.leftForConnectionLoss, isFalse);
    });
  });
}
