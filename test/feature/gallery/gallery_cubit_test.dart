import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/gallery/gallery_cubit.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/ptpip/canon_eos.dart';

import '../../fakes/fake_camera_client.dart';

class _DroppingClient extends FakeCameraClient {
  _DroppingClient(super.objects, {required this.dropAt});

  final int dropAt;

  @override
  Future<void> delete(int handle) async {
    if (handle == dropAt) throw const CameraDisconnectedException();
    await super.delete(handle);
  }
}

class _FailingClient extends FakeCameraClient {
  _FailingClient(super.objects, {required this.failAt});

  final int failAt;

  @override
  Future<void> delete(int handle) async {
    if (handle == failAt) {
      throw const PtpResponseException(
        PtpOperation.deleteObject,
        PtpResponseCode.deviceBusy,
      );
    }
    await super.delete(handle);
  }
}

class _BrokenClient extends FakeCameraClient {
  _BrokenClient(super.objects, {required this.breakAt});

  final int breakAt;

  @override
  Future<void> delete(int handle) async {
    if (handle == breakAt) throw StateError('broken');
    await super.delete(handle);
  }
}

void main() {
  final pair = [
    cameraObject(1, 'IMG_0001.JPG'),
    cameraObject(2, 'IMG_0001.CR3'),
  ];
  final single = cameraObject(3, 'IMG_0002.JPG');
  final raw = cameraObject(4, 'IMG_0003.CR3');

  Future<GalleryCubit> loaded(FakeCameraClient client) async {
    final cubit = GalleryCubit(client);
    await cubit.load();
    return cubit;
  }

  test('deletes both files of a pair and drops the deleted groups', () async {
    final client = FakeCameraClient([...pair, single, raw]);
    final cubit = await loaded(client);
    cubit.selectAll();
    final doomed = cubit.state.groups
        .where((group) => group.raw?.handle != raw.handle)
        .toList();

    final outcome = await cubit.delete(doomed);

    expect(outcome, (denied: 0, failed: 0, disconnected: false));
    expect(client.deleted, unorderedEquals([1, 2, 3]));
    expect(cubit.state.groups.map((group) => group.raw), [raw]);
    expect(cubit.state.selected, {cubit.state.groups.single.key});
    expect(cubit.state.deleting, isFalse);
  });

  test('a refused file keeps its group and selection', () async {
    final client = FakeCameraClient([...pair, single])..deleteDenied = {2};
    final cubit = await loaded(client);
    cubit.selectAll();

    final outcome = await cubit.delete(cubit.state.selectedGroups);

    expect(outcome, (denied: 1, failed: 0, disconnected: false));
    expect(client.deleted, unorderedEquals([1, 3]));
    final left = cubit.state.groups.single;
    expect(left.jpeg, isNull);
    expect(left.raw?.handle, 2);
    expect(cubit.state.selected, {left.key});
  });

  test('a disconnect stops and counts the rest as failed', () async {
    final client = _DroppingClient([...pair, single, raw], dropAt: 3);
    final cubit = await loaded(client);

    final outcome = await cubit.delete(cubit.state.groups);

    expect(client.deleted, [raw.handle]);
    expect(outcome, (denied: 0, failed: 2, disconnected: true));
    expect(cubit.state.groups, hasLength(2));
  });

  test('reports deleting while it runs', () async {
    final client = FakeCameraClient([single])..deleteGate = Completer<void>();
    final cubit = await loaded(client);

    final deletion = cubit.delete(cubit.state.groups);
    expect(cubit.state.deleting, isTrue);
    client.deleteGate!.complete();
    await deletion;

    expect(cubit.state.deleting, isFalse);
    expect(cubit.state.groups, isEmpty);
  });

  test('other errors are counted apart from refusals', () async {
    final client = _FailingClient([single, raw], failAt: single.handle);
    final cubit = await loaded(client);

    final outcome = await cubit.delete(cubit.state.groups);

    expect(outcome, (denied: 0, failed: 1, disconnected: false));
    expect(cubit.state.groups.single.jpeg, single);
  });

  test('an error stops deleting and keeps what was deleted', () async {
    final client = _BrokenClient([single, raw], breakAt: single.handle);
    final cubit = await loaded(client);

    await expectLater(cubit.delete(cubit.state.groups), throwsStateError);

    expect(cubit.state.deleting, isFalse);
    expect(cubit.state.groups.single.jpeg, single);
  });

  test('a regrouping shot keeps its key and selection', () async {
    final date = DateTime(2026, 1, 1);
    final first = cameraObject(5, 'IMG_0009.JPG', captureDate: date);
    final twin = cameraObject(6, 'IMG_0009.JPG', captureDate: date);
    final client = FakeCameraClient([first, twin]);
    final cubit = await loaded(client);
    final kept = cubit.state.groups.firstWhere((g) => g.jpeg == twin);
    cubit.setSelected([kept], true);

    await cubit.delete(cubit.state.groups.where((g) => g != kept).toList());

    expect(cubit.state.groups.single.key, kept.key);
    expect(cubit.state.selected, {kept.key});
  });
}
