import 'dart:convert';
import 'dart:io';

import 'http_support.dart';
import 'remote_path.dart';
import 'storage_backend.dart';
import 'tcp_connector.dart';

const _propfindBody =
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:propfind xmlns:d="DAV:"><d:prop><d:getcontentlength/>'
    '<d:resourcetype/></d:prop></d:propfind>';

final _contentLength = RegExp(
  r'<(?:[A-Za-z0-9_-]+:)?getcontentlength[^>]*>\s*(\d+)\s*<',
);

class WebDavBackend implements StorageBackend {
  WebDavBackend({
    required this.endpoint,
    this.basePath = '',
    required this.username,
    required String password,
    TcpConnector connector = directConnector,
    String? pinnedCertificate,
  }) : _authorization =
           'Basic ${base64.encode(utf8.encode('$username:$password'))}',
       _client = httpClientFor(connector, pinnedCertificate: pinnedCertificate);

  final Uri endpoint;
  final String basePath;
  final String username;
  final String _authorization;
  final HttpClient _client;
  final _knownDirectories = <String>{};

  Uri _url(List<String> segments, {bool collection = false}) =>
      endpoint.replace(
        pathSegments: [
          ...endpoint.pathSegments.where((s) => s.isNotEmpty),
          ...pathSegments(basePath),
          ...segments,
          if (collection) '',
        ],
      );

  Uri _fileUrl(RemoteTarget target, String name) =>
      _url([...pathSegments(target.directory), name]);

  Future<HttpResult> _send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
    File? file,
    int? fileLength,
    UploadProgress? onProgress,
  }) => sendHttp(
    _client,
    method,
    uri,
    headers: {'Authorization': _authorization, ...headers},
    body: body,
    file: file,
    fileLength: fileLength,
    onProgress: onProgress,
  );

  /// `null` if [uri] does not exist; otherwise its size, or -1 for
  /// collections.
  Future<int?> _stat(Uri uri, String what) async {
    final result = await _send(
      'PROPFIND',
      uri,
      headers: {'Depth': '0', 'Content-Type': 'application/xml'},
      body: utf8.encode(_propfindBody),
    );
    if (result.status == 404) return null;
    if (!result.ok) throw statusException(result.status, what);
    final match = _contentLength.firstMatch(result.body);
    return match == null ? -1 : int.parse(match.group(1)!);
  }

  @override
  Future<void> testConnection() async {
    final size = await _stat(_url(const [], collection: true), 'Base folder');
    if (size == null) {
      throw const StorageException(
        'Base folder was not found.',
        retryable: false,
      );
    }
  }

  @override
  Future<ProbeResult> probe(
    RemoteTarget target, {
    required int size,
    required String sha256,
  }) async {
    final remoteSize = await _stat(_fileUrl(target, target.name), '$target');
    if (remoteSize == null) return ProbeResult.absent;
    return remoteSize == size ? ProbeResult.identical : ProbeResult.different;
  }

  @override
  Future<UploadResult> upload(
    UploadRequest request, {
    UploadProgress? onProgress,
  }) async {
    final target = request.target;
    final targetUrl = _fileUrl(target, target.name);
    final tempUrl = _fileUrl(target, request.tempName);

    final existing = await probe(
      target,
      size: request.size,
      sha256: request.sha256,
    );
    if (existing != ProbeResult.absent) {
      await _deleteQuietly(tempUrl);
      return _occupied(existing);
    }

    await _ensureDirectory(target.directory);
    final put = await _send(
      'PUT',
      tempUrl,
      headers: {'Content-Type': 'application/octet-stream'},
      file: request.source,
      fileLength: request.size,
      onProgress: onProgress,
    );
    if (!put.ok) {
      throw statusException(put.status, 'Folder ${target.directory}');
    }

    final move = await _send(
      'MOVE',
      tempUrl,
      headers: {'Destination': targetUrl.toString(), 'Overwrite': 'F'},
    );
    if (move.status == 412) {
      final occupied = await probe(
        target,
        size: request.size,
        sha256: request.sha256,
      );
      await _deleteQuietly(tempUrl);
      return _occupied(occupied);
    }
    if (!move.ok) throw statusException(move.status, '$target');

    final committed = await _stat(targetUrl, '$target');
    if (committed != request.size) {
      throw StorageException(
        'Uploaded $target has $committed bytes instead of ${request.size}.',
      );
    }
    return UploadResult.uploaded;
  }

  UploadResult _occupied(ProbeResult result) => result == ProbeResult.identical
      ? UploadResult.alreadyPresent
      : UploadResult.nameTaken;

  Future<void> _ensureDirectory(String directory) async {
    final segments = [...pathSegments(basePath), ...pathSegments(directory)];
    for (var i = 1; i <= segments.length; i++) {
      final path = segments.take(i).join('/');
      if (_knownDirectories.contains(path)) continue;
      final uri = endpoint.replace(
        pathSegments: [
          ...endpoint.pathSegments.where((s) => s.isNotEmpty),
          ...segments.take(i),
          '',
        ],
      );
      final result = await _send('MKCOL', uri);
      if (result.status != 201 &&
          result.status != 405 &&
          await _stat(uri, 'Folder $path') != -1) {
        throw statusException(result.status, 'Folder $path');
      }
      _knownDirectories.add(path);
    }
  }

  Future<void> _deleteQuietly(Uri uri) async {
    try {
      await _send('DELETE', uri);
    } on StorageException {
      // A leftover temp file is overwritten by the next attempt anyway.
    }
  }

  @override
  Future<void> close() async => _client.close(force: true);
}
