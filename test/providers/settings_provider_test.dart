import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/user_settings_model.dart';
import 'package:planflow/data/repositories/settings_repository.dart';
import 'package:planflow/providers/settings_provider.dart';

void main() {
  test('load stores fetched settings and updates loading state', () async {
    final repository = _FakeSettingsRepository(
      fetched: const UserSettingsModel(
        id: 'settings-1',
        userId: 'user-1',
        morningBriefingAt: '06:30',
        eveningBriefingAt: '20:30',
        defaultReminderMin: 30,
      ),
    );
    final provider = SettingsProvider(repository);

    final loaded = await provider.load('user-1');

    expect(loaded, isNotNull);
    expect(provider.settings?.morningBriefingAt, '06:30');
    expect(provider.isLoading, isFalse);
    expect(repository.fetchUserIds.single, 'user-1');
  });

  test('save stores the returned settings and updates saving state', () async {
    final repository = _FakeSettingsRepository();
    final provider = SettingsProvider(repository);

    final saved = await provider.save(
      const UserSettingsModel(
        id: '',
        userId: 'user-1',
        morningBriefingAt: '07:00',
        eveningBriefingAt: '21:00',
        defaultReminderMin: 60,
      ),
    );

    expect(saved.userId, 'user-1');
    expect(provider.settings?.eveningBriefingAt, '21:00');
    expect(provider.isSaving, isFalse);
    expect(repository.savedSettings?.morningBriefingAt, '07:00');
  });
}

class _FakeSettingsRepository extends SettingsRepository {
  _FakeSettingsRepository({this.fetched});

  final UserSettingsModel? fetched;
  UserSettingsModel? savedSettings;
  final List<String> fetchUserIds = <String>[];

  @override
  Future<UserSettingsModel?> fetchSettings(String userId) async {
    fetchUserIds.add(userId);
    return fetched;
  }

  @override
  Future<UserSettingsModel> upsertSettings(UserSettingsModel settings) async {
    savedSettings = settings;
    return settings.copyWith(id: 'settings-1');
  }
}
