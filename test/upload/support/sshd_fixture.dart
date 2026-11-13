import 'dart:async';
import 'dart:io';

/// Runs OpenSSH `sshd` on an ephemeral loopback port with a fresh host key
/// and `internal-sftp`. Throws (never skips) when sshd cannot be started:
/// tests using it are tagged `sftp`/`sftp-root` and only run on request.
///
/// `SSHD` overrides the binary (default `/usr/sbin/sshd`). Password mode
/// starts sshd through `sudo -n` and logs in as `SFTP_TEST_USER` with
/// `SFTP_TEST_PASSWORD`; key mode logs in as the current user.
class SshdFixture {
  SshdFixture._(this._process, this._dir, this.port, this.username);

  static String get _sshd => Platform.environment['SSHD'] ?? '/usr/sbin/sshd';

  static Future<SshdFixture> start({bool password = false}) async {
    final sshd = _sshd;
    if (!File(sshd).existsSync()) {
      throw StateError('$sshd not found; install openssh-server or set SSHD.');
    }
    final dir = await Directory.systemTemp.createTemp('sshd_fixture');
    await _run('ssh-keygen', [
      '-q',
      '-t',
      'ed25519',
      '-N',
      '',
      '-f',
      '${dir.path}/host_key',
    ]);
    await _run('ssh-keygen', [
      '-q',
      '-t',
      'ed25519',
      '-N',
      '',
      '-f',
      '${dir.path}/client_key',
    ]);
    await File('${dir.path}/client_key.pub')
        .copy('${dir.path}/authorized_keys');
    await Directory('${dir.path}/data').create();

    final String username;
    if (password) {
      final user = Platform.environment['SFTP_TEST_USER'];
      if (user == null || Platform.environment['SFTP_TEST_PASSWORD'] == null) {
        throw StateError('Set SFTP_TEST_USER and SFTP_TEST_PASSWORD.');
      }
      username = user;
    } else {
      username = (await _run('id', ['-un'])).trim();
    }

    final port = await _freePort();
    final config = File('${dir.path}/sshd_config');
    await config.writeAsString('''
Port $port
ListenAddress 127.0.0.1
HostKey ${dir.path}/host_key
PidFile ${dir.path}/sshd.pid
AuthorizedKeysFile ${dir.path}/authorized_keys
StrictModes no
UsePAM no
PubkeyAuthentication yes
PasswordAuthentication ${password ? 'yes' : 'no'}
KbdInteractiveAuthentication no
AllowUsers $username
Subsystem sftp internal-sftp
LogLevel VERBOSE
''');
    final args = ['-D', '-f', config.path, '-E', '${dir.path}/sshd.log'];
    final process = password
        ? await Process.start('sudo', ['-n', sshd, ...args])
        : await Process.start(sshd, args);
    final fixture = SshdFixture._(process, dir, port, username);
    await fixture._awaitListening();
    return fixture;
  }

  final Process _process;
  final Directory _dir;
  final int port;
  final String username;

  /// Absolute path of an empty, writable directory for key-auth tests.
  String get dataDir => '${_dir.path}/data';

  String get clientPrivateKey =>
      File('${_dir.path}/client_key').readAsStringSync();

  /// A valid key that is not authorized for login.
  String get unauthorizedPrivateKey =>
      File('${_dir.path}/host_key').readAsStringSync();

  String get password => Platform.environment['SFTP_TEST_PASSWORD']!;

  /// OpenSSH style `SHA256:<base64>`.
  Future<String> hostKeyFingerprint() async {
    final out = await _run('ssh-keygen', [
      '-l',
      '-E',
      'sha256',
      '-f',
      '${_dir.path}/host_key.pub',
    ]);
    return out.split(' ')[1];
  }

  String get log {
    final file = File('${_dir.path}/sshd.log');
    return file.existsSync() ? file.readAsStringSync() : '';
  }

  Future<void> _awaitListening() async {
    var exited = false;
    unawaited(_process.exitCode.then((_) => exited = true));
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (exited) break;
      try {
        final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
        socket.destroy();
        return;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    await stop();
    throw StateError('sshd did not start:\n$log');
  }

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    if (_dir.existsSync()) await _dir.delete(recursive: true);
  }

  static Future<String> _run(String executable, List<String> args) async {
    final result = await Process.run(executable, args);
    if (result.exitCode != 0) {
      throw StateError('$executable failed: ${result.stderr}');
    }
    return result.stdout as String;
  }

  static Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }
}
