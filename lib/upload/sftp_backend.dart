import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'http_support.dart';
import 'remote_path.dart';
import 'storage_backend.dart';
import 'tcp_connector.dart';
import 'trust_pins.dart';

const _authTimeout = Duration(seconds: 30);

class _TunnelSshSocket implements SSHSocket {
  _TunnelSshSocket(this._socket);

  final Socket _socket;

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() => _socket.close();

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();
}

class _Session {
  _Session(this.ssh, this.sftp);

  final SSHClient ssh;
  final SftpClient sftp;

  void close() {
    sftp.close();
    ssh.close();
  }
}

/// SFTP with password or OpenSSH private key authentication. The host key
/// must match [pinnedHostKey]; unknown keys are always rejected.
class SftpBackend implements StorageBackend {
  SftpBackend({
    required this.host,
    this.port = 22,
    required this.username,
    this._password,
    this._privateKey,
    this._passphrase,
    this.basePath = '',
    required this.pinnedHostKey,
    this._connector = directConnector,
  });

  final String host;
  final int port;
  final String username;

  /// Absolute, or relative to the login directory.
  final String basePath;

  /// OpenSSH style `SHA256:<base64>`.
  final String? pinnedHostKey;
  final String? _password;
  final String? _privateKey;
  final String? _passphrase;
  final TcpConnector _connector;
  final _knownDirectories = <String>{};
  Future<_Session>? _session;

  String _path(List<String> segments) {
    final joined = [...pathSegments(basePath), ...segments].join('/');
    if (basePath.startsWith('/')) return '/$joined';
    return joined.isEmpty ? '.' : joined;
  }

  String _filePath(RemoteTarget target, String name) =>
      _path([...pathSegments(target.directory), name]);

  Future<_Session> _open() async {
    final List<SSHKeyPair>? identities;
    try {
      identities = _privateKey == null
          ? null
          : SSHKeyPair.fromPem(_privateKey, _passphrase);
    } on Object {
      throw const StorageException(
        'The private key could not be read.',
        retryable: false,
      );
    }

    final Socket socket;
    try {
      socket = await _connector(host, port);
    } on SocketException catch (e) {
      throw networkException(e, host);
    }

    String? rejectedType;
    String? rejectedFingerprint;
    final client = SSHClient(
      _TunnelSshSocket(socket),
      username: username,
      identities: identities,
      onPasswordRequest: _password == null ? null : () => _password,
      authTimeout: _authTimeout,
      onVerifyHostKey: (type, fingerprint) {
        final readable = hostKeyFingerprint(fingerprint);
        if (hostKeyPinMatches(pinnedHostKey, readable)) return true;
        rejectedType = type;
        rejectedFingerprint = readable;
        return false;
      },
    );
    try {
      await client.authenticated;
      return _Session(client, await client.sftp());
    } on Object catch (e) {
      client.close();
      final fingerprint = rejectedFingerprint;
      if (fingerprint != null) {
        throw UnknownHostKeyException(rejectedType!, fingerprint);
      }
      if (e is SSHAuthFailError) {
        throw const StorageException(
          'Wrong username, password or key.',
          retryable: false,
        );
      }
      throw StorageException('Connection to $host failed: $e');
    }
  }

  /// Runs [action] on a shared session; transport failures drop the session
  /// so the next call reconnects.
  Future<T> _run<T>(Future<T> Function(SftpClient sftp) action) async {
    final session = _session ??= _open();
    try {
      return await action((await session).sftp);
    } on StorageException {
      if (identical(_session, session)) await _drop();
      rethrow;
    } on SftpStatusError catch (e) {
      throw _statusError(e);
    } on Object catch (e) {
      if (identical(_session, session)) await _drop();
      throw StorageException('The connection to $host was interrupted: $e');
    }
  }

  StorageException _statusError(SftpStatusError e) => switch (e.code) {
    SftpStatusCode.noSuchFile => StorageException(
      'Folder was not found: ${e.message}',
      retryable: false,
    ),
    SftpStatusCode.permissionDenied => const StorageException(
      'Access denied.',
      retryable: false,
    ),
    _ => StorageException('The server reported: ${e.message}'),
  };

  Future<void> _drop() async {
    final session = _session;
    _session = null;
    _knownDirectories.clear();
    try {
      (await session)?.close();
    } on Object {
      // Already failed to open; nothing to close.
    }
  }

  Future<SftpFileAttrs?> _stat(SftpClient sftp, String path) async {
    try {
      return await sftp.stat(path);
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noSuchFile) return null;
      rethrow;
    }
  }

  @override
  Future<void> testConnection() => _run((sftp) async {
    final attrs = await _stat(sftp, _path(const []));
    if (attrs == null || !attrs.isDirectory) {
      throw const StorageException(
        'Base folder was not found.',
        retryable: false,
      );
    }
  });

  @override
  Future<ProbeResult> probe(
    RemoteTarget target, {
    required int size,
    required String sha256,
  }) => _run((sftp) => _probe(sftp, _filePath(target, target.name), size));

  Future<ProbeResult> _probe(SftpClient sftp, String path, int size) async {
    final attrs = await _stat(sftp, path);
    if (attrs == null) return ProbeResult.absent;
    return attrs.size == size && !attrs.isDirectory
        ? ProbeResult.identical
        : ProbeResult.different;
  }

  @override
  Future<UploadResult> upload(
    UploadRequest request, {
    UploadProgress? onProgress,
  }) => _run((sftp) async {
    final target = request.target;
    final targetPath = _filePath(target, target.name);
    final tempPath = _filePath(target, request.tempName);

    Future<UploadResult?> occupied() async {
      final result = await _probe(sftp, targetPath, request.size);
      if (result == ProbeResult.absent) return null;
      await _removeQuietly(sftp, tempPath);
      return result == ProbeResult.identical
          ? UploadResult.alreadyPresent
          : UploadResult.nameTaken;
    }

    final before = await occupied();
    if (before != null) return before;

    await _ensureDirectory(sftp, target.directory);
    final file = await sftp.open(
      tempPath,
      mode:
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate |
          SftpFileOpenMode.write,
    );
    try {
      await file
          .write(
            request.source.openRead().map(Uint8List.fromList),
            onProgress: (sent) => onProgress?.call(sent, request.size),
          )
          .done;
    } finally {
      await file.close();
    }

    // The rename below may replace an existing file, so check right before.
    final during = await occupied();
    if (during != null) return during;
    await sftp.rename(tempPath, targetPath);

    final committed = (await sftp.stat(targetPath)).size;
    if (committed != request.size) {
      throw StorageException(
        'Uploaded $target has $committed bytes instead of ${request.size}.',
      );
    }
    return UploadResult.uploaded;
  });

  Future<void> _ensureDirectory(SftpClient sftp, String directory) async {
    final segments = [...pathSegments(basePath), ...pathSegments(directory)];
    final root = basePath.startsWith('/') ? '/' : '';
    for (var i = 1; i <= segments.length; i++) {
      final path = '$root${segments.take(i).join('/')}';
      if (_knownDirectories.contains(path)) continue;
      try {
        await sftp.mkdir(path);
      } on SftpStatusError {
        final attrs = await _stat(sftp, path);
        if (attrs == null || !attrs.isDirectory) rethrow;
      }
      _knownDirectories.add(path);
    }
  }

  Future<void> _removeQuietly(SftpClient sftp, String path) async {
    try {
      await sftp.remove(path);
    } on SftpStatusError {
      // Usually absent; a leftover is overwritten by the next attempt.
    }
  }

  @override
  Future<void> close() => _drop();
}
