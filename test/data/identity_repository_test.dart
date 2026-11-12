import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/identity_repository.dart';

void main() {
  const guidLength = 16;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('generates a 16-byte GUID once and reuses it after restart', () async {
    final first = await IdentityRepository(
      await SharedPreferences.getInstance(),
    ).identity();
    final again = await IdentityRepository(
      await SharedPreferences.getInstance(),
    ).identity();

    expect(first.guid, hasLength(guidLength));
    expect(first.name, IdentityRepository.friendlyName);
    expect(again, first);
  });

  test('restores the GUID persisted in preferences', () async {
    final prefs = await SharedPreferences.getInstance();
    final created = await IdentityRepository(prefs).identity();
    final stored = prefs.getString(IdentityRepository.guidKey);

    SharedPreferences.setMockInitialValues({
      IdentityRepository.guidKey: stored!,
    });
    final restored = await IdentityRepository(
      await SharedPreferences.getInstance(),
    ).identity();

    expect(restored.guid, created.guid);
  });
}
