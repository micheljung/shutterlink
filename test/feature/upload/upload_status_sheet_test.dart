import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shutterlink/feature/sessions/sessions_upload_cubit.dart';
import 'package:shutterlink/feature/upload/upload_status_cubit.dart';
import 'package:shutterlink/feature/upload/upload_status_sheet.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/network_policy.dart';
import 'package:shutterlink/upload/upload_item.dart';

class _MockUploadStatusCubit extends MockCubit<UploadStatusState>
    implements UploadStatusCubit {}

class _MockSessionsUploadCubit extends MockCubit<SessionsUploadState>
    implements SessionsUploadCubit {}

void main() {
  late _MockUploadStatusCubit cubit;
  late _MockSessionsUploadCubit sessions;

  setUp(() {
    cubit = _MockUploadStatusCubit();
    sessions = _MockSessionsUploadCubit();
    when(() => sessions.state).thenReturn(const SessionsUploadState());
    when(cubit.retryNow).thenAnswer((_) async {});
    when(cubit.removeKeptCopies).thenAnswer((_) async => 0);
  });

  Future<void> pump(WidgetTester tester, UploadStatusState state) async {
    when(() => cubit.state).thenReturn(state);
    await tester.pumpWidget(
      MaterialApp(
        home: MultiBlocProvider(
          providers: [
            BlocProvider<UploadStatusCubit>.value(value: cubit),
            BlocProvider<SessionsUploadCubit>.value(value: sessions),
          ],
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => UploadStatusSheet.show(context),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('lists the Sessions queue only while it has photos', (
    tester,
  ) async {
    await pump(tester, const UploadStatusState());
    expect(find.text(UploadStatusSheet.sessionsTitle), findsNothing);

    Navigator.of(tester.element(find.byType(UploadStatusSheet))).pop();
    await tester.pumpAndSettle();
    when(() => sessions.state)
        .thenReturn(const SessionsUploadState(pending: 1));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text(UploadStatusSheet.sessionsTitle), findsOneWidget);
    expect(find.text('1 photo waiting'), findsOneWidget);
  });

  testWidgets('shows the active upload', (tester) async {
    await pump(
      tester,
      const UploadStatusState(
        pending: 2,
        uploadingFile: 'IMG_0001.JPG',
        sentBytes: 1,
        totalBytes: 4,
        completed: 3,
      ),
    );

    expect(find.text('Uploading IMG_0001.JPG'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.25,
    );
    expect(find.text('2 waiting · 3 uploaded'), findsOneWidget);
    expect(find.text('Retry now'), findsNothing);
  });

  testWidgets('explains why uploads wait and retries on request', (
    tester,
  ) async {
    await pump(
      tester,
      const UploadStatusState(pending: 1, waitReason: WaitReason.network),
    );

    expect(find.text('Waiting for Wi-Fi/mobile data'), findsOneWidget);
    await tester.tap(find.text('Retry now'));
    verify(cubit.retryNow).called(1);
  });

  testWidgets('lists failed items with their error', (tester) async {
    await pump(
      tester,
      const UploadStatusState(
        pending: 1,
        waitReason: WaitReason.attention,
        failed: [
          UploadItem(
            id: 'a',
            filename: 'IMG_0002.CR3',
            kind: CameraObjectKind.raw,
            captureDay: '2026-11-13',
            size: 1,
            sha256: '00',
            localPath: '/tmp/IMG_0002.CR3',
            destinationFingerprint: 'f',
            state: UploadState.savedToGallery,
            lastError: 'Access denied.',
            needsAttention: true,
          ),
        ],
      ),
    );

    expect(
      find.text(UploadStatusSheet.waitText(WaitReason.attention)),
      findsOneWidget,
    );
    expect(find.text('IMG_0002.CR3'), findsOneWidget);
    expect(find.text('Access denied.'), findsOneWidget);
  });

  testWidgets('offers to remove kept copies', (tester) async {
    await pump(tester, const UploadStatusState(keptCopies: 3));

    expect(find.text('All photos are uploaded.'), findsOneWidget);
    await tester.tap(find.text('Remove 3 kept copies'));
    verify(cubit.removeKeptCopies).called(1);
  });

  test('every wait reason has a text', () {
    for (final reason in WaitReason.values) {
      expect(UploadStatusSheet.waitText(reason), isNotEmpty);
    }
  });
}
