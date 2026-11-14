import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'storage_backend.dart';

const responseTimeout = Duration(seconds: 60);

/// S3 answers 403 with this code for a wrong region or endpoint as well as
/// for a wrong secret, so it is not reported as a sign-in failure.
const _signatureMismatch = 'SignatureDoesNotMatch';

class HttpResult {
  const HttpResult(this.status, this.headers, this.body);

  final int status;
  final HttpHeaders headers;
  final String body;

  bool get ok => status >= 200 && status < 300;
}

/// Sends one request and reads the whole response. Transport failures become
/// readable [StorageException]s.
Future<HttpResult> sendHttp(
  HttpClient client,
  String method,
  Uri uri, {
  Map<String, String> headers = const {},
  List<int>? body,
  File? file,
  int? fileLength,
  UploadProgress? onProgress,
}) async {
  try {
    final request = await client.openUrl(method, uri);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    if (file != null) {
      final total = fileLength ?? await file.length();
      request.contentLength = total;
      var sent = 0;
      await request.addStream(
        file.openRead().map((chunk) {
          sent += chunk.length;
          onProgress?.call(sent, total);
          return chunk;
        }),
      );
    } else {
      request.contentLength = body?.length ?? 0;
      if (body != null) request.add(body);
    }
    final response = await request.close().timeout(responseTimeout);
    final text = await utf8.decoder
        .bind(response)
        .join()
        .timeout(responseTimeout);
    return HttpResult(response.statusCode, response.headers, text);
  } on StorageException {
    rethrow;
  } on SocketException catch (e) {
    throw networkException(e, uri.host);
  } on HandshakeException catch (e) {
    throw StorageException(
      'Secure connection to ${uri.host} failed: ${e.message}',
      retryable: false,
    );
  } on HttpException {
    throw StorageException('The connection to ${uri.host} was interrupted.');
  } on TimeoutException {
    throw StorageException('${uri.host} did not respond in time.');
  }
}

StorageException networkException(SocketException e, String host) {
  if (e.message.contains('host lookup') ||
      e.osError?.message.contains('address associated') == true) {
    return StorageException(
      'Server $host not found. Check the address and the internet '
      'connection.',
    );
  }
  final reason = e.osError?.message ?? e.message;
  return StorageException('Connection to $host failed: $reason');
}

/// [what] names the resource, e.g. "The base folder".
StorageException statusException(int status, String what, {String? detail}) {
  final suffix = detail == null || detail.isEmpty ? '' : ' ($detail)';
  return switch (status) {
    401 => AuthenticationException('Wrong username or password$suffix.'),
    403 when detail == _signatureMismatch => StorageException(
      'Access denied$suffix. Check the secret key, region and endpoint.',
      retryable: false,
    ),
    403 => AuthenticationException('Access denied$suffix.'),
    404 => StorageException('$what was not found$suffix.', retryable: false),
    408 ||
    429 ||
    >= 500 => StorageException('The server reported error $status$suffix.'),
    _ => StorageException(
      'Unexpected server response $status$suffix.',
      retryable: false,
    ),
  };
}
