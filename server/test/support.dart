import 'dart:io';

import 'package:crypto/crypto.dart';

const String codeA = 'apple-banana-cherry-delta';
const String codeB = 'eagle-falcon-grouse-heron';
const String unknownCode = 'iris-jasmine-kale-lotus';

final DateTime t0 = DateTime.utc(2026, 11, 13, 10);

class MutableClockSource {
  MutableClockSource(this.now);

  DateTime now;

  DateTime call() => now;
}

String keyOf(List<int> bytes) => sha256.convert(bytes).toString();

List<int> photoBytes(int seed, [int length = 1024]) =>
    List.generate(length, (i) => (i * 31 + seed) & 0xFF);

Stream<List<int>> chunked(List<int> bytes, [int chunkSize = 300]) async* {
  for (var i = 0; i < bytes.length; i += chunkSize) {
    yield bytes.sublist(
      i,
      i + chunkSize > bytes.length ? bytes.length : i + chunkSize,
    );
  }
}

Future<Directory> tempDataDir() =>
    Directory.systemTemp.createTemp('shutterlink_server_test');
