import 'package:equatable/equatable.dart';

import '../ptpip/camera_client.dart';

/// Which files may be uploaded over metered (mobile) data.
enum MobileDataPolicy { off, jpeg, all }

enum NetworkTransport { wifi, cellular, other }

class NetworkInfo extends Equatable {
  const NetworkInfo({
    required this.transport,
    required this.validated,
    required this.metered,
  });

  final NetworkTransport transport;

  /// The system confirmed internet access, which a camera access point lacks.
  final bool validated;
  final bool metered;

  @override
  List<Object?> get props => [transport, validated, metered];
}

class NetworkStatus extends Equatable {
  const NetworkStatus(this.networks);

  /// For platforms that route uploads themselves and enforce no policy.
  const NetworkStatus.unrestricted()
    : networks = const [
        NetworkInfo(
          transport: NetworkTransport.other,
          validated: true,
          metered: false,
        ),
      ];

  static const offline = NetworkStatus([]);

  final List<NetworkInfo> networks;

  /// Includes the Wi-Fi the camera is bound to in infrastructure mode.
  bool get hasUnmeteredInternet =>
      networks.any((network) => network.validated && !network.metered);

  bool get hasMeteredInternet =>
      networks.any((network) => network.validated && network.metered);

  @override
  List<Object?> get props => [networks];
}

enum WaitReason {
  noDestination,

  /// No internet at all.
  network,

  /// Mobile data is available but the policy excludes this file.
  unmeteredNetwork,
  backoff,

  /// A permanent error that needs the user, e.g. rejected credentials.
  attention,
}

sealed class NetworkDecision {
  const NetworkDecision();
}

class UploadAllowed extends NetworkDecision {
  const UploadAllowed({required this.metered});

  final bool metered;
}

class UploadWaits extends NetworkDecision {
  const UploadWaits(this.reason);

  final WaitReason reason;
}

NetworkDecision decideNetwork(
  NetworkStatus status,
  MobileDataPolicy policy,
  CameraObjectKind kind,
) {
  if (status.hasUnmeteredInternet) return const UploadAllowed(metered: false);
  final policyAllows = switch (policy) {
    MobileDataPolicy.off => false,
    MobileDataPolicy.jpeg => kind == CameraObjectKind.jpeg,
    MobileDataPolicy.all => true,
  };
  if (status.hasMeteredInternet) {
    return policyAllows
        ? const UploadAllowed(metered: true)
        : const UploadWaits(WaitReason.unmeteredNetwork);
  }
  return const UploadWaits(WaitReason.network);
}
