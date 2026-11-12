import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/gallery/day_section.dart';
import 'package:shutterlink/feature/gallery/photo_group.dart';

import '../../fakes/fake_camera_client.dart';

void main() {
  final evening = DateTime(2026, 5, 2, 21);
  final morning = DateTime(2026, 5, 2, 7);
  final dayBefore = DateTime(2026, 5, 1, 23, 59);

  test('groups shots by local calendar day, newest first', () {
    final groups = groupPhotos([
      cameraObject(1, 'IMG_0001.JPG', captureDate: dayBefore),
      cameraObject(2, 'IMG_0002.JPG', captureDate: morning),
      cameraObject(3, 'IMG_0003.JPG', captureDate: evening),
    ]);

    final sections = sectionsOf(groups);

    expect(sections.map((section) => section.day), [
      DateTime(2026, 5, 2),
      DateTime(2026, 5, 1),
    ]);
    expect(sections.first.groups.map((group) => group.baseName), [
      'IMG_0003',
      'IMG_0002',
    ]);
  });

  test('puts shots without a date last', () {
    final groups = groupPhotos([
      cameraObject(1, 'IMG_0001.JPG'),
      cameraObject(2, 'IMG_0002.JPG', captureDate: morning),
      cameraObject(3, 'IMG_0003.JPG'),
    ]);

    final sections = sectionsOf(groups);

    expect(sections.map((section) => section.day), [
      DateTime(2026, 5, 2),
      null,
    ]);
    expect(sections.last.groups, hasLength(2));
  });

  test('keeps the gallery order when flattened', () {
    final groups = groupPhotos([
      cameraObject(1, 'IMG_0001.JPG', captureDate: dayBefore),
      cameraObject(2, 'IMG_0002.JPG'),
      cameraObject(3, 'IMG_0003.JPG', captureDate: evening),
      cameraObject(4, 'IMG_0004.JPG', captureDate: morning),
      cameraObject(5, 'IMG_0005.JPG'),
    ]);

    final sections = sectionsOf(groups);

    expect(sections.expand((section) => section.groups), groups);
  });

  test('has no sections without photos', () {
    expect(sectionsOf(const []), isEmpty);
  });
}
