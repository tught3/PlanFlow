// SettingsScreen이 공용 FAB 묶음(PlanFlowGlobalFabs)을 사용해
// "음성으로 일정 관리"와 "AI일정대화" 버튼을 각각 1개씩 렌더하는지 확인한다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'package:planflow/data/models/user_settings_model.dart';
import 'package:planflow/data/repositories/settings_repository.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/screens/settings/settings_screen.dart';
import 'package:planflow/services/briefing_scheduler_service.dart';
import 'package:planflow/services/calendar_sync_service.dart';
import 'package:planflow/services/naver_calendar_permission_service.dart';
import 'package:planflow/services/naver_caldav_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      Supabase.instance;
    } catch (_) {
      await Supabase.initialize(
        url: 'https://example.com',
        anonKey: 'public-anon-key',
        authOptions: const FlutterAuthClientOptions(
          detectSessionInUri: false,
          autoRefreshToken: false,
        ),
      );
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'PlanFlow',
      packageName: 'com.fluxstudio.planflow',
      version: '1.1.1',
      buildNumber: '48',
      buildSignature: '',
    );
  });

  testWidgets(
    'SettingsScreen renders one voice FAB and one AI conversation FAB',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            groupContextProvider: _fakeEmptyGroupContextProvider(),
            settingsRepository: _FakeSettingsRepository(
              fetched: const UserSettingsModel(
                id: 'settings-1',
                userId: 'user-1',
              ),
            ),
            briefingSchedulerService: _FakeBriefingSchedulerService(),
            calendarSyncService: _FakeCalendarSyncService(),
            notificationService: _FakeNotificationService(),
            naverCalDavService: _FakeNaverCalDavService(),
            userId: 'user-1',
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('음성으로 일정 관리'), findsOneWidget);
      expect(find.text('AI일정대화'), findsOneWidget);
    },
  );

  test('settings list reserves scroll space below the two global FABs', () {
    final source =
        File('lib/screens/settings/settings_screen.dart').readAsStringSync();
    expect(source, contains('AppConstants.defaultPadding + 220'));
  });
}

GroupContextProvider _fakeEmptyGroupContextProvider() =>
    GroupContextProvider(repository: _FakeGroupRepository());

class _FakeGroupRepository extends GroupRepository {
  @override
  Future<List<GroupModel>> listGroups() async => const <GroupModel>[];

  @override
  Future<GroupModel?> fetchGroup(String groupId) async => null;

  @override
  Future<GroupModel> createGroup(GroupModel group) {
    throw UnimplementedError();
  }

  @override
  Future<GroupModel> updateGroup(GroupModel group) {
    throw UnimplementedError();
  }

  @override
  Future<List<GroupMemberModel>> listMembers(String groupId) async {
    return const <GroupMemberModel>[];
  }

  @override
  Future<GroupMemberModel> addMember(GroupMemberModel member) {
    throw UnimplementedError();
  }

  @override
  Future<GroupMemberModel> updateMember(GroupMemberModel member) {
    throw UnimplementedError();
  }
}

class _FakeSettingsRepository extends SettingsRepository {
  _FakeSettingsRepository({this.fetched});

  final UserSettingsModel? fetched;

  @override
  Future<UserSettingsModel?> fetchSettings(String userId) async => fetched;

  @override
  Future<UserSettingsModel> upsertSettings(UserSettingsModel settings) async {
    return settings.copyWith(id: 'settings-1');
  }
}

class _FakeBriefingSchedulerService extends BriefingSchedulerService {
  @override
  Future<BriefingDailyScheduleResult> scheduleDaily({
    required String morningTime,
    required String eveningTime,
    bool briefingEnabled = true,
    String? userId,
  }) async {
    return BriefingDailyScheduleResult(
      morning: BriefingScheduleEntry(
        // banned-ok: FAB 렌더링만 검증하는 더미 fake 반환값(클램프/만료 로직 미경유)
        scheduledAt: DateTime(2026, 5, 7, 7,
            30), // banned-ok: FAB 렌더링만 검증, 미단언 더미 fake 반환값(클램프/만료 로직 미경유)
        scheduled: true,
      ),
      evening: BriefingScheduleEntry(
        // banned-ok: FAB 렌더링만 검증하는 더미 fake 반환값(클램프/만료 로직 미경유)
        scheduledAt:
            DateTime(2026, 5, 7, 21), // banned-ok: 위와 동일 사유(더미 fake 반환값, 미단언)
        scheduled: true,
      ),
    );
  }
}

class _FakeCalendarSyncService extends CalendarSyncService {
  _FakeCalendarSyncService()
      : super(
          naverStatusProvider: () async {
            return const NaverCalendarPermissionResult(
              status: NaverCalendarPermissionStatus.unknown,
              message: '테스트 권한 상태',
            );
          },
          naverAccessTokenProvider: () async => null,
          naverStatusSaver: (_) async {},
        );

  @override
  Future<CalendarSyncSummary> fetchStatus() async {
    return CalendarSyncSummary(
      google: CalendarIntegrationResult.signedOut(CalendarProvider.google),
      naver: CalendarIntegrationResult.signedOut(CalendarProvider.naver),
    );
  }
}

class _FakeNotificationService extends NotificationService {
  @override
  Future<NotificationPermissionStatus> checkPermissionStatus() async {
    return const NotificationPermissionStatus(
      notificationsEnabled: true,
      exactAlarmsEnabled: true,
      fullScreenIntentStatus: PermissionCheckState.needsManualCheck,
    );
  }
}

class _FakeNaverCalDavService extends NaverCalDavService {
  _FakeNaverCalDavService()
      : super(credentialStore: const _FakeNaverCalDavCredentialStore());

  @override
  Future<bool> hasCredentials() async => false;

  @override
  Future<void> dispose() async {}
}

class _FakeNaverCalDavCredentialStore implements NaverCalDavCredentialStore {
  const _FakeNaverCalDavCredentialStore();

  @override
  Future<void> clearCredentials() async {}

  @override
  Future<NaverCalDavCredentials?> readCredentials() async => null;

  @override
  Future<void> saveCredentials({
    required String naverId,
    required String appPassword,
  }) async {}
}
