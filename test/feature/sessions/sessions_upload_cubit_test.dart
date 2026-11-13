import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/data/upload_worker.dart';
import 'package:shutterlink/feature/sessions/sessions_upload_cubit.dart';

import '../../fakes/spy_sessions_dependencies.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SpySessionsDependencies sessions;
  late SessionsUploadCubit cubit;

  Future<SessionsUploadState> settled(
    bool Function(SessionsUploadState state) test,
  ) async => test(cubit.state) ? cubit.state : cubit.stream.firstWhere(test);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sessions_upload');
    SharedPreferences.setMockInitialValues({
      SettingsRepository.sessionsEnabledKey: true,
      SettingsRepository.sessionsServerUrlKey: 'https://photos.example.com',
    });
    sessions = SpySessionsDependencies(
      SettingsRepository(await SharedPreferences.getInstance()),
      root,
      token: 'token',
    );
    cubit = SessionsUploadCubit(sessions);
  });

  tearDown(() async {
    await cubit.close();
    await root.delete(recursive: true);
  });

  test('starts one worker and wakes it on settings changes', () async {
    final file = File(p.join(root.path, 'photo.jpg'))..writeAsStringSync('x');
    await sessions.queue.enqueue(sessionCode: 'a-b-c-d', file: file);

    await cubit.setEnabled(enabled: true);
    var state = await settled(
      (state) => state.status == UploadWorkerStatus.serverConfiguration,
    );
    expect(sessions.workers, 1);
    expect(sessions.requests, hasLength(1));
    expect(state.pending, 1);

    await cubit.setEnabled(enabled: true);
    await settled((_) => sessions.requests.length == 2);
    expect(sessions.workers, 1);

    await cubit.resumed();
    expect(sessions.requests, hasLength(3));

    await cubit.setEnabled(enabled: false);
    state = cubit.state;
    expect(state.running, isFalse);
    await cubit.resumed();
    expect(sessions.requests, hasLength(3));
  });

  test('stays idle while disabled', () async {
    await cubit.setEnabled(enabled: false);

    expect(sessions.workers, 0);
    expect(sessions.fakeCredentials.reads, 0);
    expect(cubit.state, const SessionsUploadState());
  });
}
