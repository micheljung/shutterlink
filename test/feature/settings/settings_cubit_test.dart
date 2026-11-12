import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/settings/settings_cubit.dart';

void main() {
  late SettingsRepository settings;
  late SettingsCubit cubit;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
    cubit = SettingsCubit(settings);
  });

  tearDown(() => cubit.close());

  test('preview quality defaults to thumbnail and persists', () async {
    expect(cubit.state.previewQuality, PreviewQuality.thumbnail);

    await cubit.setPreviewQuality(PreviewQuality.full);

    expect(cubit.state.previewQuality, PreviewQuality.full);
    expect(settings.previewQuality, PreviewQuality.full);
    expect(SettingsCubit(settings).state.previewQuality, PreviewQuality.full);
  });

  test('changing one setting keeps the others', () async {
    await cubit.setPreviewQuality(PreviewQuality.full);
    await cubit.setHostOverride('10.0.0.9');
    await cubit.setFormat(DownloadFormat.raw);

    expect(
      cubit.state,
      const SettingsState(
        format: DownloadFormat.raw,
        previewQuality: PreviewQuality.full,
        hostOverride: '10.0.0.9',
      ),
    );
  });
}
