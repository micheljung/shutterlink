import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shutterlink_server/src/app.dart';
import 'package:shutterlink_server/src/tips.dart';

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

const String uploadToken = 'secret-upload-token';
final Uri origin = Uri.parse('http://localhost/');

Request putRequest(
  String code,
  String key,
  List<int> bytes, {
  String? token = uploadToken,
  bool withLength = true,
}) => Request(
  'PUT',
  origin.resolve('/api/sessions/$code/photos/$key'),
  body: chunked(bytes),
  headers: {
    if (token != null) 'authorization': 'Bearer $token',
    if (withLength) 'content-length': '${bytes.length}',
  },
);

Request getRequest(String path) => Request('GET', origin.resolve(path));

Future<List<int>> bodyBytes(Response response) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response.read()) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<String> bodyText(Response response) async =>
    utf8.decode(await bodyBytes(response));

Future<Map<String, Object?>> bodyJson(Response response) async =>
    jsonDecode(await bodyText(response)) as Map<String, Object?>;

class TestApp {
  TestApp._(this.dataDir, this.now, this.app);

  static Future<TestApp> open({
    List<Tip> tips = const [],
    int maxPhotoBytes = 4096,
    int maxSessionBytes = 1 << 20,
    int zipConcurrency = 2,
    Duration zipQueueTimeout = const Duration(seconds: 5),
    Duration zipIdleTimeout = const Duration(seconds: 5),
  }) async {
    final dataDir = await tempDataDir();
    final now = MutableClockSource(t0);
    final app = await ShutterlinkApp.open(
      dataDir: dataDir,
      uploadToken: uploadToken,
      tips: tips,
      clock: Clock(now.call),
      maxPhotoBytes: maxPhotoBytes,
      maxSessionBytes: maxSessionBytes,
      zipConcurrency: zipConcurrency,
      zipQueueTimeout: zipQueueTimeout,
      zipIdleTimeout: zipIdleTimeout,
    );
    return TestApp._(dataDir, now, app);
  }

  final Directory dataDir;
  final MutableClockSource now;
  final ShutterlinkApp app;

  Future<Response> call(Request request) async => app.handler(request);

  Future<Response> upload(String code, List<int> bytes) =>
      call(putRequest(code, keyOf(bytes), bytes));

  Future<Response> get(String path) => call(getRequest(path));

  Future<void> close() => dataDir.delete(recursive: true);
}
