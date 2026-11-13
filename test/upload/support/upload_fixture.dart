import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shutterlink/upload/storage_backend.dart';

Uint8List bytesOf(int length, {int seed = 0}) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + seed) & 0xff));

String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();

Future<UploadRequest> uploadRequest(
  Directory tmp,
  List<int> bytes, {
  String directory = '2026-11-13',
  String name = 'IMG_0001.JPG',
  String tempName = '.IMG_0001.JPG.tmp-fixed',
}) async {
  final file = File('${tmp.path}/$name');
  await file.writeAsBytes(bytes);
  return UploadRequest(
    source: file,
    target: RemoteTarget(directory: directory, name: name),
    tempName: tempName,
    size: bytes.length,
    sha256: sha256Of(bytes),
  );
}

/// SHA-256 fingerprint of the self-signed test certificate, computed
/// independently of the production helper.
Future<String> testCertificateFingerprint() async {
  final pem = await File('test/upload/support/certs/cert.pem').readAsString();
  final body = pem
      .split('\n')
      .where((l) => l.isNotEmpty && !l.startsWith('-----'))
      .join();
  return sha256
      .convert(base64Decode(body))
      .bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}

/// A port nothing listens on.
Future<int> closedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
