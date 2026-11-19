import 'dart:async';
import 'dart:io';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

import 'canon_ble_protocol.dart';
import 'canon_ble_remote.dart';
import 'shutter_remote.dart';

enum BluetoothState {
  unknown,
  ready,
  off,

  /// Below Android 12, finding devices needs location switched on.
  locationOff,
  denied,
  unsupported,
}

/// The phone's Bluetooth, as far as remotes need it.
abstract interface class RemoteBluetooth {
  Stream<BluetoothState> get states;

  /// Asks for the permissions remotes need; whether they were granted.
  Future<bool> requestAccess();

  Future<void> openSettings();

  /// Cameras waiting to pair, growing as they are found.
  Stream<List<RemoteCamera>> scan();

  ShutterRemote remoteFor(RemoteCamera camera);
}

class BleRemoteBluetooth implements RemoteBluetooth {
  BleRemoteBluetooth({FlutterReactiveBle? ble, required this.remoteName})
    : _ble = ble ?? FlutterReactiveBle();

  final FlutterReactiveBle _ble;
  final String remoteName;

  @override
  Stream<BluetoothState> get states => _ble.statusStream.map(
    (status) => switch (status) {
      BleStatus.ready => BluetoothState.ready,
      BleStatus.poweredOff => BluetoothState.off,
      BleStatus.locationServicesDisabled => BluetoothState.locationOff,
      BleStatus.unauthorized => BluetoothState.denied,
      BleStatus.unsupported => BluetoothState.unsupported,
      BleStatus.unknown => BluetoothState.unknown,
    },
  );

  static const _bluetooth = [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
  ];

  @override
  Future<bool> requestAccess() async {
    // iOS asks by itself on first use; a refusal shows as denied.
    if (!Platform.isAndroid) return true;
    // Android 12 and later want the Bluetooth permissions, older versions
    // location. Each reports the permissions it does not use as denied.
    final statuses = await [..._bluetooth, Permission.location].request();
    bool granted(Permission permission) =>
        statuses[permission]?.isGranted ?? false;
    return _bluetooth.every(granted) || granted(Permission.location);
  }

  @override
  Future<void> openSettings() => openAppSettings();

  static const unnamedCamera = 'Canon camera';

  /// Anything nearby may advertise the camera's service; a flood of them
  /// must not grow the list without end.
  static const maxFound = 20;
  static const _maxNameLength = 32;
  static final _invisible = RegExp(
    '[\u0000-\u001F\u007F\u200E\u200F\u202A-\u202E\u2066-\u2069]',
  );

  /// The advertised name, without control or direction characters.
  static String cameraName(String advertised) {
    final clean = advertised.replaceAll(_invisible, '').trim();
    if (clean.isEmpty) return unnamedCamera;
    return String.fromCharCodes(clean.runes.take(_maxNameLength));
  }

  @override
  Stream<List<RemoteCamera>> scan() {
    final found = <String, RemoteCamera>{};
    return _ble
        .scanForDevices(
          withServices: [Uuid.parse(CanonBleProtocol.service)],
          scanMode: ScanMode.lowLatency,
        )
        .map((device) {
          if (found.length < maxFound || found.containsKey(device.id)) {
            found[device.id] = RemoteCamera(
              id: device.id,
              name: cameraName(device.name),
            );
          }
          return found.values.toList();
        });
  }

  @override
  ShutterRemote remoteFor(RemoteCamera camera) =>
      CanonBleRemote(_ble, camera, remoteName: remoteName);
}
