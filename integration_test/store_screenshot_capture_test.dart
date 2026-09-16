import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planflow/features/groups/screens/group_dashboard_screen.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/providers/group_dashboard_provider.dart';
import 'package:planflow/features/groups/repositories/group_dashboard_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/l10n/app_localizations.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/screens/calendar/calendar_screen.dart';
import 'package:planflow/screens/home/home_screen.dart';
import 'package:planflow/screens/voice/confirm_screen.dart';
import 'package:planflow/services/home_header_summary_service.dart';
import 'package:planflow/services/smart_preparation_alarm_service.dart';

import '_harness/screenshot_helper.dart';

/// CI-only Store screenshot driver.
///
/// This deliberately does not call [runPlanFlowApp], authenticate, initialize
/// Supabase, or use production configuration.  It mounts the same PlanFlow
/// screen widgets with their existing offline-safe seams and a fictional,
/// fixed fixture.  The workflow selects one case per simulator invocation via
/// STORE_SCREENSHOT_ID, then captures the simulator surface with simctl.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final screenshotId = const String.fromEnvironment('STORE_SCREENSHOT_ID');

  testWidgets('renders deterministic PlanFlow store fixture', (tester) async {
    if (screenshotId.isEmpty) {
      throw StateError('STORE_SCREENSHOT_ID is required for capture');
    }

    await tester.pumpWidget(_fixtureFor(screenshotId));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    switch (screenshotId) {
      case 'iphone69-calendar-home':
        expect(find.text('팀 주간 회의'), findsOneWidget);
        break;
      case 'iphone69-voice-confirm':
        expect(find.text('팀 주간 회의'), findsOneWidget);
        break;
      case 'iphone69-group':
      case 'ipad13-group':
        expect(find.text('PlanFlow 데모 그룹'), findsOneWidget);
        break;
      case 'ipad13-calendar':
        expect(
          find.byKey(
            const ValueKey('calendar-personal-event-store-fixture-event'),
          ),
          findsOneWidget,
        );
        break;
    }
    await E2eScreenshotHelper(binding).capture(screenshotId);
  });
}

Widget _fixtureFor(String id) {
  Widget screen;
  switch (id) {
    case 'iphone69-calendar-home':
      screen = HomeScreen(
        userIdOverride: 'store-fixture-user',
        loadHeaderSummary: false,
        headerSummaryOverride: const HomeHeaderSummary(
          weatherLabel: '맑음 22°',
          detailLine: '오늘은 일정에 집중하기 좋은 날이에요.',
          isReady: true,
          locationLabel: '판교',
          weatherIcon: Icons.wb_sunny_outlined,
        ),
        // banned-ok: Store screenshot pixels require a fixed calendar date.
        nowProvider: () => DateTime.utc(2026, 9, 21, 1),
        eventRepository: _OfflineEventRepository(),
        smartPreparationAlarmService: const _FakeSmartPreparationAlarmService(),
        groupContextProvider: GroupContextProvider(
          repository: const _OfflineGroupRepository(),
        ),
      );
      break;
    case 'iphone69-voice-confirm':
      screen = ConfirmScreen(
        userId: 'store-fixture-user',
        parsedSchedule: <String, dynamic>{
          'parse_attempt_id': 'store-fixture-parse-attempt',
          'title': '팀 주간 회의',
          'start_at': '2026-09-21T01:00:00.000Z',
          'end_at': '2026-09-21T02:00:00.000Z',
          'location': '판교 회의실',
          'location_lat': 37.3947,
          'location_lng': 127.1112,
          'memo': '결정사항을 정리해요',
        },
        // banned-ok: Store screenshot pixels require a fixed calendar date.
        nowProvider: () => DateTime.utc(2026, 9, 21, 1),
        backend: const _OfflineConfirmBackend(),
      );
      break;
    case 'iphone69-group':
    case 'ipad13-group':
      screen = GroupDashboardScreen(
        currentUserIdOverride: 'store-fixture-user',
        provider: GroupDashboardProvider(
          contextProvider: GroupContextProvider(
            repository: _OfflineGroupRepository(),
          ),
          repository: _OfflineGroupDashboardRepository(),
        ),
      );
      break;
    case 'ipad13-calendar':
      screen = CalendarScreen(
        userId: 'store-fixture-user',
        suppressInitialDaySheet: true,
        // banned-ok: Store screenshot pixels require a fixed calendar date.
        initialDate: DateTime(2026, 9, 21),
        eventRepository: _OfflineEventRepository(),
      );
      break;
    default:
      throw ArgumentError('Unsupported STORE_SCREENSHOT_ID: $id');
  }

  return MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('ko', 'KR'),
    supportedLocales: const <Locale>[Locale('ko', 'KR'), Locale('en', 'US')],
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    theme: ThemeData.light(useMaterial3: true),
    home: Scaffold(
      body: Stack(
        children: <Widget>[
          screen,
          const SizedBox(
            key: ValueKey('store-capture-ready'),
            width: 0,
            height: 0,
          ),
        ],
      ),
    ),
  );
}

