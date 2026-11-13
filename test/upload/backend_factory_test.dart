import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/upload/backend_factory.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/s3_backend.dart';
import 'package:shutterlink/upload/sftp_backend.dart';
import 'package:shutterlink/upload/storage_backend.dart';
import 'package:shutterlink/upload/webdav_backend.dart';

import 'support/s3_test_server.dart';
import 'support/serve.dart';
import 'support/upload_fixture.dart';
import 'support/webdav_test_server.dart';

void main() {
  final meteredFlags = <bool>[];
  final hosts = <String>[];

  setUp(() {
    meteredFlags.clear();
    hosts.clear();
  });

  Future<Socket> Function(String, int, {required bool allowMetered})
  connectorFor(int port) {
    final loopback = loopbackConnector(port, hosts: hosts);
    return (host, port, {required allowMetered}) {
      meteredFlags.add(allowMetered);
      return loopback(host, port);
    };
  }

  group('createBackend', () {
    test('builds the backend for each type', () async {
      final backends = [
        createBackend(
          const Destination(
            type: DestinationType.webdav,
            endpoint: 'https://dav.example.com',
          ),
          const DestinationSecrets(),
        ),
        createBackend(
          const Destination(
            type: DestinationType.s3,
            endpoint: 'https://s3.example.com',
            bucket: 'photos',
          ),
          const DestinationSecrets(),
        ),
        createBackend(
          const Destination(
            type: DestinationType.sftp,
            endpoint: 'nas.example.com',
          ),
          const DestinationSecrets(),
        ),
      ];
      expect(backends[0], isA<WebDavBackend>());
      expect((backends[1] as S3Backend).region, defaultS3Region);
      final sftp = backends[2] as SftpBackend;
      expect((sftp.host, sftp.port), ('nas.example.com', defaultSftpPort));
      for (final backend in backends) {
        await backend.close();
      }
    });

    test('parses an SFTP port and URL form', () async {
      for (final endpoint in ['nas.example.com:2222', 'sftp://nas:2222']) {
        final backend = createBackend(
          Destination(type: DestinationType.sftp, endpoint: endpoint),
          const DestinationSecrets(),
        ) as SftpBackend;
        expect(backend.port, 2222);
        await backend.close();
      }
    });

    test('rejects an unusable address', () {
      for (final destination in const [
        Destination(type: DestinationType.webdav, endpoint: 'dav.example.com'),
        Destination(type: DestinationType.s3, endpoint: 'ftp://s3.example'),
        Destination(type: DestinationType.sftp, endpoint: ':22'),
      ]) {
        expect(
          () => createBackend(destination, const DestinationSecrets()),
          throwsA(
            isA<StorageException>().having(
              (e) => e.retryable,
              'retryable',
              false,
            ),
          ),
        );
      }
    });
  });

  group('destinationBackendFactory', () {
    test('connects through the connector with the queue\'s policy', () async {
      final server = await WebDavTestServer.start(collections: ['dav']);
      addTearDown(server.close);
      final factory = destinationBackendFactory(
        () async => const DestinationSecrets(password: 'secret'),
        connector: connectorFor(server.port),
      );

      final backend = await factory(
        Destination(
          type: DestinationType.webdav,
          endpoint: 'http://dav.example.com:${server.port}/dav',
          username: 'alice',
        ),
        allowMetered: false,
      );
      await backend.testConnection();
      await backend.close();

      expect(meteredFlags, allOf(isNotEmpty, everyElement(isFalse)));
      expect(hosts, everyElement('dav.example.com'));
    });

    test('surfaces missing credentials', () async {
      final factory = destinationBackendFactory(
        () => Future.error(const CredentialsMissingException()),
      );

      await expectLater(
        factory(
          const Destination(
            type: DestinationType.webdav,
            endpoint: 'https://dav.example.com',
          ),
          allowMetered: true,
        ),
        throwsA(isA<CredentialsMissingException>()),
      );
    });
  });

  group('testDestination', () {
    test('passes the S3 secret key and allows mobile data', () async {
      final server = await S3TestServer.start();
      addTearDown(server.close);

      await testDestination(
        Destination(
          type: DestinationType.s3,
          endpoint: 'http://s3.example.com:${server.port}',
          region: 'eu-central-1',
          bucket: 'photos',
          username: 'AKIDTEST',
          pathStyle: true,
        ),
        const DestinationSecrets(password: 'test-secret'),
        connector: connectorFor(server.port),
      );

      expect(meteredFlags, allOf(isNotEmpty, everyElement(isTrue)));
    });

    test('reports rejected credentials readably', () async {
      final server = await WebDavTestServer.start(collections: ['dav']);
      addTearDown(server.close);

      await expectLater(
        testDestination(
          Destination(
            type: DestinationType.webdav,
            endpoint: 'http://dav.example.com:${server.port}/dav',
            username: 'alice',
          ),
          const DestinationSecrets(password: 'wrong'),
          connector: connectorFor(server.port),
        ),
        throwsA(
          isA<StorageException>().having(
            (e) => e.retryable,
            'retryable',
            false,
          ),
        ),
      );
    });

    test('accepts a self-signed certificate only once pinned', () async {
      final server = await WebDavTestServer.start(
        collections: ['dav'],
        tls: true,
      );
      addTearDown(server.close);
      final destination = Destination(
        type: DestinationType.webdav,
        endpoint: 'https://localhost:${server.port}/dav',
        username: 'alice',
      );
      const secrets = DestinationSecrets(password: 'secret');
      final fingerprint = await testCertificateFingerprint();

      await expectLater(
        testDestination(
          destination,
          secrets,
          connector: connectorFor(server.port),
        ),
        throwsA(
          isA<UntrustedCertificateException>().having(
            (e) => e.fingerprint,
            'fingerprint',
            fingerprint,
          ),
        ),
      );
      await testDestination(
        destination,
        secrets.copyWith(certificatePin: () => fingerprint),
        connector: connectorFor(server.port),
      );
    });

    test('rejects an SFTP server whose host is unreachable', () async {
      final port = await closedPort();

      await expectLater(
        testDestination(
          Destination(
            type: DestinationType.sftp,
            endpoint: 'localhost:$port',
            username: 'alice',
          ),
          const DestinationSecrets(password: 'secret'),
        ),
        throwsA(isA<StorageException>()),
      );
    });
  });
}
