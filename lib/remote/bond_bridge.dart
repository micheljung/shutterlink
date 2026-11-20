import 'dart:async';

import 'package:flutter/services.dart';

enum BondState { none, bonding, bonded }

/// The phone's Bluetooth bond with a camera, which Android has the user
/// confirm. The camera takes remote buttons only once it is in place.
abstract interface class BondBridge {
  Future<BondState> bondState(String address);

  /// Asks Android to bond; the user confirms in a dialog or notification.
  Future<void> createBond(String address);

  /// The bond's changes from now on.
  Stream<BondState> bondStates(String address);
}

/// For platforms that bond by themselves, such as iOS.
class NoBondBridge implements BondBridge {
  const NoBondBridge();

  @override
  Future<BondState> bondState(String address) async => BondState.bonded;

  @override
  Future<void> createBond(String address) async {}

  @override
  Stream<BondState> bondStates(String address) => const Stream.empty();
}

class AndroidBondBridge implements BondBridge {
  AndroidBondBridge();

  static const channel = MethodChannel('ch.micheljung.shutterlink/bond');
  static const eventsChannel = EventChannel(
    'ch.micheljung.shutterlink/bond_states',
  );

  /// One platform listener, shared: a second would replace the first.
  late final Stream<Map<Object?, Object?>> _events = eventsChannel
      .receiveBroadcastStream()
      .map((event) => event as Map<Object?, Object?>)
      .asBroadcastStream();

  static BondState _parse(Object? state) => switch (state) {
    'bonded' => BondState.bonded,
    'bonding' => BondState.bonding,
    _ => BondState.none,
  };

  @override
  Future<BondState> bondState(String address) async {
    try {
      final state = await channel.invokeMethod<String>('bondState', {
        'address': address,
      });
      return _parse(state);
    } on MissingPluginException {
      return BondState.bonded;
    } on PlatformException {
      // Unknown to Android: the connect fails on its own and is retried.
      return BondState.bonded;
    }
  }

  @override
  Future<void> createBond(String address) async {
    await channel.invokeMethod<bool>('createBond', {'address': address});
  }

  @override
  Stream<BondState> bondStates(String address) => _events
      .where(
        (event) =>
            (event['address'] as String?)?.toUpperCase() ==
            address.toUpperCase(),
      )
      .map((event) => _parse(event['state']));
}
