import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../upload/backend_factory.dart';
import '../upload/destination.dart';
import '../upload/network_policy.dart';

/// The upload destination: plain settings in [SharedPreferences], secrets and
/// trust pins in [FlutterSecureStorage].
class DestinationRepository {
  DestinationRepository(
    this._prefs, {
    this._secureStorage = defaultSecureStorage,
  });

  /// A Keystore that cannot decrypt (e.g. after a restore) resets instead of
  /// failing every read.
  static const defaultSecureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: true),
  );

  static const typeKey = 'upload_type';
  static const endpointKey = 'upload_endpoint';
  static const regionKey = 'upload_region';
  static const bucketKey = 'upload_bucket';
  static const basePathKey = 'upload_base_path';
  static const pathStyleKey = 'upload_path_style';
  static const usernameKey = 'upload_username';
  static const policyKey = 'upload_mobile_data_policy';
  static const keepLocalCopyKey = 'upload_keep_local_copy';
  static const secretsKey = 'upload_secrets';
  static const _fingerprintField = 'fingerprint';

  static const _prefKeys = [
    typeKey,
    endpointKey,
    regionKey,
    bucketKey,
    basePathKey,
    pathStyleKey,
    usernameKey,
    policyKey,
    keepLocalCopyKey,
  ];

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secureStorage;
  final _changes = StreamController<Destination?>.broadcast();

  /// Emits after every [save] and [remove]; feed it to
  /// `UploadQueue.setDestination` so pending items are re-targeted.
  Stream<Destination?> get changes => _changes.stream;

  Destination? get destination {
    final typeName = _prefs.getString(typeKey);
    final type = DestinationType.values
        .where((type) => type.name == typeName)
        .firstOrNull;
    final endpoint = _prefs.getString(endpointKey);
    if (type == null || endpoint == null) return null;
    final policyName = _prefs.getString(policyKey);
    return Destination(
      type: type,
      endpoint: endpoint,
      region: _prefs.getString(regionKey) ?? '',
      bucket: _prefs.getString(bucketKey) ?? '',
      basePath: _prefs.getString(basePathKey) ?? '',
      username: _prefs.getString(usernameKey) ?? '',
      pathStyle: _prefs.getBool(pathStyleKey) ?? false,
      policy: MobileDataPolicy.values.firstWhere(
        (policy) => policy.name == policyName,
        orElse: () => MobileDataPolicy.off,
      ),
      keepLocalCopy: _prefs.getBool(keepLocalCopyKey) ?? true,
    );
  }

  /// Throws [CredentialsMissingException] when the secrets are unreadable or
  /// belong to another destination; unreadable ones are wiped.
  Future<DestinationSecrets> readSecrets() async {
    final fingerprint = destination?.fingerprint;
    final String? raw;
    try {
      raw = await _secureStorage.read(key: secretsKey);
    } on Object {
      await _wipeSecrets();
      throw const CredentialsMissingException();
    }
    if (raw == null || fingerprint == null) {
      throw const CredentialsMissingException();
    }
    try {
      final json = jsonDecode(raw) as Map<String, Object?>;
      if (json[_fingerprintField] != fingerprint) {
        throw const CredentialsMissingException();
      }
      return DestinationSecrets.fromJson(json);
    } on TypeError {
      await _wipeSecrets();
      throw const CredentialsMissingException();
    } on FormatException {
      await _wipeSecrets();
      throw const CredentialsMissingException();
    }
  }

  /// Replaces any previous destination and its secrets.
  Future<void> save(Destination destination, DestinationSecrets secrets) async {
    await _secureStorage.write(
      key: secretsKey,
      value: jsonEncode({
        _fingerprintField: destination.fingerprint,
        ...secrets.toJson(),
      }),
    );
    await Future.wait([
      _prefs.setString(typeKey, destination.type.name),
      _prefs.setString(endpointKey, destination.endpoint),
      _prefs.setString(regionKey, destination.region),
      _prefs.setString(bucketKey, destination.bucket),
      _prefs.setString(basePathKey, destination.basePath),
      _prefs.setBool(pathStyleKey, destination.pathStyle),
      _prefs.setString(usernameKey, destination.username),
      _prefs.setString(policyKey, destination.policy.name),
      _prefs.setBool(keepLocalCopyKey, destination.keepLocalCopy),
    ]);
    _changes.add(destination);
  }

  Future<void> remove() async {
    await Future.wait(_prefKeys.map(_prefs.remove));
    await _wipeSecrets();
    _changes.add(null);
  }

  Future<void> _wipeSecrets() async {
    try {
      await _secureStorage.delete(key: secretsKey);
    } on Object {
      // Nothing more to do; the next save overwrites the entry.
    }
  }

  Future<void> close() => _changes.close();
}
