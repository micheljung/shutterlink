import 'package:flutter_bloc/flutter_bloc.dart';

import 'operating_mode.dart';

/// The active mode; null while the picker shows. It outlives camera
/// clients, so a reconnect keeps the mode.
class ModeCubit extends Cubit<OperatingMode?> {
  ModeCubit() : super(null);

  bool _leftForConnectionLoss = false;

  /// The last mode ended because the camera was lost, not because the user
  /// left it.
  bool get leftForConnectionLoss => _leftForConnectionLoss;

  void select(OperatingMode mode) {
    _leftForConnectionLoss = false;
    emit(mode);
  }

  /// Back to the picker. Queued uploads keep draining.
  void leave() {
    _leftForConnectionLoss = false;
    emit(null);
  }

  /// The camera is gone, so the mode ends without the user asking. A mode
  /// the user already left stays left by the user.
  void connectionLost() {
    if (state == null) return;
    _leftForConnectionLoss = true;
    emit(null);
  }
}
