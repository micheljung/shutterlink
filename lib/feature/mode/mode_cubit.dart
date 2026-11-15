import 'package:flutter_bloc/flutter_bloc.dart';

import 'operating_mode.dart';

/// The active mode; null while the picker shows. It outlives camera
/// clients, so a reconnect keeps the mode.
class ModeCubit extends Cubit<OperatingMode?> {
  ModeCubit() : super(null);

  void select(OperatingMode mode) => emit(mode);

  /// Back to the picker. Queued uploads keep draining.
  void leave() => emit(null);
}
