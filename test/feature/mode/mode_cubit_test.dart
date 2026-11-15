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
      ..select(OperatingMode.qrSession),
    expect: () => [OperatingMode.browse, null, OperatingMode.qrSession],
  );
}
