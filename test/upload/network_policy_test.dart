import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/network_policy.dart';

void main() {
  const cameraAp = NetworkInfo(
    transport: NetworkTransport.wifi,
    validated: false,
    metered: false,
  );
  const infraWifi = NetworkInfo(
    transport: NetworkTransport.wifi,
    validated: true,
    metered: false,
  );
  const hotspot = NetworkInfo(
    transport: NetworkTransport.wifi,
    validated: true,
    metered: true,
  );
  const cellular = NetworkInfo(
    transport: NetworkTransport.cellular,
    validated: true,
    metered: true,
  );

  const jpeg = CameraObjectKind.jpeg;
  const raw = CameraObjectKind.raw;

  String outcome(NetworkDecision decision) => switch (decision) {
    UploadAllowed(metered: false) => 'unmetered',
    UploadAllowed(metered: true) => 'metered',
    UploadWaits(:final reason) => 'wait ${reason.name}',
  };

  final cases =
      <(String, List<NetworkInfo>, MobileDataPolicy, CameraObjectKind, String)>[
        (
          'camera AP only',
          [cameraAp],
          MobileDataPolicy.all,
          jpeg,
          'wait network',
        ),
        ('offline', [], MobileDataPolicy.all, raw, 'wait network'),
        (
          'validated infra Wi-Fi, policy off',
          [infraWifi],
          MobileDataPolicy.off,
          raw,
          'unmetered',
        ),
        (
          'infra Wi-Fi beats cellular',
          [infraWifi, cellular],
          MobileDataPolicy.all,
          raw,
          'unmetered',
        ),
        (
          'AP + cellular, off',
          [cameraAp, cellular],
          MobileDataPolicy.off,
          jpeg,
          'wait unmeteredNetwork',
        ),
        (
          'AP + cellular, jpeg, JPEG',
          [cameraAp, cellular],
          MobileDataPolicy.jpeg,
          jpeg,
          'metered',
        ),
        (
          'AP + cellular, jpeg, RAW',
          [cameraAp, cellular],
          MobileDataPolicy.jpeg,
          raw,
          'wait unmeteredNetwork',
        ),
        (
          'AP + cellular, all, RAW',
          [cameraAp, cellular],
          MobileDataPolicy.all,
          raw,
          'metered',
        ),
        (
          'metered hotspot, off',
          [hotspot],
          MobileDataPolicy.off,
          jpeg,
          'wait unmeteredNetwork',
        ),
        (
          'metered hotspot, all',
          [hotspot],
          MobileDataPolicy.all,
          raw,
          'metered',
        ),
        (
          'unvalidated cellular',
          [
            const NetworkInfo(
              transport: NetworkTransport.cellular,
              validated: false,
              metered: true,
            ),
          ],
          MobileDataPolicy.all,
          jpeg,
          'wait network',
        ),
      ];

  for (final (name, networks, policy, kind, expected) in cases) {
    test(name, () {
      expect(
        outcome(decideNetwork(NetworkStatus(networks), policy, kind)),
        expected,
      );
    });
  }

  test('unrestricted platforms always upload', () {
    expect(
      outcome(
        decideNetwork(
          const NetworkStatus.unrestricted(),
          MobileDataPolicy.off,
          raw,
        ),
      ),
      'unmetered',
    );
    expect(NetworkStatus.offline.hasUnmeteredInternet, isFalse);
  });
}
