import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/destination_repository.dart';
import 'package:shutterlink/feature/settings/upload_draft_fields.dart';
import 'package:shutterlink/feature/settings/upload_settings_cubit.dart';
import 'package:shutterlink/feature/settings/upload_settings_section.dart';
import 'package:shutterlink/feature/settings/upload_setup_screen.dart';
import 'package:shutterlink/upload/backend_factory.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/network_policy.dart';
import 'package:shutterlink/upload/provider_preset.dart';
import 'package:shutterlink/upload/storage_backend.dart';

/// Progress bars animate while a check or dialog is open, so they never
/// settle.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _GatedSecureStorage extends FlutterSecureStorage {
  final gate = Completer<void>();

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    await gate.future;
    return super.read(key: key);
  }
}

class _ReadOnlySecureStorage extends FlutterSecureStorage {
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => Future.error(Exception('Keystore unavailable'));
}

void main() {
  const saved = Destination(
    type: DestinationType.webdav,
    endpoint: 'https://old.example.com/dav',
    username: 'alice',
    policy: MobileDataPolicy.jpeg,
    keepLocalCopy: false,
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

  Future<void> enter(WidgetTester tester, String label, String text) async {
    await tester.enterText(field(label), text);
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await settle(tester);
  }

  bool enabled(WidgetTester tester, String label) => tester
      .widget<ButtonStyleButton>(
        find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
      )
      .enabled;

  Future<void> openGuide(WidgetTester tester, String provider) async {
    await tap(tester, 'Set up upload');
    await tap(tester, provider);
    await tap(tester, 'Next');
  }

  /// Fills the custom WebDAV guide up to the check, which runs on entry.
  Future<void> customWebDavToCheck(WidgetTester tester) async {
    await openGuide(tester, 'Custom');
    await enter(tester, 'Server URL', 'https://dav.example.com');
    await tap(tester, 'Next');
    await enter(tester, 'Username', 'alice');
    await enter(tester, 'Password', 'pw');
    await tap(tester, 'Next');
    await tap(tester, 'Next');
  }

  Future<void> openEdit(WidgetTester tester) async {
    await tester.tap(find.text('Edit'));
    await settle(tester);
  }

  Finder dialogButton(String text) =>
      find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

  testWidgets('shows nothing without upload support', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: UploadSettingsSection())),
    );

    expect(find.text('Upload'), findsNothing);
  });

  testWidgets('offers only setup and disabled policies without a '
      'destination', (tester) async {
    await pump(tester);

    expect(find.text('Set up upload'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(
      tester
          .widget<SegmentedButton<MobileDataPolicy>>(
            find.byType(SegmentedButton<MobileDataPolicy>),
          )
          .onSelectionChanged,
      isNull,
    );
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNull,
    );
  });

  testWidgets('shows the fields of each custom destination type', (
    tester,
  ) async {
    await pump(tester);
    await openGuide(tester, 'Custom');

    expect(field('Server URL'), findsOneWidget);
    expect(field('Bucket'), findsNothing);

    await tap(tester, 'S3');
    expect(field('Endpoint URL'), findsOneWidget);
    expect(field('Bucket'), findsOneWidget);
    await tap(tester, 'Advanced');
    expect(field('Region'), findsOneWidget);
    expect(find.text('Path-style URLs'), findsOneWidget);
    await enter(tester, 'Endpoint URL', 'https://s3.example.com');
    await enter(tester, 'Bucket', 'photos');
    await tap(tester, 'Next');
    expect(field('Access key ID'), findsOneWidget);
    expect(field('Secret access key'), findsOneWidget);
    await tap(tester, 'Back');

    await tap(tester, 'SFTP');
    expect(field('Host'), findsOneWidget);
    expect(field('Bucket'), findsNothing);
    await tap(tester, 'Next');
    expect(field('Username'), findsOneWidget);
    expect(field('Password'), findsOneWidget);
    expect(field('Private key'), findsNothing);
    await tap(tester, 'Use a private key instead');
    expect(field('Private key'), findsOneWidget);
    expect(field('Key passphrase'), findsOneWidget);
    expect(field('Password'), findsNothing);
  });

  testWidgets('guides through a preset and saves it', (tester) async {
    await pump(tester);
    await tap(tester, 'Set up upload');
    expect(enabled(tester, 'Next'), isFalse);
    await tap(tester, 'Backblaze B2');
    await tap(tester, 'Next');

    expect(find.text('Your Backblaze B2 bucket'), findsOneWidget);
    expect(enabled(tester, 'Next'), isFalse);
    await enter(tester, 'Region', 'eu-central-003');
    await enter(tester, 'Bucket name', 'camera');
    expect(
      find.text('Endpoint: https://s3.eu-central-003.backblazeb2.com'),
      findsOneWidget,
    );
    await tap(tester, 'Next');
    await enter(tester, 'Key ID', 'key-id');
    await enter(tester, 'Application key', 'app-key');
    await tap(tester, 'Next');
    await enter(tester, 'Folder', 'eos');
    await tap(tester, 'Next');

    expect(find.text('No upload destination'), findsNothing);
    expect(
      repository.destination,
      const Destination(
        type: DestinationType.s3,
        endpoint: 'https://s3.eu-central-003.backblazeb2.com',
        region: 'eu-central-003',
        bucket: 'camera',
        basePath: 'eos',
        username: 'key-id',
        pathStyle: true,
      ),
    );
    expect(repository.preset, ProviderPreset.backblazeB2);
    expect((await repository.readSecrets()).password, 'app-key');
    expect(find.text('Backblaze B2'), findsOneWidget);
    expect(find.text('camera · /eos'), findsOneWidget);
  });

  testWidgets('shows the connection check result', (tester) async {
    await pump(tester);
    await openGuide(tester, 'Custom');
    expect(enabled(tester, 'Next'), isFalse);
    answers.add(const StorageException('Server down.', retryable: false));

    await enter(tester, 'Server URL', 'https://dav.example.com');
    await tap(tester, 'Next');
    await enter(tester, 'Username', 'alice');
    await enter(tester, 'Password', 'pw');
    await tap(tester, 'Next');
    await tap(tester, 'Next');

    expect(find.text('Server down.'), findsOneWidget);
    expect(find.text('Back to Server'), findsOneWidget);
    expect(find.text('Back to Sign in'), findsNothing);
    expect(repository.destination, isNull);
    expect(tested.last.$1.endpoint, 'https://dav.example.com');
    expect(tested.last.$2.password, 'pw');

    await tap(tester, 'Check again');
    expect(repository.destination?.endpoint, 'https://dav.example.com');
  });

  testWidgets('a rejected sign-in leads back to Sign in', (tester) async {
    await pump(tester);
    answers.add(const AuthenticationException('Wrong username or password.'));
    await customWebDavToCheck(tester);

    expect(find.text('Wrong username or password.'), findsOneWidget);
    await tap(tester, 'Back to Sign in');
    expect(find.text('Step 3 of 5 · Sign in'), findsOneWidget);
    expect(repository.destination, isNull);
  });

  testWidgets('saves anyway when the server is unreachable', (tester) async {
    await pump(tester);
    answers.add(const StorageException('Server dav.example.com not found.'));
    await customWebDavToCheck(tester);

    await tap(tester, 'Save anyway');

    expect(repository.destination?.endpoint, 'https://dav.example.com');
    expect(
      await repository.readSecrets(),
      const DestinationSecrets(password: 'pw'),
    );
  });

  testWidgets('pins a certificate the user trusts', (tester) async {
    await pump(tester);
    answers.add(const UntrustedCertificateException(fingerprint));
    await customWebDavToCheck(tester);

    expect(find.text('Trust this certificate?'), findsOneWidget);
    expect(find.text(fingerprint), findsOneWidget);
    await tester.tap(find.text('Trust'));
    await settle(tester);

    expect(tested.last.$2.certificatePin, fingerprint);
    expect((await repository.readSecrets()).certificatePin, fingerprint);
  });

  testWidgets('keeps the pin on Sign in and drops it for another server', (
    tester,
  ) async {
    await pump(tester);
    answers
      ..add(const UntrustedCertificateException(fingerprint))
      ..add(const AuthenticationException('Wrong username or password.'))
      ..add(const StorageException('Down.', retryable: false))
      ..add(const StorageException('Down.', retryable: false));
    await customWebDavToCheck(tester);
    await tester.tap(find.text('Trust'));
    await settle(tester);
    expect(tested.last.$2.certificatePin, fingerprint);

    await tap(tester, 'Back to Sign in');
    await enter(tester, 'Password', 'corrected');
    await tap(tester, 'Next');
    await tap(tester, 'Next');
    expect(tested.last.$2.certificatePin, fingerprint);

    await tap(tester, 'Back to Server');
    await enter(tester, 'Server URL', 'https://other.example.com');
    await tap(tester, 'Next');
    await tap(tester, 'Next');
    await tap(tester, 'Next');
    expect(tested.last.$2.certificatePin, isNull);
  });

  testWidgets('keeps an SFTP host key unpinned when declined', (tester) async {
    await pump(tester);
    await openGuide(tester, 'Custom');
    await tap(tester, 'SFTP');
    await enter(tester, 'Host', 'nas.example.com');
    await tap(tester, 'Next');
    await tap(tester, 'Next');
    const rejected = UnknownHostKeyException('ssh-ed25519', 'SHA256:abc');
    answers.add(rejected);
    await tap(tester, 'Next');

    expect(find.text('Trust this host key?'), findsOneWidget);
    expect(find.text('ssh-ed25519'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);

    expect(find.text(rejected.message), findsOneWidget);
    expect(find.text('Save anyway'), findsNothing);
    expect(tested, hasLength(1));
    expect(repository.destination, isNull);
  });

  testWidgets('saves the policy without touching the secrets', (tester) async {
    await repository.save(saved, savedSecrets);
    final changes = <Destination?>[];
    final subscription = repository.changes.listen(changes.add);
    addTearDown(subscription.cancel);
    await pump(tester);

    await tester.tap(find.text('All'));
    await settle(tester);
    await tester.tap(find.text('Keep photos in gallery after upload'));
    await settle(tester);

    expect(repository.destination?.policy, MobileDataPolicy.all);
    expect(repository.destination?.keepLocalCopy, isTrue);
    expect(repository.destination?.fingerprint, saved.fingerprint);
    expect(changes.last, repository.destination);
    expect(await repository.readSecrets(), savedSecrets);
  });

  testWidgets('a policy change keeps credentials missing', (tester) async {
    await repository.save(saved, savedSecrets);
    FlutterSecureStorage.setMockInitialValues({});
    await pump(tester);

    await tester.tap(find.text('All'));
    await settle(tester);

    expect(repository.destination?.policy, MobileDataPolicy.all);
    expect(
      await DestinationRepository.defaultSecureStorage.read(
        key: DestinationRepository.secretsKey,
      ),
      isNull,
    );
    expect(find.text('Credentials missing. Enter them again.'), findsOneWidget);
  });

  testWidgets('confirms replacing a destination', (tester) async {
    await repository.save(saved, savedSecrets);
    await pump(tester);
    await openEdit(tester);
    expect(
      tester.widget<TextField>(field('Server URL')).controller?.text,
      saved.endpoint,
    );
    await enter(tester, 'Server URL', 'https://new.example.com/dav');

    await tap(tester, 'Save');
    expect(find.text('Replace destination?'), findsOneWidget);
    expect(
      find.text('Photos not uploaded yet will go to the new destination.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(repository.destination, saved);
    expect(find.text(notSavedNote), findsOneWidget);

    await tap(tester, 'Save');
    await tester.tap(find.text('Replace'));
    await settle(tester);
    expect(repository.destination?.endpoint, 'https://new.example.com/dav');
    expect(repository.destination?.policy, saved.policy);
    expect(repository.destination?.keepLocalCopy, saved.keepLocalCopy);
    expect(await repository.readSecrets(), savedSecrets);
  });

  testWidgets('a legacy destination saves unchanged without asking', (
    tester,
  ) async {
    await repository.save(saved, savedSecrets);
    await pump(tester);
    await openEdit(tester);

    expect(field('Server URL'), findsOneWidget);
    expect(tester.widget<TextField>(field('Folder')).controller?.text, '');
    await tap(tester, 'Save');

    expect(find.text('Replace destination?'), findsNothing);
    expect(repository.destination, saved);
    expect(repository.destination?.basePath, '');
    expect(find.text('Edit upload'), findsNothing);
  });

  testWidgets('a changed password saves without asking, a changed folder '
      'asks', (tester) async {
    final nextcloud = ProviderPreset.nextcloud.build(
      const PresetInput(server: 'cloud.example.com', username: 'alice'),
    );
    await repository.save(
      nextcloud,
      savedSecrets,
      preset: ProviderPreset.nextcloud,
    );
    await pump(tester);
    await openEdit(tester);

    expect(
      tester.widget<TextField>(field('Server address')).controller?.text,
      'cloud.example.com',
    );
    await enter(tester, 'App password', 'new-secret');
    await tap(tester, 'Save');
    expect(find.text('Replace destination?'), findsNothing);
    expect((await repository.readSecrets()).password, 'new-secret');
    expect(repository.destination, nextcloud);

    await openEdit(tester);
    await enter(tester, 'Folder', 'Camera');
    await tap(tester, 'Save');
    expect(find.text('Replace destination?'), findsOneWidget);
    await tester.tap(find.text('Replace'));
    await settle(tester);
    expect(repository.destination?.basePath, 'Camera');
    expect(repository.preset, ProviderPreset.nextcloud);
  });

  testWidgets('reports missing credentials and fixes them', (tester) async {
    await repository.save(saved, savedSecrets);
    FlutterSecureStorage.setMockInitialValues({});
    await pump(tester);

    expect(find.text('Credentials missing. Enter them again.'), findsOneWidget);
    await tap(tester, 'Fix');
    await enter(tester, 'Password', 'again');
    await tap(tester, 'Save');

    expect(find.text('Credentials missing. Enter them again.'), findsNothing);
    expect((await repository.readSecrets()).password, 'again');
  });

  testWidgets('removes the destination', (tester) async {
    await repository.save(saved, savedSecrets);
    await pump(tester);

    await tap(tester, 'Remove');
    expect(find.text('Remove destination?'), findsOneWidget);
    await tester.tap(dialogButton('Cancel'));
    await settle(tester);
    expect(repository.destination, saved);

    await tap(tester, 'Remove');
    await tester.tap(dialogButton('Remove'));
    await settle(tester);

    expect(repository.destination, isNull);
    expect(find.text('Set up upload'), findsOneWidget);
  });

  testWidgets('Edit waits until the secrets are loaded', (tester) async {
    await repository.save(saved, savedSecrets);
    final storage = _GatedSecureStorage();
    repository = DestinationRepository(
      await SharedPreferences.getInstance(),
      secureStorage: storage,
    );
    await pump(tester);

    Finder editButton() => find.ancestor(
      of: find.text('Edit'),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    );
    expect(tester.widget<ButtonStyleButton>(editButton()).enabled, isFalse);

    storage.gate.complete();
    await settle(tester);
    expect(tester.widget<ButtonStyleButton>(editButton()).enabled, isTrue);
    await openEdit(tester);
    expect(
      tester.widget<TextField>(field('Password')).controller?.text,
      savedSecrets.password,
    );
  });

  testWidgets('declining Replace in the guide leaves a note', (tester) async {
    await repository.save(saved, savedSecrets);
    final cubit = await pump(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(navigator.push(UploadSetupScreen.route(cubit)));
    await settle(tester);
    await tap(tester, 'Custom');
    await tap(tester, 'Next');
    await enter(tester, 'Server URL', 'https://new.example.com/dav');
    await tap(tester, 'Next');
    await tap(tester, 'Next');
    await tap(tester, 'Next');

    expect(find.text('Replace destination?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);

    expect(find.text(notSavedNote), findsOneWidget);
    expect(repository.destination, saved);
  });

  testWidgets('a failing save does not leave the guide busy', (tester) async {
    repository = DestinationRepository(
      await SharedPreferences.getInstance(),
      secureStorage: _ReadOnlySecureStorage(),
    );
    await pump(tester);
    await openGuide(tester, 'Custom');
    await enter(tester, 'Server URL', 'https://dav.example.com');
    await tap(tester, 'Next');
    await tap(tester, 'Next');
    final errors = <Object>[];
    await runZonedGuarded(() async {
      await tester.tap(find.text('Next'));
      await settle(tester);
    }, (error, _) => errors.add(error));

    expect(errors, isNotEmpty);
    expect(find.text('Checking the connection…'), findsNothing);
    expect(
      tester
          .widget<ButtonStyleButton>(
            find.ancestor(
              of: find.text('Check again'),
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            ),
          )
          .enabled,
      isTrue,
    );
  });
}