/// ConfirmScreen's write methods are never reached by this read-only capture,
/// but the explicit implementation makes that boundary visible and prevents
/// accidental fallback to Supabase in future fixture edits.
class _OfflineConfirmBackend extends ConfirmScreenBackend {
  const _OfflineConfirmBackend();

  @override
  Future<List<String>> fetchPastSupplies({
    required String userId,
    required String location,
  }) async =>
      <String>[];

  @override
  Future<void> insertPreActions(List<Map<String, dynamic>> payloads) async {}

  @override
  Future<void> insertReminders(List<Map<String, dynamic>> payloads) async {}

  @override
  Future<void> insertLocationHistory(Map<String, dynamic> payload) async {}

  @override
  Future<void> insertVoiceLog(Map<String, dynamic> payload) async {}
}

class _FakeSmartPreparationAlarmService extends SmartPreparationAlarmService {
  const _FakeSmartPreparationAlarmService();

  @override
  Future<Set<String>> listEventIdsWithSmartAlarms({
    required String userId,
    required Iterable<String> eventIds,
  }) async =>
      const <String>{};
}

class _OfflineEventRepository extends EventRepository {
  const _OfflineEventRepository();

  @override
  Future<List<EventModel>> listEvents({String? userId}) async =>
      <EventModel>[_fixtureEvent];

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async =>
      null;

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}

  @override
  Future<EventModel> updateSuppliesChecked({
    required String eventId,
    required List<String> suppliesChecked,
    String? userId,
  }) async {
    throw StateError('store screenshot fixture is read-only');
  }
}

final _fixtureEvent = EventModel(
  id: 'store-fixture-event',
  userId: 'store-fixture-user',
  title: '팀 주간 회의',
  // banned-ok: Store screenshot pixels require a fixed calendar date.
  startAt: DateTime.utc(2026, 9, 21, 1),
  // banned-ok: Store screenshot pixels require a fixed calendar date.
  endAt: DateTime.utc(2026, 9, 21, 2),
  location: '판교 회의실',
  locationLat: 37.3947,
  locationLng: 127.1112,
  memo: '결정사항을 정리해요',
);

class _OfflineGroupRepository extends GroupRepository {
  const _OfflineGroupRepository();

  @override
  Future<List<GroupModel>> listGroups() async => <GroupModel>[_fixtureGroup];

  @override
  Future<GroupModel?> fetchGroup(String groupId) async => null;

  @override
  Future<GroupModel> createGroup(GroupModel group) async => group;

  @override
  Future<GroupModel> updateGroup(GroupModel group) async => group;

  @override
  Future<List<GroupMemberModel>> listMembers(String groupId) async =>
      <GroupMemberModel>[_fixtureMember];

  @override
  Future<GroupMemberModel> addMember(GroupMemberModel member) async => member;

  @override
  Future<GroupMemberModel> updateMember(GroupMemberModel member) async =>
      member;
}

class _OfflineGroupDashboardRepository extends GroupDashboardRepository {
  const _OfflineGroupDashboardRepository();

  @override
  Future<GroupDashboardSummary> loadDashboard({
    required String groupId,
    required DateTime now,
  }) async =>
      GroupDashboardSummary(
        todayEventCount: 1,
        weekEventCount: 1,
        memberCount: 1,
        upcomingEvents: <GroupEventModel>[_fixtureGroupEvent],
      );

  @override
  Future<List<GroupEventModel>> fetchMemberEvents({
    required String groupId,
    required String memberUserId,
    required DateTime from,
    required DateTime to,
  }) async =>
      <GroupEventModel>[];
}

const _fixtureGroup = GroupModel(
  id: 'store-fixture-group',
  createdBy: 'store-fixture-user',
  name: 'PlanFlow 데모 그룹',
);
const _fixtureMember = GroupMemberModel(
  id: 'store-fixture-member',
  groupId: 'store-fixture-group',
  userId: 'store-fixture-user',
  role: 'leader',
  displayName: '데모 사용자',
);
final _fixtureGroupEvent = GroupEventModel(
  id: 'store-fixture-group-event',
  groupId: 'store-fixture-group',
  title: '그룹 일정 공유',
  // banned-ok: Store screenshot pixels require a fixed calendar date.
  startAt: DateTime.utc(2026, 9, 21, 5),
  // banned-ok: Store screenshot pixels require a fixed calendar date.
  endAt: DateTime.utc(2026, 9, 21, 6),
  createdBy: 'store-fixture-user',
);
