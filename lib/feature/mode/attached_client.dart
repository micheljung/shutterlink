import 'package:flutter/widgets.dart';

import '../../ptpip/camera_client.dart';

/// The camera client the active mode may call; null while reconnecting, when
/// the mode's old client is dead.
class AttachedClient extends InheritedWidget {
  const AttachedClient({super.key, required this.client, required super.child});

  final CameraClient? client;

  /// Whether [client] may be called from [context]. Outside a mode host it
  /// always may.
  static bool allows(BuildContext context, CameraClient client) {
    final scope = context.getInheritedWidgetOfExactType<AttachedClient>();
    return scope == null || scope.client == client;
  }

  @override
  bool updateShouldNotify(AttachedClient oldWidget) =>
      client != oldWidget.client;
}
