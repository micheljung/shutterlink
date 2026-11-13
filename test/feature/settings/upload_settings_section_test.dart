import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/destination_repository.dart';
import 'package:shutterlink/feature/settings/upload_settings_cubit.dart';
import 'package:shutterlink/feature/settings/upload_settings_section.dart';
import 'package:shutterlink/upload/backend_factory.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/network_policy.dart';
import 'package:shutterlink/upload/storage_backend.dart';

/// The progress bar animates while a dialog is open, so it never settles.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  const saved = Destination(
    type: DestinationType.webdav,
    endpoint: 'https://old.example.com/dav',
    username: 'alice',
  );
  const savedSecrets = DestinationSecrets(password: 'old-secret');
  const fingerprint = 'AA:BB:CC';
  late DestinationRepository repository;
  late List<(Destination, DestinationSecrets)> tested;
  late List<Exception?> answers;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    repository = DestinationRepository(await SharedPreferences.getInstance());
    tested = [];
    answers = [];
  });

  Future<UploadSettingsCubit> pump(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(800, 3000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final cubit = UploadSettingsCubit(
      repository,
      tester: (destination, secrets) async {
        tested.add((destination, secrets));
        final answer = answers.isEmpty ? null : answers.removeAt(0);
        if (answer != null) throw answer;
      },
    );
    addTearDown(cubit.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider.value(
            value: cubit,
            child: const SingleChildScrollView(child: UploadSettingsSection()),
          ),
        ),
      ),
    );
    await settle(tester);
    return cubit;
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  Future<void> enter(WidgetTester tester, String label, String text) =>
      tester.enterText(field(label), text);

  testWidgets('shows nothing without upload support', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: UploadSettingsSection())),
    );

    expect(find.text('Upload'), findsNothing);
  });

  testWidgets('shows the fields of each destination type', (tester) async {
    await pump(tester);

    expect(field('Server URL'), findsOneWidget);
    expect(field('Username'), findsOneWidget);
    expect(field('Password'), findsOneWidget);
    expect(field('Bucket'), findsNothing);
    expect(field('Private key (optional)'), findsNothing);

    await tester.tap(find.text('S3'));
    await settle(tester);
    for (final label in [
      'Endpoint URL',
      'Region',
      'Bucket',
      'Folder',
      'Access key ID',
      'Secret access key',
    ]) {
      expect(field(label), findsOneWidget, reason: label);
    }
    expect(find.text('Path-style URLs'), findsOneWidget);

    await tester.tap(find.text('SFTP'));
    await settle(tester);
    expect(field('Host'), findsOneWidget);
    expect(field('Private key (optional)'), findsOneWidget);
    expect(field('Key passphrase'), findsOneWidget);
    expect(field('Bucket'), findsNothing);
  });

  testWidgets('shows the test connection result', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Test connection'));
    await settle(tester);
    expect(find.text('Enter the server address.'), findsOneWidget);
    expect(tested, isEmpty);

    await enter(tester, 'Server URL', 'https://dav.example.com');
    await enter(tester, 'Username', 'alice');
    await enter(tester, 'Password', 'pw');
    answers.add(const StorageException('Access denied.', retryable: false));
    await tester.tap(find.text('Test connection'));
    await settle(tester);
    expect(find.text('Access denied.'), findsOneWidget);

    await tester.tap(find.text('Test connection'));
    await settle(tester);
    expect(find.text('Connection works.'), findsOneWidget);
    expect(tested.last.$1.endpoint, 'https://dav.example.com');
    expect(tested.last.$2.password, 'pw');
  });

  testWidgets('pins a certificate the user trusts', (tester) async {
    await pump(tester);
    await enter(tester, 'Server URL', 'https://dav.example.com');
    answers.add(const UntrustedCertificateException(fingerprint));

    await tester.tap(find.text('Test connection'));
    await settle(tester);
    expect(find.text('Trust this certificate?'), findsOneWidget);
    expect(find.text(fingerprint), findsOneWidget);
    await tester.tap(find.text('Trust'));
    await settle(tester);

    expect(find.text('Connection works.'), findsOneWidget);
    expect(tested.last.$2.certificatePin, fingerprint);
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect((await repository.readSecrets()).certificatePin, fingerprint);
  });

  testWidgets('keeps an SFTP host key unpinned when declined', (tester) async {
    await pump(tester);
    await tester.tap(find.text('SFTP'));
    await settle(tester);
    await enter(tester, 'Host', 'nas.example.com');
    const rejected = UnknownHostKeyException('ssh-ed25519', 'SHA256:abc');
    answers.add(rejected);

    await tester.tap(find.text('Test connection'));
    await settle(tester);
    expect(find.text('Trust this host key?'), findsOneWidget);
    expect(find.text('ssh-ed25519'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);

    expect(find.text(rejected.message), findsOneWidget);
    expect(tested, hasLength(1));
  });

  testWidgets('saves the policy and local copy choice', (tester) async {
    await pump(tester);
    await enter(tester, 'Server URL', 'https://dav.example.com');
    await tester.tap(find.text('JPEG only'));
    await tester.tap(find.text('Keep photos in gallery after upload'));
    await settle(tester);

    await tester.tap(find.text('Save'));
    await settle(tester);

    expect(find.text('Saved.'), findsOneWidget);
    expect(repository.destination?.policy, MobileDataPolicy.jpeg);
    expect(repository.destination?.keepLocalCopy, isFalse);
  });

  testWidgets('confirms replacing a destination', (tester) async {
    await repository.save(saved, savedSecrets);
    await pump(tester);
    expect(
      tester.widget<TextField>(field('Server URL')).controller?.text,
      saved.endpoint,
    );
    await enter(tester, 'Server URL', 'https://new.example.com/dav');

    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(find.text('Replace destination?'), findsOneWidget);
    expect(
      find.text('Photos not uploaded yet will go to the new destination.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(repository.destination, saved);

    await tester.tap(find.text('Save'));
    await settle(tester);
    await tester.tap(find.text('Replace'));
    await settle(tester);
    expect(repository.destination?.endpoint, 'https://new.example.com/dav');
    expect(await repository.readSecrets(), savedSecrets);
  });

  testWidgets('saves an unchanged destination without asking', (tester) async {
    await repository.save(saved, savedSecrets);
    await pump(tester);
    await tester.tap(find.text('All'));
    await settle(tester);

    await tester.tap(find.text('Save'));
    await settle(tester);

    expect(find.text('Replace destination?'), findsNothing);
    expect(repository.destination?.policy, MobileDataPolicy.all);
  });

  testWidgets('reports missing credentials', (tester) async {
    await repository.save(saved, savedSecrets);
    FlutterSecureStorage.setMockInitialValues({});
    await pump(tester);

    expect(
      find.text('Credentials missing. Enter them again and save.'),
      findsOneWidget,
    );
  });

  testWidgets('removes the destination', (tester) async {
    await repository.save(saved, savedSecrets);
    await pump(tester);

    await tester.tap(find.text('Remove destination'));
    await settle(tester);
    await tester.tap(find.text('Remove'));
    await settle(tester);

    expect(repository.destination, isNull);
    expect(find.text('Remove destination'), findsNothing);
    expect(tester.widget<TextField>(field('Server URL')).controller?.text, '');
  });
}
