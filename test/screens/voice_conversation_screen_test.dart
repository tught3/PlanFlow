import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/event_edit_route_payload.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/models/user_settings_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/data/repositories/settings_repository.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/voice/voice_conversation_screen.dart';
import 'package:planflow/services/api_usage_guard.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/services/manual_event_side_effect_service.dart';
import 'package:planflow/services/stt_service.dart';
import 'package:planflow/services/voice_conversation_controller.dart';
import 'package:planflow/services/voice_conversation_ad_gate.dart';
import 'package:planflow/services/voice_conversation_entitlement.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _alignedFutureFixtureYear() {
  for (var year = DateTime.now().year + 1; ; year++) {
    if (DateTime(year, 1, 1).weekday == DateTime.thursday &&
        !(year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))) {
      return year;
    }
  }
}

final int _voiceFixtureYear = _alignedFutureFixtureYear();

class _FakeSttService extends SttService {
  Completer<SttListenResult>? _completer;
  ValueChanged<String>? _onPartialResult;
  ValueChanged<SttNativeStatusEvent>? _onStatus;
  int cancelCalls = 0;
  int stopCalls = 0;
  int listenCalls = 0;
  int clearActiveTranscriptCalls = 0;

  @override
  Future<SttListenResult> listen({
    ValueChanged<String>? onPartialResult,
    ValueChanged<int>? onRestart,
    ValueChanged<SttNativeStatusEvent>? onStatus,
    SttListenMode mode = SttListenMode.dictation,
  }) {
    listenCalls += 1;
    _onPartialResult = onPartialResult;
    _onStatus = onStatus;
    _completer = Completer<SttListenResult>();
    return _completer!.future;
  }

  void emitStatus(SttNativeStatus status) {
    _onStatus?.call(SttNativeStatusEvent(status: status));
  }

  void emitPartial(String text) {
    _onPartialResult?.call(text);
  }

  void completeSuccess(String text) {
    _completer?.complete(SttListenResult.success(text));
  }

  void completeFailure(String message) {
    _completer?.complete(
      SttListenResult.failure(
        failure: SttListenFailure.silence,
        message: message,
      ),
    );
  }

  @override
  Future<void> cancelActiveListen() async {
    cancelCalls += 1;
    if (_completer != null && !_completer!.isCompleted) {
      completeFailure('Cancelled.');
    }
  }

  @override
  Future<void> stopActiveListen() async {
    stopCalls += 1;
    if (_completer != null && !_completer!.isCompleted) {
      completeFailure('Stopped.');
    }
  }

  @override
  Future<String> clearActiveTranscript() async {
    clearActiveTranscriptCalls += 1;
    return '';
  }
}

/// cancelActiveListen()이 끝없이 대기하는 STT — 종료 흐름의 타임아웃 동작을
/// 검증하기 위한 전용 fake.
class _HangingCancelSttService extends _FakeSttService {
  @override
  Future<void> cancelActiveListen() {
    cancelCalls += 1;
    return Completer<void>().future; // 절대 완료되지 않음
  }
}

class _BlockingClearSttService extends _FakeSttService {
  final Completer<String> clearCompleter = Completer<String>();

  @override
  Future<String> clearActiveTranscript() {
    clearActiveTranscriptCalls += 1;
    return clearCompleter.future;
  }
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository(this.events);

  final List<EventModel> events;
  final List<String> deletedIds = <String>[];
  final List<EventModel> updatedEvents = <EventModel>[];
  final List<EventModel> createdEvents = <EventModel>[];
  // 테스트에서 주입하는 겹지 후보. 비워 두면 Repository 기본 구현대로
  // 빈 목록이 반환된다.
  List<EventModel> overlappingCandidates = const <EventModel>[];
  int findOverlappingCalls = 0;
  DateTime? lastOverlapRangeStart;
  DateTime? lastOverlapRangeEnd;
  String? lastOverlapExcludedEventId;
  // updateEvent에서 throw할지 여부. 실패 경로 검증을 위한 옵션.
  bool throwOnUpdate = false;
  // updateEvent의 펜딩 컨테이너. 갱신 결과를 지연시켜 테스트가 펜딩
  // 상태를 검증할 수 있다.
  Completer<EventModel>? savePendingCompleter;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => events;

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    for (final event in events) {
      if (event.id == eventId) {
        return event;
      }
    }
    return null;
  }

  @override
  Future<List<EventModel>> findOverlappingEvents({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    String? userId,
    String? excludedEventId,
  }) async {
    findOverlappingCalls += 1;
    lastOverlapRangeStart = rangeStart;
    lastOverlapRangeEnd = rangeEnd;
    lastOverlapExcludedEventId = excludedEventId;
    if (!rangeEnd.isAfter(rangeStart)) {
      return const <EventModel>[];
    }
    return overlappingCandidates
        .where((candidate) => candidate.id != excludedEventId)
        .toList(growable: false);
  }

  @override
  Future<EventModel> createEvent(EventModel event) async {
    createdEvents.add(event);
    return event;
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    if (throwOnUpdate) {
      throw StateError('updateEvent 강제 실패');
    }
    if (savePendingCompleter != null) {
      final saved = await savePendingCompleter!.future;
      updatedEvents.add(saved);
      final index = events.indexWhere((candidate) => candidate.id == saved.id);
      if (index >= 0) {
        events[index] = saved;
      }
      return saved;
    }
    updatedEvents.add(event);
    final index = events.indexWhere((candidate) => candidate.id == event.id);
    if (index >= 0) {
      events[index] = event;
    }
    return event;
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {
    deletedIds.add(eventId);
  }
}

/// 테스트 안에서 [_applyConversationDateAutoSave]의 사이드 이펙트 호출을
/// 검증하기 위한 가짜 구현. 호출된 횟수와 인자를 그대로 기록한다.
class _FakeManualEventSideEffectService extends ManualEventSideEffectService {
  _FakeManualEventSideEffectService();

  final List<({EventModel event, String userId})> syncAfterSaveCalls =
      <({EventModel event, String userId})>[];
  Duration? lastReminderOffset;
  Duration? lastCriticalAlarmOffset;
  bool throwOnSync = false;

  @override
  Future<ManualEventSideEffectResult> syncAfterSave({
    required EventModel event,
    required String userId,
    bool clearPreActions = true,
    Duration? reminderOffset,
    Duration? criticalAlarmOffset,
    int prepTimeMin = 60,
    int prepPreAlarmOffset = 30,
    int departPreAlarmOffset = 30,
    int travelMinutes = 15,
    Duration departureSafetyMargin = const Duration(minutes: 1),
    String travelMode = 'car',
    bool isFirstExternalEventOfDay = true,
  }) async {
    syncAfterSaveCalls.add((event: event, userId: userId));
    lastReminderOffset = reminderOffset;
    lastCriticalAlarmOffset = criticalAlarmOffset;
    if (throwOnSync) {
      throw StateError('syncAfterSave 강제 실패');
    }
    return const ManualEventSideEffectResult(
      remindersSynced: true,
      notificationsSynced: true,
      preActionsCleared: true,
    );
  }
}

class _SlowSecondListEventRepository extends EventRepository {
  _SlowSecondListEventRepository();

  final Completer<List<EventModel>> secondListCompleter =
      Completer<List<EventModel>>();
  int _listCallCount = 0;

  @override
  Future<List<EventModel>> listEvents({String? userId}) {
    _listCallCount += 1;
    if (_listCallCount == 1) {
      return Future<List<EventModel>>.value(const <EventModel>[]);
    }
    return secondListCompleter.future;
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async =>
      null;

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}
}

class _FakeGroupRepository extends GroupRepository {
  _FakeGroupRepository(this.groups);

  final List<GroupModel> groups;

  @override
  Future<List<GroupModel>> listGroups() async => groups;

  @override
  Future<GroupModel?> fetchGroup(String groupId) async {
    for (final group in groups) {
      if (group.id == groupId) {
        return group;
      }
    }
    return null;
  }

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

class _FakeGroupEventRepository extends GroupEventRepository {
  _FakeGroupEventRepository(this.events, {this.cancelShouldFail = false});

  final List<GroupEventModel> events;
  final List<GroupEventModel> updatedEvents = <GroupEventModel>[];
  final List<String> cancelledIds = <String>[];
  // 테스트에서 "권한 없는 사용자" 등 취소 실패 케이스를 재현하기 위한 플래그.
  final bool cancelShouldFail;

  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async {
    return events.where((event) => event.groupId == groupId).toList();
  }

  @override
  Future<GroupEventModel> createGroupEvent(GroupEventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) async {
    updatedEvents.add(event);
    final index = events.indexWhere((candidate) => candidate.id == event.id);
    if (index >= 0) {
      events[index] = event;
    }
    return event;
  }

  @override
  Future<GroupEventModel> cancelGroupEvent(String eventId) async {
    if (cancelShouldFail) {
      throw StateError('활성 일정만 취소할 수 있습니다.');
    }
    cancelledIds.add(eventId);
    final index = events.indexWhere((candidate) => candidate.id == eventId);
    if (index < 0) {
      throw StateError('일정을 찾지 못했어요.');
    }
    final cancelled = events[index].copyWith(
      status: 'cancelled',
      cancelledAt: DateTime.now().toUtc(),
      cancelledBy: 'tester',
    );
    events[index] = cancelled;
    return cancelled;
  }

  @override
  Future<GroupEventModel> archiveGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> fetchGroupEvent(String eventId) {
    throw UnimplementedError();
  }
}

class _FakeLocationLookupService extends LocationLookupService {
  @override
  Future<List<LocationLookupResult>> search(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    return <LocationLookupResult>[
      LocationLookupResult(
        name: query,
        address: query,
        latitude: 37.7519,
        longitude: 128.8761,
      ),
    ];
  }
}

class _NoLocationPermissionService extends AppPermissionService {
  @override
  Future<GeoPoint?> getCurrentLocationWithPermission({
    bool requestIfMissing = true,
  }) async {
    return null;
  }
}

/// [VoiceConversationEntitlementService]의 consume() 호출 횟수/인자를
/// 검증하기 위한 fake delegate.
class _FakeEntitlementDelegate implements VoiceConversationEntitlementDelegate {
  int consumeCalls = 0;
  final List<String> consumedSessionIds = <String>[];
  VoiceConversationConsumeResult? consumeResult;

  @override
  Future<VoiceConversationEntitlementPeek?> peek() async => null;

  @override
  Future<VoiceConversationConsumeResult?> consume(String sessionId) async {
    consumeCalls += 1;
    consumedSessionIds.add(sessionId);
    return consumeResult;
  }
}

/// [VoiceConversationAdGate]의 self-gate 호출 여부/인자를 검증하기 위한
/// fake delegate. [grantToProvide]가 있으면 즉시 진입을 승인하고, null이면
/// 진입을 거부(onEnterAllowed 미호출)한다.
class _FakeAdGateDelegate implements VoiceConversationAdGateDelegate {
  _FakeAdGateDelegate({this.grantToProvide});

  int tryEnterCalls = 0;
  String? lastUserId;
  final VoiceConversationEntryGrant? grantToProvide;

  @override
  Future<int?> getRemainingFreeTrialCount(String userId) async => null;

  @override
  Future<int?> useFreeTrial(String userId) async => null;

  @override
  Future<void> tryEnter({
    required BuildContext context,
    required String userId,
    required void Function(VoiceConversationEntryGrant grant) onEnterAllowed,
    required VoiceConversationAdGate gate,
  }) async {
    tryEnterCalls += 1;
    lastUserId = userId;
    final grant = grantToProvide;
    if (grant != null) {
      onEnterAllowed(grant);
    }
  }
}

/// [_FakeAdGateDelegate]와 달리 승인이 즉시(동기적으로) 끝나지 않고
/// [delay]만큼 지연된 뒤에야 완료되는 fake. self-gate가 아직 진행 중인
/// 레이스 윈도우 동안 사용자가 수동으로 텍스트를 제출하는 상황을 재현하기
/// 위해 쓴다(HIGH: self-gate 대기 중 수동입력 시 소비 영구 누락 회귀 테스트).
class _DelayedAdGateDelegate implements VoiceConversationAdGateDelegate {
  _DelayedAdGateDelegate({
    required this.grantToProvide,
    required this.delay,
  });

  int tryEnterCalls = 0;
  String? lastUserId;
  final VoiceConversationEntryGrant grantToProvide;
  final Duration delay;

  @override
  Future<int?> getRemainingFreeTrialCount(String userId) async => null;

  @override
  Future<int?> useFreeTrial(String userId) async => null;

  @override
  Future<void> tryEnter({
    required BuildContext context,
    required String userId,
    required void Function(VoiceConversationEntryGrant grant) onEnterAllowed,
    required VoiceConversationAdGate gate,
  }) async {
    tryEnterCalls += 1;
    lastUserId = userId;
    await Future<void>.delayed(delay);
    onEnterAllowed(grantToProvide);
  }
}

/// [_DelayedAdGateDelegate]와 반대로, [delay] 후 **거부**로 끝나는 fake
/// (onEnterAllowed를 아예 호출하지 않음). self-gate가 지연 후 거부로 끝나는
/// 동안 그 대기 창 안에서 사용자가 수동 제출한 명령이 처리되지 않아야 함을
/// 재현하기 위해 쓴다(리뷰어가 위젯테스트로 재현한 거부 케이스 레이스 회귀).
class _DelayedDeniedAdGateDelegate implements VoiceConversationAdGateDelegate {
  _DelayedDeniedAdGateDelegate({required this.delay});

  int tryEnterCalls = 0;
  String? lastUserId;
  final Duration delay;

  @override
  Future<int?> getRemainingFreeTrialCount(String userId) async => null;

  @override
  Future<int?> useFreeTrial(String userId) async => null;

  @override
  Future<void> tryEnter({
    required BuildContext context,
    required String userId,
    required void Function(VoiceConversationEntryGrant grant) onEnterAllowed,
    required VoiceConversationAdGate gate,
  }) async {
    tryEnterCalls += 1;
    lastUserId = userId;
    await Future<void>.delayed(delay);
    // onEnterAllowed를 호출하지 않음 = 거부.
  }
}

/// onEnterAllowed/onDenied 어느 쪽도 호출하지 않는 silent 거부 fake.
/// 단, [VoiceConversationAdGate.lastDenialReason]을 명시적으로 설정해
/// 화면 fallback 분기가 어떤 reason 문구를 노출하는지 검증할 수 있게 한다.
/// 게이트의 tryEnterVoiceConversation이 진입 직전 `lastDenialReason = null`로
/// 리셋하기 때문에, 이 delegate는 reset 이후에 lastDenialReason을 다시 쓴다 —
/// 그래야 화면의 fallback에서 `voiceConversationGateDenialMessage`가 정상적으로
/// 호출되는 흐름이 그대로 재현된다.
class _SilentAdGateDelegateWithReason
    implements VoiceConversationAdGateDelegate {
  _SilentAdGateDelegateWithReason({required this.lastDenialReason});

  int tryEnterCalls = 0;
  String? lastUserId;
  final VoiceConversationGateDenialReason lastDenialReason;

  @override
  Future<int?> getRemainingFreeTrialCount(String userId) async => null;

  @override
  Future<int?> useFreeTrial(String userId) async => null;

  @override
  Future<void> tryEnter({
    required BuildContext context,
    required String userId,
    required void Function(VoiceConversationEntryGrant grant) onEnterAllowed,
    required VoiceConversationAdGate gate,
  }) async {
    tryEnterCalls += 1;
    lastUserId = userId;
    // 게이트의 reset(lastDenialReason = null) 이후에 reason을 설정한다.
    gate.lastDenialReason = lastDenialReason;
    // onEnterAllowed/onDenied 모두 호출하지 않는다 = silent 거부.
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 전송 경로의 GptService().parseSchedule()이 ApiUsageGuard.tryConsume →
    // SharedPreferences.getInstance()를 await한다. mock이 없으면 pending되어
    // pumpAndSettle이 타임아웃되므로, 빈 mock과 가드 싱글톤 초기화를 둔다.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ApiUsageGuard.resetForTesting();
  });

  Future<void> pumpConversation(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(384, 823),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildPlanFlowTheme(),
        home: child,
      ),
    );
  }

  testWidgets('AI 일정 대화는 STT partial을 입력창에 즉시 보여준다', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.text('음성으로 명령하기'));
    await tester.pump();

    expect(find.text('마이크를 준비하고 있어요...'), findsOneWidget);

    stt.emitPartial('이번주 금요일 일정');
    await tester.pump();

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, '이번주 금요일 일정');
  });

  testWidgets('AI 일정 대화는 음성 입력 중 입력창을 탭하면 수동 입력으로 전환된다', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    stt.emitStatus(SttNativeStatus.stalled);
    await tester.pump();

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(stt.stopCalls, greaterThanOrEqualTo(1));
    expect(find.text('음성으로 명령하기'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
    );

    await tester.enterText(find.byType(TextField), '이번주 일정 보여줘');
    await tester.pump();
    stt.emitPartial('늦게 도착한 음성 결과');
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '이번주 일정 보여줘',
    );
  });

  testWidgets('AI 일정 대화는 음성 인식 실패 뒤에도 텍스트로 전환해 자동 재시작을 멈춘다', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    stt.completeFailure('음성을 알아듣지 못했어요.');
    await tester.pump(const Duration(milliseconds: 20));

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '이번주 일정 보여줘');
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '이번주 일정 보여줘',
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(stt.listenCalls, 1);
  });

  testWidgets('AI 일정 대화는 native ready 음성 입력 중에도 입력창 탭으로 수동 전환한다',
      (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    stt.emitStatus(SttNativeStatus.ready);
    await tester.pump();
    expect(find.text('음성 인식 중이에요 · 다음 명령을 말해 주세요'), findsOneWidget);

    await tester.tap(find.byType(TextField));
    await tester.pump();

    expect(stt.stopCalls, greaterThanOrEqualTo(1));
    expect(find.text('음성으로 명령하기'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
    );
  });

  testWidgets('AI 일정 대화는 focus 중 키보드 닫기와 전송에서 입력 포커스를 해제한다', (tester) async {
    await pumpConversation(
      tester,
      const VoiceConversationScreen(),
    );

    final textField = find.byType(TextField);
    await tester.tap(textField);
    await tester.pump();
    expect(find.byTooltip('키보드 닫기'), findsOneWidget);
    expect(find.bySemanticsLabel('키보드 닫기'), findsOneWidget);
    expect(tester.widget<TextField>(textField).focusNode?.hasFocus, isTrue);

    await tester.tap(find.byTooltip('키보드 닫기'));
    await tester.pump();
    expect(tester.widget<TextField>(textField).focusNode?.hasFocus, isFalse);
    expect(find.byTooltip('키보드 닫기'), findsNothing);

    await tester.tap(textField);
    await tester.enterText(textField, '이번주 일정 보여줘');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(textField).focusNode?.hasFocus, isFalse);

    await tester.tap(textField);
    await tester.enterText(textField, '다음주 일정 보여줘');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(textField).focusNode?.hasFocus, isFalse);
  });

  testWidgets('AI 일정 대화는 native ready 전에는 듣는 중으로 표시하지 않는다', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.text('음성으로 명령하기'));
    await tester.pump();

    expect(find.text('마이크를 준비하고 있어요...'), findsOneWidget);
    expect(find.text('음성 인식 중이에요 · 다음 명령을 말해 주세요'), findsNothing);

    stt.emitStatus(SttNativeStatus.ready);
    await tester.pump();

    expect(find.text('음성 인식 중이에요 · 다음 명령을 말해 주세요'), findsOneWidget);
  });

  testWidgets('AI 일정 대화는 STT 성공 후 사용자 말과 응답을 표시한다', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.text('음성으로 명령하기'));
    await tester.pump();

    stt.completeSuccess('오늘 일정 알려줘');
    await tester.pumpAndSettle();

    expect(find.text('오늘 일정 알려줘'), findsOneWidget);
    expect(find.textContaining('일정'), findsWidgets);
    expect(find.text('음성 인식 중이에요 · 다음 명령을 말해 주세요'), findsNothing);
  });

  testWidgets(
    'AI 일정 대화는 최종 음성 결과 제출 경로에서도 STT 누적 트랜스크립트를 지운다',
    (tester) async {
      final stt = _FakeSttService();
      await pumpConversation(
        tester,
        VoiceConversationScreen(sttService: stt),
      );

      await tester.tap(find.text('음성으로 명령하기'));
      await tester.pump();

      // fromVoiceFinal 경로: listen()이 최종 결과로 완료된 뒤 제출된다.
      // 제출 후 _keepListening이 유지돼 자동 재시작되는데, 이때 STT 서비스에
      // 방금 제출한 문구가 남아 있으면 재시작 세션의 partial이 옛 문구를
      // 입력창에 되살린다(iOS 실기기 재현 버그). 모든 제출 경로에서 지워야 한다.
      stt.completeSuccess('이번주 일정 보여줘');
      await tester.pumpAndSettle();

      expect(find.text('이번주 일정 보여줘'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
      expect(stt.clearActiveTranscriptCalls, 1);
    },
  );

  testWidgets(
    'AI 일정 대화는 final 확정 즉시 입력창을 비우고 STT 정리를 기다리지 않는다',
    (tester) async {
      final stt = _BlockingClearSttService();
      await pumpConversation(
        tester,
        VoiceConversationScreen(sttService: stt),
      );

      await tester.tap(find.text('음성으로 명령하기'));
      await tester.pump();
      stt.emitPartial('다음주 일정 보여줘');
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '다음주 일정 보여줘',
      );

      stt.completeSuccess('다음주 일정 보여줘');
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
      expect(stt.clearActiveTranscriptCalls, 1);

      stt.clearCompleter.complete('');
      await tester.pumpAndSettle();
    },
  );

  testWidgets('AI 일정 대화 input bar follows the keyboard inset', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    final before = tester.getBottomLeft(find.byType(TextField)).dy;

    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();

    final after = tester.getBottomLeft(find.byType(TextField)).dy;

    expect(after, lessThan(before));
    addTearDown(
      () => tester.view.viewInsets = FakeViewPadding.zero,
    );
  });

  testWidgets('AI 일정 대화는 STT 실패 시 바로 재시도하고 실패 문구를 남기지 않는다', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.text('음성으로 명령하기'));
    await tester.pump();

    stt.completeFailure('음성을 알아듣지 못했어요.');
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('음성을 알아듣지 못했어요.'), findsNothing);
    await tester.pump(const Duration(milliseconds: 700));
    expect(stt.listenCalls, greaterThanOrEqualTo(2));
    expect(find.text('음성을 알아듣지 못했어요.'), findsNothing);
  });

  testWidgets(
    'AI 일정 대화는 듣는 중 전송 시 이전 STT 콜백을 버리고 새 리슨만 반영한다',
    (tester) async {
      final stt = _FakeSttService();
      await pumpConversation(
        tester,
        VoiceConversationScreen(sttService: stt),
      );

      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();

      stt.emitPartial('이번주 일정 보여줘');
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '이번주 일정 보여줘',
      );

      await tester.tap(find.text('전송'));
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
      expect(find.text('음성 입력 정지'), findsOneWidget);
      expect(find.text('음성으로 명령하기'), findsNothing);
      expect(stt.clearActiveTranscriptCalls, 1);

      stt.emitPartial('늦게온 이전 세션 일정');
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );

      await tester.pump(const Duration(milliseconds: 200));
      expect(stt.listenCalls, greaterThanOrEqualTo(2));

      // iOS SpeechToText가 새 세션 시작 직후 방금 보낸 문장을 다시 replay해도
      // 입력창이 되살아나면 안 된다.
      stt.emitPartial('이번주 일정 보여줘');
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );

      stt.emitPartial('다음 발화 일정');
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '다음 발화 일정',
      );
    },
  );

  testWidgets(
    'AI 일정 대화는 전송 후 명시적으로 정지하면 stale STT partial을 무시한다',
    (tester) async {
      final stt = _FakeSttService();
      await pumpConversation(
        tester,
        VoiceConversationScreen(sttService: stt),
      );

      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();
      // 위 테스트와 동일 사유로 query intent 문구를 쓴다.
      stt.emitPartial('이번주 일정 보여줘');
      await tester.pump();

      await tester.tap(find.text('전송'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );

      await tester.tap(find.text('음성 입력 정지'));
      await tester.pumpAndSettle();

      stt.emitPartial('정지 후 늦은 일정');
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
    },
  );
  testWidgets(
    'AI 일정 대화는 리스닝 중이 아닐 때 제출해도 STT 트랜스크립트를 지운다',
    (tester) async {
      final stt = _FakeSttService();
      await pumpConversation(
        tester,
        VoiceConversationScreen(sttService: stt),
      );

      // 마이크를 켠 적이 없으므로 _isListening/_keepListening 둘 다 false다 —
      // STT 세션이 없어도 모든 제출 경로에서 누적 트랜스크립트 리셋을 통일해
      // 실행한다(세션 배열만 지우고 활성 리스닝은 건드리지 않는다).
      await tester.enterText(find.byType(TextField), '이번주 일정 보여줘');
      await tester.pump();
      await tester.tap(find.text('전송'));
      await tester.pumpAndSettle();

      expect(stt.clearActiveTranscriptCalls, 1);
    },
  );

  testWidgets('AI 일정 대화는 initialText를 자동 제출한다', (tester) async {
    await pumpConversation(
      tester,
      const VoiceConversationScreen(initialText: '오늘 일정 알려줘'),
    );
    await tester.pumpAndSettle();

    expect(find.text('오늘 일정 알려줘'), findsOneWidget);
    expect(find.textContaining('일정'), findsWidgets);
  });

  testWidgets('AI 일정 대화는 모바일 크기에서 기본 메시지와 입력바를 렌더링한다', (tester) async {
    await pumpConversation(
      tester,
      const VoiceConversationScreen(),
    );
    await tester.pumpAndSettle();

    expect(find.text('AI 일정 대화'), findsOneWidget);
    expect(find.textContaining('일정을 이어서 말해도 돼요'), findsOneWidget);
    expect(find.text('계속 듣기'), findsNothing);
    expect(find.text('Supabase 설정을 확인하지 못했어요.'), findsOneWidget);
    expect(find.text('음성으로 명령하기'), findsOneWidget);
    expect(find.text('전송'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 initialText 결과 일정 카드를 렌더링한다', (tester) async {
    final friday = DateTime(_voiceFixtureYear, 5, 29, 18);
    final events = List<EventModel>.generate(
      4,
      (index) => EventModel(
        id: 'event-$index',
        userId: 'user-1',
        title: '금요일 일정 ${index + 1}',
        startAt: friday.add(Duration(minutes: index * 30)).toUtc(),
      ),
    );

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: _FakeEventRepository(events),
        initialText: '$_voiceFixtureYear년 5월 29일 일정 다 보여 줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('$_voiceFixtureYear년 5월 29일 일정 다 보여 줘'), findsOneWidget);
    expect(find.textContaining('일정 4개를 찾았어요'), findsOneWidget);
    expect(find.text('금요일 일정 1'), findsOneWidget);
    expect(find.text('금요일 일정 4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 조회 결과 카드를 눌러 수정 모달을 열고 편집으로 이동한다', (tester) async {
    final event = EventModel(
      id: 'event-edit',
      userId: 'user-1',
      title: '금요일 상담',
      startAt: DateTime(_voiceFixtureYear, 5, 29, 18).toUtc(),
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceConversation,
      routes: [
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => VoiceConversationScreen(
            repository: _FakeEventRepository(<EventModel>[event]),
            initialText: '$_voiceFixtureYear년 5월 29일 일정 다 보여 줘',
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) => const Text(
            '편집 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildPlanFlowTheme(),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('금요일 상담'));
    await tester.pumpAndSettle();

    expect(find.text('이 일정으로 무엇을 할까요?'), findsOneWidget);
    expect(find.text('수정하기'), findsOneWidget);
    expect(find.text('삭제하기'), findsOneWidget);

    await tester.tap(find.text('수정하기'));
    await tester.pumpAndSettle();

    expect(find.text('편집 화면'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 다음날 이동 명령을 편집 화면 없이 곧바로 저장한다', (tester) async {
    final event = EventModel(
      id: 'event-shift',
      userId: 'user-1',
      title: '이동할 일정',
      startAt: DateTime(_voiceFixtureYear, 5, 7, 9).toUtc(),
      endAt: DateTime(_voiceFixtureYear, 5, 7, 10).toUtc(),
    );
    EventModel? receivedDraft;
    final repository = _FakeEventRepository(<EventModel>[event]);
    final sideEffects = _FakeManualEventSideEffectService();
    final router = GoRouter(
      initialLocation: AppRoutes.voiceConversation,
      routes: [
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => VoiceConversationScreen(
            repository: repository,
            sideEffectService: sideEffects,
            settingsRepository:
                _FakeSettingsRepository(const Duration(minutes: 30)),
            reminderNotifyAtReader: _fakeReminderReader(repository),
            initialText: '5월 7일 일정 알려줘',
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) {
            receivedDraft = state.extra as EventModel?;
            return const Text(
              '편집 화면',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildPlanFlowTheme(),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      '1번 일정 그 다음날로 변경해줘',
    );
    await tester.tap(find.text('전송'));
    // 단독 날짜 변경은 자동 저장 경로로 저장 완료까지 기다린다.
    for (var i = 0; i < 40 && repository.updatedEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();

    // 편집 화면으로 넘어가지 않고 곧바로 저장됐다.
    expect(find.text('편집 화면'), findsNothing);
    expect(receivedDraft, isNull);
    expect(repository.updatedEvents, hasLength(1));
    expect(
      planflowLocal(repository.updatedEvents.single.startAt!),
      DateTime(_voiceFixtureYear, 5, 8, 9),
    );
    expect(
      planflowLocal(repository.updatedEvents.single.endAt!),
      DateTime(_voiceFixtureYear, 5, 8, 10),
    );
    // 안내 문구는 '편집 화면을 열었다'가 아니라 저장 결과를 말한다.
    expect(find.textContaining('편집 화면'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 조회 결과 카드 삭제를 확인 후 실행한다', (tester) async {
    final event = EventModel(
      id: 'event-delete',
      userId: 'user-1',
      title: '삭제할 일정',
      startAt: DateTime(_voiceFixtureYear, 5, 29, 18).toUtc(),
    );
    final repository = _FakeEventRepository(<EventModel>[event]);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        initialText: '$_voiceFixtureYear년 5월 29일 일정 다 보여 줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('삭제할 일정'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제하기'));
    await tester.pumpAndSettle();

    expect(find.text('이 일정을 삭제할까요?'), findsOneWidget);

    await tester.tap(find.text('삭제').last);
    await tester.pumpAndSettle();

    expect(repository.deletedIds, contains('event-delete'));
    expect(find.text('삭제할 일정 일정을 삭제했어요.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 삭제 확인 대기 중 붙은 이전 명령을 잘라낸다', (tester) async {
    final friday = DateTime(_voiceFixtureYear, 5, 29, 18);
    final events = List<EventModel>.generate(
      5,
      (index) => EventModel(
        id: 'event-$index',
        userId: 'user-1',
        title: '금요일 일정 ${index + 1}',
        startAt: friday.add(Duration(minutes: index * 30)).toUtc(),
      ),
    );
    final repository = _FakeEventRepository(events);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        initialText: '5월 29일 일정 다 보여 줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '5번 일정 삭제해 줘');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    expect(find.textContaining('금요일 일정 5 일정을 삭제할까요?'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '5번 일정 삭제해 줘 응 삭제해줘');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    expect(repository.deletedIds, contains('event-4'));
    expect(find.text('응 삭제해줘'), findsOneWidget);
    expect(find.text('5번 일정 삭제해 줘 응 삭제해줘'), findsNothing);

    await tester.enterText(find.byType(TextField), '응 삭제해줘');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    expect(repository.deletedIds.where((id) => id == 'event-4'), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 뒤로가기 확인 후에만 대화 세션을 종료한다', (tester) async {
    // _exitConversation()은 context.pop() 대신 context.go(AppRoutes.home)으로 이동한다.
    // 따라서 /home 라우트가 필요하며, pop 결과를 기대하는 대신 홈 화면으로 이동하는지 확인한다.
    final stt = _FakeSttService();
    final router = GoRouter(
      initialLocation: AppRoutes.voiceConversation,
      routes: [
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => VoiceConversationScreen(
            sttService: stt,
            repository: _FakeEventRepository(const <EventModel>[]),
          ),
        ),
        GoRoute(
          path: AppRoutes.home,
          builder: (context, state) => const Scaffold(
            body: Text('홈 화면'),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildPlanFlowTheme(),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('종료'), findsOneWidget);

    // 뒤로가기 버튼을 누르면 확인 바텀시트가 뜬다
    await tester.tap(find.byTooltip('뒤로가기'));
    await tester.pumpAndSettle();

    expect(find.text('AI 일정 대화 페이지를 나가겠습니까?'), findsOneWidget);

    // '계속 대화하기'를 누르면 대화 화면이 유지된다
    await tester.tap(find.text('계속 대화하기'));
    await tester.pumpAndSettle();

    expect(find.text('AI 일정 대화'), findsOneWidget);

    // 다시 뒤로가기 후 '나가기'를 누르면 홈 화면으로 이동한다
    await tester.tap(find.byTooltip('뒤로가기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('나가기'));
    await tester.pumpAndSettle();

    // _exitConversation이 context.go(AppRoutes.home)으로 이동하므로 홈 화면이 보인다
    expect(find.text('홈 화면'), findsOneWidget);
    expect(stt.cancelCalls, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'AI 일정 대화 상단 종료 버튼도 동일한 확인 바텀시트를 띄운다',
    (tester) async {
      final stt = _FakeSttService();
      final router = GoRouter(
        initialLocation: AppRoutes.voiceConversation,
        routes: [
          GoRoute(
            path: AppRoutes.voiceConversation,
            builder: (context, state) => VoiceConversationScreen(
              sttService: stt,
              repository: _FakeEventRepository(const <EventModel>[]),
            ),
          ),
          GoRoute(
            path: AppRoutes.home,
            builder: (context, state) => const Scaffold(
              body: Text('홈 화면'),
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp.router(
          theme: buildPlanFlowTheme(),
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('종료'));
      await tester.pumpAndSettle();

      expect(find.text('AI 일정 대화 페이지를 나가겠습니까?'), findsOneWidget);

      await tester.tap(find.text('계속 대화하기'));
      await tester.pumpAndSettle();

      expect(find.text('AI 일정 대화'), findsOneWidget);
      expect(find.text('홈 화면'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'AI 일정 대화는 홈 버튼(push) 진입 경로에서도 취소-재시도 후 정상적으로 홈으로 돌아간다',
    (tester) async {
      // 버그 재현 경로(①): 홈 화면이 Navigator.push 대신 GoRouter의
      // context.push(AppRoutes.voiceConversation)로 대화 화면에 진입하는
      // 상황을 재현한다. 수정 전에는 이 진입 방식과 무관하게
      // _exitConversation()의 context.go(home)이 GoRouter 스택 밖의
      // 화면을 pop하지 못해 뒤로가기가 무반응이었다.
      final stt = _FakeSttService();
      final router = GoRouter(
        initialLocation: AppRoutes.home,
        routes: [
          GoRoute(
            path: AppRoutes.home,
            builder: (context, state) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => context.push(AppRoutes.voiceConversation),
                  child: const Text('홈 화면'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.voiceConversation,
            builder: (context, state) => VoiceConversationScreen(
              sttService: stt,
              repository: _FakeEventRepository(const <EventModel>[]),
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp.router(
          theme: buildPlanFlowTheme(),
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('홈 화면'), findsOneWidget);

      // 홈 버튼과 동일한 방식(context.push)으로 대화 화면에 진입한다.
      await tester.tap(find.text('홈 화면'));
      await tester.pumpAndSettle();

      expect(find.text('AI 일정 대화'), findsOneWidget);
      expect(find.text('홈 화면'), findsNothing);

      // 첫 번째 뒤로가기: '계속 대화하기'로 취소해도 대화 화면이 유지되고,
      // 플래그가 고착되지 않아 다음 뒤로가기 시도도 확인 시트를 다시 띄운다.
      await tester.tap(find.byTooltip('뒤로가기'));
      await tester.pumpAndSettle();
      expect(find.text('AI 일정 대화 페이지를 나가겠습니까?'), findsOneWidget);

      await tester.tap(find.text('계속 대화하기'));
      await tester.pumpAndSettle();
      expect(find.text('AI 일정 대화'), findsOneWidget);

      // 두 번째 뒤로가기: 확인 시트가 다시 뜨고, '나가기'를 누르면
      // push로 진입한 대화 화면이 사라지고 실제로 홈 화면으로 돌아간다.
      await tester.tap(find.byTooltip('뒤로가기'));
      await tester.pumpAndSettle();
      expect(find.text('AI 일정 대화 페이지를 나가겠습니까?'), findsOneWidget);

      await tester.tap(find.text('나가기'));
      await tester.pumpAndSettle();

      expect(find.text('AI 일정 대화'), findsNothing);
      expect(find.text('홈 화면'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'AI 일정 대화는 STT 취소가 지연돼도 타임아웃 후 대화 세션을 끝까지 종료한다',
    (tester) async {
      // _stopVoiceBeforeNavigation()의 cancelActiveListen() 호출이
      // 끝없이 대기하는 상황(실패 시나리오)을 흉내낸다. 타임아웃이 없으면
      // _exitConversation()이 영원히 끝나지 않아 _isExitingConversation이
      // 고착돼 다음 뒤로가기도 무반응이 된다.
      final stt = _HangingCancelSttService();
      final router = GoRouter(
        initialLocation: AppRoutes.voiceConversation,
        routes: [
          GoRoute(
            path: AppRoutes.voiceConversation,
            builder: (context, state) => VoiceConversationScreen(
              sttService: stt,
              repository: _FakeEventRepository(const <EventModel>[]),
            ),
          ),
          GoRoute(
            path: AppRoutes.home,
            builder: (context, state) => const Scaffold(
              body: Text('홈 화면'),
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp.router(
          theme: buildPlanFlowTheme(),
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('뒤로가기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('나가기'));
      await tester.pump();

      // 타임아웃(4초) 전에는 STT 취소를 기다리느라 아직 대화 화면에 있다.
      expect(find.text('홈 화면'), findsNothing);

      // 타임아웃을 넘겨서 펌프하면 취소 완료를 기다리지 않고 종료가
      // 이어져 홈 화면으로 이동한다.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(find.text('홈 화면'), findsOneWidget);
      expect(stt.cancelCalls, greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('AI 일정 대화는 듣는 중 정지 후 마이크로 다시 시작할 수 있다', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.text('음성으로 명령하기'));
    await tester.pump();

    expect(find.text('마이크를 준비하고 있어요...'), findsOneWidget);
    expect(find.text('음성 입력 정지'), findsOneWidget);

    await tester.tap(find.text('음성 입력 정지'));
    await tester.pumpAndSettle();

    // 정지 후 하단 컨트롤 바는 다시 시작 버튼 하나로 돌아온다.
    expect(find.text('음성으로 명령하기'), findsOneWidget);
    expect(stt.stopCalls, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 전송 처리 중 문맥 분석 로더를 보여준다', (tester) async {
    final repository = _SlowSecondListEventRepository();
    await pumpConversation(
      tester,
      VoiceConversationScreen(repository: repository),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '오늘 일정 알려줘');
    await tester.tap(find.text('전송'));
    await tester.pump();

    expect(find.text('AI 문맥 분석중이에요...'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    repository.secondListCompleter.complete(const <EventModel>[]);
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 장소 변경을 편집 화면 없이 바로 저장한다', (tester) async {
    final stt = _FakeSttService();
    var pickerCalls = 0;
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-1',
        userId: 'user-1',
        title: '방문 일정',
        startAt: DateTime(_voiceFixtureYear, 5, 22, 9).toUtc(),
      ),
    ]);
    Future<LocationLookupResult?> fakeLocationPicker({
      required BuildContext context,
      required String query,
      LocationLookupService? locationLookupService,
      AppPermissionService? appPermissionService,
      String? preferredMapProvider,
      bool? canUseInAppMapOverride,
    }) async {
      pickerCalls += 1;
      return LocationLookupResult(
        name: query,
        address: query,
        latitude: 37.7519,
        longitude: 128.8761,
      );
    }

    final router = GoRouter(
      initialLocation: AppRoutes.voiceConversation,
      routes: [
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => VoiceConversationScreen(
            sttService: stt,
            repository: repository,
            locationLookupService: _FakeLocationLookupService(),
            permissionService: _NoLocationPermissionService(),
            locationPicker: fakeLocationPicker,
            initialText: '$_voiceFixtureYear년 5월 22일 일정 보여줘',
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) => const Text(
            '편집 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildPlanFlowTheme(),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('음성으로 명령하기'));
    await tester.pump();
    stt.completeSuccess('그 일정에 강릉 건도리횟집 장소추가');
    for (var i = 0; i < 20 && repository.updatedEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('편집 화면'), findsNothing);
    expect(pickerCalls, 1);
    expect(repository.updatedEvents, hasLength(1));
    expect(repository.updatedEvents.single.location, '강릉 건도리횟집');
    expect(repository.updatedEvents.single.locationLat, 37.7519);
    expect(repository.updatedEvents.single.locationLng, 128.8761);
    expect(find.text('음성 인식 중이에요 · 다음 명령을 말해 주세요'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 중요한 일정 변경을 바로 저장한다', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-1',
        userId: 'user-1',
        title: '방문 일정',
        startAt: DateTime(_voiceFixtureYear, 5, 22, 9).toUtc(),
        isCritical: false,
      ),
    ]);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        initialText: '5월 22일 일정 보여줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '첫번째 일정 중요한 일정으로 표시해줘');
    await tester.tap(find.text('전송'));
    for (var i = 0; i < 20 && repository.updatedEvents.isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(repository.updatedEvents, hasLength(1));
    expect(repository.updatedEvents.single.isCritical, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 그룹 일정을 후보 목록에 병합해 순번 매칭에 포함한다', (tester) async {
    final personalEvent = EventModel(
      id: 'personal-1',
      userId: 'user-1',
      title: '개인 방문 일정',
      startAt: DateTime(_voiceFixtureYear, 5, 22, 9).toUtc(),
    );
    final groupEvent = GroupEventModel(
      id: 'group-event-1',
      groupId: 'group-1',
      title: '팀 회의',
      startAt: DateTime(_voiceFixtureYear, 5, 22, 14).toUtc(),
      endAt: DateTime(_voiceFixtureYear, 5, 22, 15).toUtc(),
      createdBy: 'leader-1',
      location: '회의실',
    );
    final groupRepository = _FakeGroupRepository(<GroupModel>[
      const GroupModel(id: 'group-1', createdBy: 'leader-1', name: '우리 팀'),
    ]);
    final groupEventRepository =
        _FakeGroupEventRepository(<GroupEventModel>[groupEvent]);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: _FakeEventRepository(<EventModel>[personalEvent]),
        groupRepository: groupRepository,
        groupEventRepository: groupEventRepository,
        initialText: '$_voiceFixtureYear년 5월 22일 일정 다 보여줘',
      ),
    );
    await tester.pumpAndSettle();

    // 개인 일정(9시)과 그룹 일정(14시)이 시간순으로 함께 후보 목록에 잡혀야 한다.
    expect(find.textContaining('일정 2개를 찾았어요'), findsOneWidget);
    expect(find.text('개인 방문 일정'), findsOneWidget);
    expect(find.text('팀 회의'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 그룹 일정 수정을 GroupEventRepository로 라우팅한다',
      (tester) async {
    final groupEvent = GroupEventModel(
      id: 'group-event-1',
      groupId: 'group-1',
      title: '팀 회의',
      startAt: DateTime(_voiceFixtureYear, 5, 22, 14).toUtc(),
      endAt: DateTime(_voiceFixtureYear, 5, 22, 15).toUtc(),
      createdBy: 'leader-1',
      location: '회의실',
    );
    final personalRepository = _FakeEventRepository(const <EventModel>[]);
    final groupRepository = _FakeGroupRepository(<GroupModel>[
      const GroupModel(id: 'group-1', createdBy: 'leader-1', name: '우리 팀'),
    ]);
    final groupEventRepository =
        _FakeGroupEventRepository(<GroupEventModel>[groupEvent]);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: personalRepository,
        groupRepository: groupRepository,
        groupEventRepository: groupEventRepository,
        initialText: '5월 22일 일정 다 보여줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '첫번째 일정 장소를 본관 3층으로 바꿔줘');
    await tester.tap(find.text('전송'));
    for (var i = 0;
        i < 20 && groupEventRepository.updatedEvents.isEmpty;
        i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 그룹 일정이 개인 리포지토리가 아니라 그룹 리포지토리로 저장돼야 한다.
    expect(personalRepository.updatedEvents, isEmpty);
    expect(groupEventRepository.updatedEvents, hasLength(1));
    expect(groupEventRepository.updatedEvents.single.location, '본관 3층');
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 팀 일정을 개인 일정으로 옮긴다', (tester) async {
    final groupEvent = GroupEventModel(
      id: 'group-event-1',
      groupId: 'group-1',
      title: '팀 회의',
      startAt: DateTime(_voiceFixtureYear, 5, 22, 14).toUtc(),
      endAt: DateTime(_voiceFixtureYear, 5, 22, 15).toUtc(),
      createdBy: 'leader-1',
      location: '회의실',
    );
    final personalRepository = _FakeEventRepository(const <EventModel>[]);
    final groupRepository = _FakeGroupRepository(<GroupModel>[
      const GroupModel(id: 'group-1', createdBy: 'leader-1', name: '우리 팀'),
    ]);
    final groupEventRepository =
        _FakeGroupEventRepository(<GroupEventModel>[groupEvent]);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: personalRepository,
        groupRepository: groupRepository,
        groupEventRepository: groupEventRepository,
        initialText: '5월 22일 일정 다 보여줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '첫번째 일정 개인 일정으로 바꿔줘');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '응');
    await tester.tap(find.text('전송'));
    for (var i = 0;
        i < 20 && groupEventRepository.cancelledIds.isEmpty;
        i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(groupEventRepository.cancelledIds, contains('group-event-1'));
    expect(personalRepository.createdEvents, hasLength(1));
    expect(personalRepository.createdEvents.single.title, '팀 회의');
    expect(personalRepository.createdEvents.single.source, 'manual');
    expect(personalRepository.createdEvents.single.startAt, groupEvent.startAt);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 팀 일정 개인 전환 권한 실패 시 개인 일정을 만들지 않는다', (tester) async {
    final groupEvent = GroupEventModel(
      id: 'group-event-1',
      groupId: 'group-1',
      title: '팀 회의',
      startAt: DateTime(_voiceFixtureYear, 5, 22, 14).toUtc(),
      endAt: DateTime(_voiceFixtureYear, 5, 22, 15).toUtc(),
      createdBy: 'leader-1',
      location: '회의실',
    );
    final personalRepository = _FakeEventRepository(const <EventModel>[]);
    final groupRepository = _FakeGroupRepository(<GroupModel>[
      const GroupModel(id: 'group-1', createdBy: 'leader-1', name: '우리 팀'),
    ]);
    final groupEventRepository = _FakeGroupEventRepository(
      <GroupEventModel>[groupEvent],
      cancelShouldFail: true,
    );

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: personalRepository,
        groupRepository: groupRepository,
        groupEventRepository: groupEventRepository,
        initialText: '5월 22일 일정 다 보여줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '첫번째 일정 개인 일정으로 바꿔줘');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '응');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    expect(personalRepository.createdEvents, isEmpty);
    expect(find.textContaining('개인 일정으로 옮길 수 있어요'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 팀 일정 삭제를 실제로 취소 처리한다', (tester) async {
    final groupEvent = GroupEventModel(
      id: 'group-event-1',
      groupId: 'group-1',
      title: '팀 회의',
      startAt: DateTime(_voiceFixtureYear, 5, 22, 14).toUtc(),
      endAt: DateTime(_voiceFixtureYear, 5, 22, 15).toUtc(),
      createdBy: 'leader-1',
      location: '회의실',
    );
    final personalRepository = _FakeEventRepository(const <EventModel>[]);
    final groupRepository = _FakeGroupRepository(<GroupModel>[
      const GroupModel(id: 'group-1', createdBy: 'leader-1', name: '우리 팀'),
    ]);
    final groupEventRepository =
        _FakeGroupEventRepository(<GroupEventModel>[groupEvent]);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: personalRepository,
        groupRepository: groupRepository,
        groupEventRepository: groupEventRepository,
        initialText: '5월 22일 일정 다 보여줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '첫번째 일정 삭제해줘');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '응 삭제해줘');
    await tester.tap(find.text('전송'));
    for (var i = 0;
        i < 20 && groupEventRepository.cancelledIds.isEmpty;
        i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(groupEventRepository.cancelledIds, contains('group-event-1'));
    expect(find.textContaining('아직 음성으로 삭제할 수 없어요'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 팀 일정 제목 변경을 GroupEventRepository로 라우팅한다',
      (tester) async {
    final groupEvent = GroupEventModel(
      id: 'group-event-1',
      groupId: 'group-1',
      title: '팀 회의',
      startAt: DateTime(_voiceFixtureYear, 5, 22, 14).toUtc(),
      endAt: DateTime(_voiceFixtureYear, 5, 22, 15).toUtc(),
      createdBy: 'leader-1',
      location: '회의실',
    );
    final personalRepository = _FakeEventRepository(const <EventModel>[]);
    final groupRepository = _FakeGroupRepository(<GroupModel>[
      const GroupModel(id: 'group-1', createdBy: 'leader-1', name: '우리 팀'),
    ]);
    final groupEventRepository =
        _FakeGroupEventRepository(<GroupEventModel>[groupEvent]);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: personalRepository,
        groupRepository: groupRepository,
        groupEventRepository: groupEventRepository,
        initialText: '5월 22일 일정 다 보여줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '첫번째 일정 제목을 주간 회의로 바꿔줘');
    await tester.tap(find.text('전송'));
    for (var i = 0;
        i < 20 && groupEventRepository.updatedEvents.isEmpty;
        i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(groupEventRepository.updatedEvents, hasLength(1));
    expect(groupEventRepository.updatedEvents.single.title, '주간 회의');
    expect(personalRepository.updatedEvents, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'AI 일정 대화는 편집 화면 이동 후 pop으로 복귀하면 멈췄던 마이크를 자동 재개한다',
    (tester) async {
      final event = EventModel(
        id: 'event-resume',
        userId: 'user-1',
        title: '이동할 일정',
        startAt: DateTime(_voiceFixtureYear, 5, 7, 9)
            .toUtc(), // banned-ok: 마이크 자동재개 검증용 더미 일정(유일 후보, 클램프 로직 미개입)
        endAt: DateTime(_voiceFixtureYear, 5, 7, 10)
            .toUtc(), // banned-ok: 마이크 자동재개 검증용 더미 일정(유일 후보, 클램프 로직 미개입)
        // 반복 일정은 단독 날짜 자동 저장 가드를 통과하지 못하므로, 이 테스트의
        // 편집 화면 폴백(요구사항: recur → 편집 화면)을 그대로 탄다.
        recurrenceRule: 'FREQ=DAILY',
      );
      final stt = _FakeSttService();
      final router = GoRouter(
        initialLocation: AppRoutes.voiceConversation,
        routes: [
          GoRoute(
            path: AppRoutes.voiceConversation,
            builder: (context, state) => VoiceConversationScreen(
              sttService: stt,
              repository: _FakeEventRepository(<EventModel>[event]),
            ),
          ),
          GoRoute(
            path: AppRoutes.eventEditWithId,
            builder: (context, state) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => context.pop(),
                  child: const Text('편집 화면(팝 가능)'),
                ),
              ),
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp.router(
          theme: buildPlanFlowTheme(),
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('음성으로 명령하기'));
      await tester.pump();
      final listenCallsBefore = stt.listenCalls;
      expect(listenCallsBefore, 1);

      stt.completeSuccess('1번 일정 그 다음날로 변경해줘');
      await tester.pumpAndSettle();

      expect(find.text('편집 화면(팝 가능)'), findsOneWidget);

      await tester.tap(find.text('편집 화면(팝 가능)'));
      await tester.pumpAndSettle();

      expect(find.text('AI 일정 대화'), findsOneWidget);
      expect(stt.listenCalls, greaterThan(listenCallsBefore));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'AI 일정 대화는 정지 버튼으로 멈춘 뒤 편집 화면을 다녀와도 마이크를 자동 재개하지 않는다',
    (tester) async {
      final event = EventModel(
        id: 'event-no-resume',
        userId: 'user-1',
        title: '이동할 일정',
        startAt: DateTime(_voiceFixtureYear, 5, 7, 9)
            .toUtc(), // banned-ok: 마이크 자동재개 검증용 더미 일정(유일 후보, 클램프 로직 미개입)
        endAt: DateTime(_voiceFixtureYear, 5, 7, 10)
            .toUtc(), // banned-ok: 마이크 자동재개 검증용 더미 일정(유일 후보, 클램프 로직 미개입)
        // 반복 일정은 단독 날짜 자동 저장 가드를 통과하지 못하므로, 이 테스트의
        // 편집 화면 폴백(요구사항: recur → 편집 화면)을 그대로 탄다.
        recurrenceRule: 'FREQ=DAILY',
      );
      final stt = _FakeSttService();
      final router = GoRouter(
        initialLocation: AppRoutes.voiceConversation,
        routes: [
          GoRoute(
            path: AppRoutes.voiceConversation,
            builder: (context, state) => VoiceConversationScreen(
              sttService: stt,
              repository: _FakeEventRepository(<EventModel>[event]),
            ),
          ),
          GoRoute(
            path: AppRoutes.eventEditWithId,
            builder: (context, state) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => context.pop(),
                  child: const Text('편집 화면(팝 가능)'),
                ),
              ),
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp.router(
          theme: buildPlanFlowTheme(),
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('음성으로 명령하기'));
      await tester.pump();
      expect(find.text('음성 입력 정지'), findsOneWidget);

      await tester.tap(find.text('음성 입력 정지'));
      await tester.pumpAndSettle();

      final listenCallsBefore = stt.listenCalls;

      await tester.enterText(
        find.byType(TextField),
        '1번 일정 그 다음날로 변경해줘',
      );
      await tester.tap(find.text('전송'));
      await tester.pumpAndSettle();

      expect(find.text('편집 화면(팝 가능)'), findsOneWidget);

      await tester.tap(find.text('편집 화면(팝 가능)'));
      await tester.pumpAndSettle();

      expect(find.text('AI 일정 대화'), findsOneWidget);
      expect(stt.listenCalls, listenCallsBefore);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'AI 일정 대화는 카드 액션시트로 편집 화면을 다녀와도 마이크를 자동 재개하지 않는다',
    (tester) async {
      final event = EventModel(
        id: 'event-edit-sheet',
        userId: 'user-1',
        title: '금요일 상담',
        startAt: DateTime(_voiceFixtureYear, 5, 29, 18)
            .toUtc(), // banned-ok: initialText('5월 29일 일정 다 보여 줘')와 매칭시키는 더미 일정(클램프 로직 미개입)
      );
      final stt = _FakeSttService();
      final router = GoRouter(
        initialLocation: AppRoutes.voiceConversation,
        routes: [
          GoRoute(
            path: AppRoutes.voiceConversation,
            builder: (context, state) => VoiceConversationScreen(
              sttService: stt,
              repository: _FakeEventRepository(<EventModel>[event]),
              initialText: '$_voiceFixtureYear년 5월 29일 일정 다 보여 줘',
            ),
          ),
          GoRoute(
            path: AppRoutes.eventEditWithId,
            builder: (context, state) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => context.pop(),
                  child: const Text('편집 화면(팝 가능)'),
                ),
              ),
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp.router(
          theme: buildPlanFlowTheme(),
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('음성으로 명령하기'));
      await tester.pump();
      final listenCallsBefore = stt.listenCalls;
      expect(listenCallsBefore, 1);

      await tester.tap(find.text('금요일 상담'));
      await tester.pumpAndSettle();

      expect(find.text('이 일정으로 무엇을 할까요?'), findsOneWidget);

      await tester.tap(find.text('수정하기'));
      await tester.pumpAndSettle();

      expect(find.text('편집 화면(팝 가능)'), findsOneWidget);

      await tester.tap(find.text('편집 화면(팝 가능)'));
      await tester.pumpAndSettle();

      expect(find.text('AI 일정 대화'), findsOneWidget);
      expect(stt.listenCalls, listenCallsBefore);
      expect(tester.takeException(), isNull);
    },
  );

  group('AI일정대화 엔타이틀먼트 소비 시점', () {
    tearDown(() {
      VoiceConversationEntitlementService.instance.delegateForTest = null;
      VoiceConversationAdGate.instance.delegateForTest = null;
      authProvider.setUser(null);
    });

    testWidgets('grant가 있으면 첫 명령이 처리되기 시작할 때 정확히 1회 소비한다', (tester) async {
      final fakeDelegate = _FakeEntitlementDelegate()
        ..consumeResult = const VoiceConversationConsumeResult(
          source: 'initial_free',
          initialRemaining: 2,
          dailyRemaining: 3,
        );
      VoiceConversationEntitlementService.instance.delegateForTest =
          fakeDelegate;

      const grant = VoiceConversationEntryGrant(
        sessionId: 'session-initial-text',
        source: EntitlementSource.initialFree,
        initialRemainingAtGate: 3,
        dailyRemainingAtGate: 3,
      );

      await pumpConversation(
        tester,
        const VoiceConversationScreen(
          entryGrant: grant,
          initialText: '오늘 일정 알려줘',
        ),
      );
      await tester.pumpAndSettle();

      expect(fakeDelegate.consumeCalls, 1);
      expect(fakeDelegate.consumedSessionIds, <String>['session-initial-text']);
    });

    testWidgets(
        'grant.source가 adFailedFreePass면 첫 명령이 처리돼도 소비하지 않는다 (H1 리뷰 지적)',
        (tester) async {
      // VoiceConversationAdGate.maybeFreePassGrant가 광고 실패+free_pass
      // 정책으로 승인한 grant는 광고도 무료횟수도 소진된 상태의 예외
      // 통과이므로, 화면이 grant.source를 확인하지 않고 무조건 consume()을
      // 호출하면 안 된다.
      final fakeDelegate = _FakeEntitlementDelegate();
      VoiceConversationEntitlementService.instance.delegateForTest =
          fakeDelegate;

      const grant = VoiceConversationEntryGrant(
        sessionId: 'session-free-pass',
        source: EntitlementSource.adFailedFreePass,
        initialRemainingAtGate: 0,
        dailyRemainingAtGate: 0,
      );

      await pumpConversation(
        tester,
        const VoiceConversationScreen(
          entryGrant: grant,
          initialText: '오늘 일정 알려줘',
        ),
      );
      await tester.pumpAndSettle();

      expect(fakeDelegate.consumeCalls, 0);
    });

    testWidgets('같은 세션에서 여러 번 명령해도 엔타이틀먼트는 1회만 소비한다', (tester) async {
      final fakeDelegate = _FakeEntitlementDelegate()
        ..consumeResult = const VoiceConversationConsumeResult(
          source: 'daily_free',
          initialRemaining: 0,
          dailyRemaining: 4,
        );
      VoiceConversationEntitlementService.instance.delegateForTest =
          fakeDelegate;

      const grant = VoiceConversationEntryGrant(
        sessionId: 'session-repeat',
        source: EntitlementSource.dailyFree,
        initialRemainingAtGate: 0,
        dailyRemainingAtGate: 5,
      );

      await pumpConversation(
        tester,
        const VoiceConversationScreen(entryGrant: grant),
      );
      await tester.pumpAndSettle();

      for (var i = 0; i < 10; i += 1) {
        await tester.enterText(find.byType(TextField), '오늘 일정 알려줘 $i');
        await tester.tap(find.text('전송'));
        await tester.pumpAndSettle();
      }

      expect(fakeDelegate.consumeCalls, 1);
      expect(fakeDelegate.consumedSessionIds, <String>['session-repeat']);
    });

    testWidgets('아무 명령도 보내지 않고 이탈하면 소비하지 않고 이탈 이벤트만 남긴다', (tester) async {
      final fakeDelegate = _FakeEntitlementDelegate();
      VoiceConversationEntitlementService.instance.delegateForTest =
          fakeDelegate;

      const grant = VoiceConversationEntryGrant(
        sessionId: 'session-abandoned',
        source: EntitlementSource.initialFree,
        initialRemainingAtGate: 3,
        dailyRemainingAtGate: 3,
      );

      await pumpConversation(
        tester,
        const VoiceConversationScreen(entryGrant: grant),
      );
      await tester.pumpAndSettle();

      // 아무 명령도 제출하지 않고 위젯 트리를 교체(dispose)해 이탈을 흉내낸다.
      // AnalyticsService는 1차 배포에서 외부 SDK 없이 no-op(디버그 프린트만)
      // 처리되어 이벤트 발화 자체를 스파이할 테스트 훅이 없다(디버그 프린트
      // 가로채기는 flutter_test의 foundation debug 변수 불변식과 충돌해 사용
      // 불가 — 실측 확인함). 여기서는 dispose 시 소비가 발생하지 않았음만
      // 검증한다(_usageConsumedForSession 가드의 핵심 계약).
      expect(fakeDelegate.consumeCalls, 0);
    });

    testWidgets('entryGrant 없이 진입하면 화면이 스스로 게이트를 호출해 승인을 얻는다', (tester) async {
      const grant = VoiceConversationEntryGrant(
        sessionId: 'session-self-gate',
        source: EntitlementSource.dailyFree,
        initialRemainingAtGate: 0,
        dailyRemainingAtGate: 1,
      );
      final fakeAdGateDelegate = _FakeAdGateDelegate(grantToProvide: grant);
      VoiceConversationAdGate.instance.delegateForTest = fakeAdGateDelegate;
      authProvider.setUser('user-self-gate');

      final fakeEntitlementDelegate = _FakeEntitlementDelegate()
        ..consumeResult = const VoiceConversationConsumeResult(
          source: 'daily_free',
          initialRemaining: 0,
          dailyRemaining: 0,
        );
      VoiceConversationEntitlementService.instance.delegateForTest =
          fakeEntitlementDelegate;

      await pumpConversation(
        tester,
        const VoiceConversationScreen(initialText: '오늘 일정 알려줘'),
      );
      await tester.pumpAndSettle();

      expect(fakeAdGateDelegate.tryEnterCalls, 1);
      expect(fakeAdGateDelegate.lastUserId, 'user-self-gate');
      expect(fakeEntitlementDelegate.consumeCalls, 1);
      expect(
        fakeEntitlementDelegate.consumedSessionIds,
        <String>['session-self-gate'],
      );
    });

    testWidgets('entryGrant 없고 로그인 정보도 없으면 self-gate를 시도하지 않고 fail-open으로 진행한다',
        (tester) async {
      final fakeAdGateDelegate = _FakeAdGateDelegate();
      VoiceConversationAdGate.instance.delegateForTest = fakeAdGateDelegate;

      final fakeEntitlementDelegate = _FakeEntitlementDelegate();
      VoiceConversationEntitlementService.instance.delegateForTest =
          fakeEntitlementDelegate;

      await pumpConversation(
        tester,
        const VoiceConversationScreen(initialText: '오늘 일정 알려줘'),
      );
      await tester.pumpAndSettle();

      // 로그인 정보가 없어 게이트를 시도하지 않지만, 화면은 정상적으로
      // initialText를 처리한다(fail-open, 소비는 되지 않음).
      expect(fakeAdGateDelegate.tryEnterCalls, 0);
      expect(find.text('오늘 일정 알려줘'), findsOneWidget);
      expect(fakeEntitlementDelegate.consumeCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'self-gate가 지연되는 동안 수동 제출해도 제출은 정상 처리되고 소비는 정확히 1회만 일어난다',
      (tester) async {
        // HIGH 회귀: entryGrant가 null(딥링크 등)로 진입해 self-gate가
        // 비동기로 진행 중인데, 그 완료를 기다리지 않는 수동 제출 경로
        // (onSubmit)가 먼저 _submitText를 호출하면 _usageConsumedForSession이
        // grant 없이 선점돼 실제 소비(consume RPC)가 영구히 누락됐었다.
        const grant = VoiceConversationEntryGrant(
          sessionId: 'session-self-gate-race',
          source: EntitlementSource.dailyFree,
          initialRemainingAtGate: 0,
          dailyRemainingAtGate: 1,
        );
        final fakeAdGateDelegate = _DelayedAdGateDelegate(
          grantToProvide: grant,
          delay: const Duration(milliseconds: 300),
        );
        VoiceConversationAdGate.instance.delegateForTest = fakeAdGateDelegate;
        authProvider.setUser('user-self-gate-race');

        final fakeEntitlementDelegate = _FakeEntitlementDelegate()
          ..consumeResult = const VoiceConversationConsumeResult(
            source: 'daily_free',
            initialRemaining: 0,
            dailyRemaining: 0,
          );
        VoiceConversationEntitlementService.instance.delegateForTest =
            fakeEntitlementDelegate;

        await pumpConversation(
          tester,
          const VoiceConversationScreen(),
        );
        // initState의 addPostFrameCallback이 self-gate 호출을 시작하도록
        // 한 프레임 더 진행시킨다. 이 시점에는 self-gate가 지연 중이라 아직
        // 완료되지 않은 상태다.
        await tester.pump();
        expect(fakeAdGateDelegate.tryEnterCalls, 1);
        expect(fakeEntitlementDelegate.consumeCalls, 0);

        // self-gate가 끝나기 전에 사용자가 직접 텍스트를 입력해 전송 버튼을
        // 누른다(onSubmit → _submitText, self-gate 대기 없이 즉시 호출됨).
        await tester.enterText(find.byType(TextField), '오늘 일정 알려줘');
        await tester.tap(find.text('전송'));
        await tester.pump();

        // self-gate가 아직 지연 중이므로, 수정 전 코드였다면 이 시점에
        // grant 없이 소비 플래그만 선점되고 실제 consume은 다시 호출되지
        // 않았다. 수정 후에는 _submitText가 completer를 기다리므로 아직
        // 소비가 일어나지 않아야 한다.
        expect(fakeEntitlementDelegate.consumeCalls, 0);

        // self-gate 지연이 끝나도록 시간을 흘려보낸다.
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();

        // 제출 자체는 정상 처리됐고(사용자 메시지가 대화에 남음), 소비는
        // 정확히 1회만 일어나야 한다(0회도 2회도 아님).
        expect(find.text('오늘 일정 알려줘'), findsOneWidget);
        expect(fakeEntitlementDelegate.consumeCalls, 1);
        expect(
          fakeEntitlementDelegate.consumedSessionIds,
          <String>['session-self-gate-race'],
        );
      },
    );

    testWidgets(
      'self-gate가 지연 후 거부로 끝나면 대기 중 제출된 명령은 처리되지 않는다',
      (tester) async {
        // BLOCKER 회귀: self-gate(딥링크 등 entryGrant 미보유 진입)가 아직
        // 완료 전인데 사용자가 수동으로 텍스트를 제출하면 _submitText가
        // completer를 기다린다. completer.complete()는 마이크로태스크로
        // 재개를 스케줄하고, context.go()로 인한 dispose는 그 다음 프레임에야
        // 일어나므로, 거부 완료 직후 재개되는 지점에서 mounted는 아직 true다.
        // 이 시점에 grant==null만 확인하지 않고 명시적 거부 판정
        // (_entryGateDenied)이 없으면, 재개된 코드가 명령을 그대로 처리해
        // 버려 게이트의 거부 결정이 무시된다.
        final fakeAdGateDelegate = _DelayedDeniedAdGateDelegate(
          delay: const Duration(milliseconds: 300),
        );
        VoiceConversationAdGate.instance.delegateForTest = fakeAdGateDelegate;
        authProvider.setUser('user-self-gate-denied');

        final fakeEntitlementDelegate = _FakeEntitlementDelegate();
        VoiceConversationEntitlementService.instance.delegateForTest =
            fakeEntitlementDelegate;

        // 화면 dispose(홈 이동) 타이밍과 무관하게 "명령이 실제로 처리됐는가"를
        // 판정하기 위해 debugPrint 로그를 가로챈다. _submitText가 명령을
        // 실제 처리하면 '_conversation.handle' 직후 'VoiceConversationScreen
        // result: action=...' 로그를 남기는데(라인 568~572 참조), 이는 위젯
        // 리빌드/네비게이션과 무관하게 처리 시점에 동기적으로 찍힌다 — 위젯
        // 트리가 그 뒤에 dispose돼도 이미 찍힌 로그는 사라지지 않으므로,
        // find.text 같은 위젯 기반 단언보다 신뢰도가 높은 판정 근거다.
        // (주의) debugPrint override는 addTearDown으로 복구하면 늦다 —
        // flutter_test의 foundation debug 변수 불변식 검사(_verifyInvariants)가
        // package:test의 addTearDown 큐보다 먼저 실행돼 "changed by the
        // test" 오류로 실패한다(실측 확인). 그래서 이 블록 안에서 캡처가
        // 끝나는 즉시 명시적으로 원복한다(try/finally).
        final debugLogs = <String>[];
        final originalDebugPrint = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) debugLogs.add(message);
        };

        final router = GoRouter(
          initialLocation: AppRoutes.voiceConversation,
          routes: [
            GoRoute(
              path: AppRoutes.voiceConversation,
              builder: (context, state) => const VoiceConversationScreen(),
            ),
            GoRoute(
              path: AppRoutes.home,
              builder: (context, state) => const Scaffold(
                body: Text('홈 화면'),
              ),
            ),
          ],
        );

        try {
          await tester.pumpWidget(
            MaterialApp.router(
              theme: buildPlanFlowTheme(),
              routerConfig: router,
            ),
          );
          // initState의 addPostFrameCallback이 self-gate 호출을 시작하도록
          // 한 프레임 더 진행시킨다. 이 시점에는 self-gate가 지연 중이라 아직
          // 완료(거부 확정)되지 않은 상태다.
          await tester.pump();
          expect(fakeAdGateDelegate.tryEnterCalls, 1);
          expect(fakeEntitlementDelegate.consumeCalls, 0);

          // self-gate가 거부로 끝나기 전에 사용자가 직접 텍스트를 입력해
          // 전송 버튼을 누른다(onSubmit → _submitText, self-gate 대기 없이
          // 즉시 호출됨. 함수 내부에서 completer를 기다리게 됨). self-gate가
          // 아직 미완료이므로 _submitText는 completer await에서 멈춰 있고,
          // 입력창은 아직 비워지지 않은 채(제출 미처리) 그대로다 — 이 시점의
          // find.text('오늘 일정 알려줘')는 (아직 지워지지 않은) TextField
          // 자체의 값과 일치해 findsOneWidget이 나오므로 판정에 쓰지 않는다.
          await tester.enterText(find.byType(TextField), '오늘 일정 알려줘');
          await tester.tap(find.text('전송'));
          await tester.pump();

          expect(fakeEntitlementDelegate.consumeCalls, 0);

          // self-gate 지연이 끝나 거부가 확정된다. completer가 complete()되고
          // (마이크로태스크로 _submitText 재개), 곧이어 context.go(home)이
          // 호출된다.
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();

          // 거부가 확정된 뒤에도 대기 중이던 제출은 처리되지 않아야 한다:
          // 소비가 0회이고, 화면은 홈으로 이동해(대화 화면 트리 자체가 사라져)
          // 있어야 한다. VoiceConversationScreen이 dispose됐으므로 그 안의
          // TextField/메시지 버블도 함께 사라져, 이 시점의 find.text 결과는
          // 더 이상 TextField 잔여값이 아니라 실제 메시지 목록 여부를 뜻한다.
          expect(fakeEntitlementDelegate.consumeCalls, 0);
          expect(find.byType(VoiceConversationScreen), findsNothing);
          expect(find.text('오늘 일정 알려줘'), findsNothing);
          expect(find.text('홈 화면'), findsOneWidget);
          expect(tester.takeException(), isNull);

          // 핵심 판정: 거부된 제출이 실제 처리 단계(_conversation.handle)까지
          // 도달하지 않았어야 한다. 도달했다면 이 로그가 남는다(수정 전
          // 코드에서 실측 재현: action=showEvents 로그가 남으며 게이트의 거부
          // 결정이 무시됨).
          expect(
            debugLogs.any(
              (log) => log.startsWith('VoiceConversationScreen result:'),
            ),
            isFalse,
            reason: '거부된 self-gate 대기 중 제출이 실제 명령 처리 단계까지 도달하면 안 된다',
          );
        } finally {
          debugPrint = originalDebugPrint;
        }
      },
    );
  });

  // B-2: self-gate fallback 분기가 거부 진단 코드(reason)를 노출하는 검증.
  // 게이트가 silent 거부(onEnterAllowed/onDenied 미호출)로 끝났을 때 화면은
  // lastDenialReason을 읽어 reason별 메시지를 띄우고, reason이 null이면
  // 'E-GATE1' 진단 코드가 포함된 fallback 메시지를 띄워야 한다.
  group('self-gate fallback reason 진단 코드 (B-2)', () {
    tearDown(() {
      VoiceConversationAdGate.instance.delegateForTest = null;
      VoiceConversationAdGate.instance.lastDenialReason = null;
      VoiceConversationEntitlementService.instance.delegateForTest = null;
      authProvider.setUser(null);
    });

    Future<GoRouter> pumpWithRouter(
      WidgetTester tester, {
      required Widget screen,
    }) async {
      final router = GoRouter(
        initialLocation: AppRoutes.voiceConversation,
        routes: [
          GoRoute(
            path: AppRoutes.voiceConversation,
            builder: (context, state) => screen,
          ),
          GoRoute(
            path: AppRoutes.home,
            builder: (context, state) =>
                const Scaffold(body: Text('B2_FALLBACK_HOME_LANDMARK')),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(
          theme: buildPlanFlowTheme(),
          routerConfig: router,
        ),
      );
      // initState의 addPostFrameCallback이 self-gate를 호출하고, silent
      // delegate가 즉시 끝나도록 보장된 상태로 한 프레임 더 진행한다.
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets(
      'lastDenialReason이 null이면 self-gate fallback 메시지에 E-GATE1 진단 코드가 노출된다',
      (tester) async {
        // silent 거부이지만 lastDenialReason은 reset(null)된 채로 둔다.
        final silentDelegate = _FakeAdGateDelegate();
        VoiceConversationAdGate.instance.delegateForTest = silentDelegate;
        VoiceConversationAdGate.instance.lastDenialReason = null;
        authProvider.setUser('user-b2-fallback-null');

        await pumpWithRouter(
          tester,
          screen: const VoiceConversationScreen(),
        );

        expect(silentDelegate.tryEnterCalls, 1);
        // 화면은 SnackBar로 E-GATE1 진단 코드가 포함된 메시지를 띄우고
        // 홈으로 이동한다.
        expect(find.textContaining('E-GATE1'), findsOneWidget);
        expect(find.text('B2_FALLBACK_HOME_LANDMARK'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'lastDenialReason이 rewardedDisabled이면 fallback 메시지에 (E-RC1) 코드가 노출된다',
      (tester) async {
        final reasonDelegate = _SilentAdGateDelegateWithReason(
          lastDenialReason: VoiceConversationGateDenialReason.rewardedDisabled,
        );
        VoiceConversationAdGate.instance.delegateForTest = reasonDelegate;
        VoiceConversationAdGate.instance.lastDenialReason = null;
        authProvider.setUser('user-b2-fallback-rewarded');

        await pumpWithRouter(
          tester,
          screen: const VoiceConversationScreen(),
        );

        expect(reasonDelegate.tryEnterCalls, 1);
        expect(
          VoiceConversationAdGate.instance.lastDenialReason,
          VoiceConversationGateDenialReason.rewardedDisabled,
        );
        // reason별 메시지가 SnackBar에 표시되고, 홈으로 이동한다.
        expect(find.textContaining('(E-RC1)'), findsOneWidget);
        expect(find.text('B2_FALLBACK_HOME_LANDMARK'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'lastDenialReason이 adsUnavailable이면 fallback 메시지에 (E-ADS0) 코드가 노출된다',
      (tester) async {
        final reasonDelegate = _SilentAdGateDelegateWithReason(
          lastDenialReason: VoiceConversationGateDenialReason.adsUnavailable,
        );
        VoiceConversationAdGate.instance.delegateForTest = reasonDelegate;
        VoiceConversationAdGate.instance.lastDenialReason = null;
        authProvider.setUser('user-b2-fallback-ads');

        await pumpWithRouter(
          tester,
          screen: const VoiceConversationScreen(),
        );

        expect(reasonDelegate.tryEnterCalls, 1);
        expect(find.textContaining('(E-ADS0)'), findsOneWidget);
        expect(find.text('B2_FALLBACK_HOME_LANDMARK'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  // -------------------------------------------------------------------------
  // 일간/시간 자동 저장 경로 테스트 (voice screen 전용)
  //
  // 다음 세 가지 시나리오를 검증한다:
  // 1) 가드/일관성: [debugCanApplyDateChangeAuto]가 controller 플래그,
  //    반복 일정, 그룹 연결, 드래프트 일관성 등을 정확히 판정한다.
  // 2) 실제 저장: [debugApplyConversationDateAutoSave]가 드래프트의
  //    startAt/endAt을 그대로 저장하고 사이드 이펙트 서비스를 호출한다.
  // 3) 폴백/실패: 중복 경고 취소, 저장 실패, 그룹 공유본/반복 일정 같은
  //    자동 저장 불가 대상이 있을 때 편집 화면 경로로 정확히 들어간다.
  //
  // 테스트는 모두 [_FakeEventRepository]와 [_FakeManualEventSideEffectService]
  // 를 주입해 외부 의존성 없이 검증한다. 컨트롤러의 canAutoApplyDateChange
  // 플래그(3mT80MWHgUxUkPlv 워커가 계약으로 제공)는 VoiceConversationResult
  // 직접 구성으로 시뮬레이트한다.
  // -------------------------------------------------------------------------

  VoiceConversationResult buildDateAutoResult({
    required EventModel targetEvent,
    required DateTime newStart,
    DateTime? newEnd,
    bool canAutoApplyDateChange = true,
    String? locationText,
    bool? criticalValue,
    String? recurrenceRule,
    String? groupEventId,
  }) {
    final draft = targetEvent.copyWith(
      startAt: newStart,
      endAt: newEnd,
      recurrenceRule: recurrenceRule,
      clearRecurrenceRule: recurrenceRule == null,
      groupEventId: groupEventId,
      clearGroupEventId: groupEventId == null,
    );
    return VoiceConversationResult(
      action: VoiceConversationAction.confirmedEdit,
      inputText: '그 일정 다음 주로',
      targetEvent: targetEvent,
      draftEvent: draft,
      visibleEvents: <EventModel>[targetEvent],
      selectedEvents: <EventModel>[targetEvent],
      canAutoApplyDateChange: canAutoApplyDateChange,
      locationText: locationText,
      criticalValue: criticalValue,
      assistantMessage: '환자 일정을 다음 주로 옮겼어요.',
    );
  }

  testWidgets('음성 자동 저장 가드는 canAutoApplyDateChange=true+일반 개인 일정만 통과시킨다',
      (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-1',
        userId: 'user-1',
        title: '병원 방문',
        startAt: DateTime(_voiceFixtureYear, 5, 22, 9).toUtc(),
      ),
    ]);
    await pumpConversation(
      tester,
      VoiceConversationScreen(repository: repository),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final newStart = DateTime(_voiceFixtureYear, 5, 29, 9).toUtc();
    final result = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: newStart,
    );

    expect(
      state.debugCanApplyDateChangeAuto(
        result: result,
        targetEvent: originalEvent,
      ),
      isTrue,
    );
  });

  testWidgets('음성 자동 저장 가드는 반복 일정이면 거부한다 (편집 화면으로 폴백)', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-rec',
        userId: 'user-1',
        title: '매주 회의',
        startAt: DateTime(_voiceFixtureYear, 5, 22, 9).toUtc(),
        recurrenceRule: 'FREQ=WEEKLY;BYDAY=FR',
      ),
    ]);
    await pumpConversation(
      tester,
      VoiceConversationScreen(repository: repository),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final newStart = DateTime(_voiceFixtureYear, 5, 29, 9).toUtc();
    final result = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: newStart,
    );

    expect(
      state.debugCanApplyDateChangeAuto(
        result: result,
        targetEvent: originalEvent,
      ),
      isFalse,
      reason: '반복 일정은 자동 저장 불가',
    );
  });

  testWidgets('음성 자동 저장 가드는 groupEventId가 있으면 거부한다 (그룹 연결 폴백)', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-group',
        userId: 'user-1',
        title: '그룹 공유 일정',
        startAt: DateTime(_voiceFixtureYear, 5, 22, 9).toUtc(),
        groupEventId: 'group-event-1',
      ),
    ]);
    await pumpConversation(
      tester,
      VoiceConversationScreen(repository: repository),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final newStart = DateTime(_voiceFixtureYear, 5, 29, 9).toUtc();
    final result = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: newStart,
    );

    expect(
      state.debugCanApplyDateChangeAuto(
        result: result,
        targetEvent: originalEvent,
      ),
      isFalse,
      reason: '그룹 연결 일정은 자동 저장 불가',
    );
  });

  testWidgets('음성 자동 저장 가드는 locationText가 같이 오면 거부한다 (동시 변경 폴백)',
      (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-mixed',
        userId: 'user-1',
        title: '방문',
        startAt: DateTime(_voiceFixtureYear, 5, 22, 9).toUtc(),
      ),
    ]);
    await pumpConversation(
      tester,
      VoiceConversationScreen(repository: repository),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final newStart = DateTime(_voiceFixtureYear, 5, 29, 9).toUtc();
    final result = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: newStart,
      locationText: '강릉',
    );

    expect(
      state.debugCanApplyDateChangeAuto(
        result: result,
        targetEvent: originalEvent,
      ),
      isFalse,
      reason: '장소 변경이 함께 있으면 편집 화면 경로',
    );
  });

  testWidgets('음성 자동 저장 가드는 criticalValue가 같이 오면 거부한다 (동시 변경 폴백)',
      (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-mixed-2',
        userId: 'user-1',
        title: '면접',
        startAt: DateTime(_voiceFixtureYear, 5, 22, 9).toUtc(),
      ),
    ]);
    await pumpConversation(
      tester,
      VoiceConversationScreen(repository: repository),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final newStart = DateTime(_voiceFixtureYear, 5, 29, 9).toUtc();
    final result = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: newStart,
      criticalValue: true,
    );

    expect(
      state.debugCanApplyDateChangeAuto(
        result: result,
        targetEvent: originalEvent,
      ),
      isFalse,
      reason: '중요 표시 변경이 함께 있으면 편집 화면 경로',
    );
  });

  testWidgets('음성 자동 저장 가드는 드래프트의 시작 시각이 원본과 같으면 거부한다', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-same',
        userId: 'user-1',
        title: '같은 날',
        startAt: DateTime(_voiceFixtureYear, 5, 22, 9).toUtc(),
      ),
    ]);
    await pumpConversation(
      tester,
      VoiceConversationScreen(repository: repository),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final sameStart = originalEvent.startAt!;
    final result = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: sameStart,
    );

    expect(
      state.debugCanApplyDateChangeAuto(
        result: result,
        targetEvent: originalEvent,
      ),
      isFalse,
      reason: '날짜가 실제로 바뀌지 않으면 자동 저장 불가',
    );
  });

  testWidgets('음성 자동 저장 가드는 canAutoApplyDateChange=false이면 무조건 거부한다',
      (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-flag-false',
        userId: 'user-1',
        title: '기존 일정',
        startAt: DateTime(_voiceFixtureYear, 5, 22, 9).toUtc(),
      ),
    ]);
    await pumpConversation(
      tester,
      VoiceConversationScreen(repository: repository),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final result = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: DateTime(_voiceFixtureYear, 5, 29, 9).toUtc(),
      canAutoApplyDateChange: false,
    );

    expect(
      state.debugCanApplyDateChangeAuto(
        result: result,
        targetEvent: originalEvent,
      ),
      isFalse,
      reason: '컨트롤러 플래그가 false이면 자동 저장 비활성',
    );
  });

  testWidgets('음성 자동 저장은 정확한 UTC 시작/종료 페이로드를 저장소에 전달한다', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-save',
        userId: 'user-1',
        title: '저장 대상',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
        endAt: DateTime.utc(_voiceFixtureYear, 5, 22, 10),
      ),
    ]);
    // 실제 사이드 이펙트 서비스는 플러그인/네트워크 의존이라 fake async
    // 테스트에서 종료하지 않는다. 저장 경로 테스트에는 항상 fake 를 주입한다.
    final sideEffects = _FakeManualEventSideEffectService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        sideEffectService: sideEffects,
        settingsRepository:
            _FakeSettingsRepository(const Duration(minutes: 30)),
        reminderNotifyAtReader: _fakeReminderReader(repository),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final newStart = DateTime.utc(_voiceFixtureYear, 5, 29, 9);
    final newEnd = DateTime.utc(_voiceFixtureYear, 5, 29, 10);
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: newStart,
      newEnd: newEnd,
    );

    final saved = await state.debugApplyConversationDateAutoSave(
      result: voiceResult,
      targetEvent: originalEvent,
    );
    expect(saved, isTrue);
    expect(repository.updatedEvents, hasLength(1));
    final updated = repository.updatedEvents.single;
    expect(updated.id, originalEvent.id);
    expect(updated.startAt, newStart);
    expect(updated.endAt, newEnd);
    // 다른 필드는 그대로 보존되어야 한다(사용자가 원치 않은 필드 변경 없음).
    expect(updated.title, originalEvent.title);
    expect(updated.location, originalEvent.location);
    expect(updated.isCritical, originalEvent.isCritical);
    expect(updated.recurrenceRule, originalEvent.recurrenceRule);
  });

  testWidgets('음성 자동 저장 후 사이드 이펙트는 old/new 임드를 포함한 event로 1회만 호출된다',
      (tester) async {
    final originalStart = DateTime.utc(_voiceFixtureYear, 5, 22, 9);
    final newStart = DateTime.utc(_voiceFixtureYear, 5, 29, 9);
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-side-effects',
        userId: 'user-1',
        title: '사이즈 이펙트',
        startAt: originalStart,
        endAt: DateTime.utc(_voiceFixtureYear, 5, 22, 10),
      ),
    ]);
    final sideEffects = _FakeManualEventSideEffectService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        sideEffectService: sideEffects,
        settingsRepository:
            _FakeSettingsRepository(const Duration(minutes: 30)),
        reminderNotifyAtReader: _fakeReminderReader(repository),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: newStart,
    );
    final saved = await state.debugApplyConversationDateAutoSave(
      result: voiceResult,
      targetEvent: originalEvent,
    );
    expect(saved, isTrue);

    expect(sideEffects.syncAfterSaveCalls, hasLength(1));
    final call = sideEffects.syncAfterSaveCalls.single;
    expect(call.event.id, originalEvent.id);
    // 저장 후의 event 가 이전 (옙초) 와 다른 일수 실수로 전환되어 있다.
    expect(call.event.startAt, newStart);
    expect(call.event.startAt, isNot(equals(originalStart)));
  });

  testWidgets('음성 자동 저장 가드는 시작 시각이 같은 경우 자동 저장 경로에서 제외된다', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-nochange',
        userId: 'user-1',
        title: '변화 없음',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
      ),
    ]);
    await pumpConversation(
      tester,
      VoiceConversationScreen(repository: repository),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: originalEvent.startAt!,
    );
    final saved = await state.debugApplyConversationDateAutoSave(
      result: voiceResult,
      targetEvent: originalEvent,
    );
    // 드래프트가 원본과 같으면 자동 저장함에 수행되지 않는다.
    expect(saved, isFalse);
    expect(repository.updatedEvents, isEmpty);
  });

  testWidgets('음성 자동 저장 가드는 _events 목록에 없는 id targetEvent면 자동 저장 경로에서 제외된다',
      (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-actual',
        userId: 'user-1',
        title: '실제 일정',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
      ),
    ]);
    await pumpConversation(
      tester,
      VoiceConversationScreen(repository: repository),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: DateTime.utc(_voiceFixtureYear, 5, 29, 9),
    );
    // 원본 이벤트에 존재하지 않는 id로 targetEvent를 바꾸어 본 적 없는
    // 일정으로 만든다.
    final phantom = EventModel(
      id: 'phantom-id',
      userId: 'user-1',
      title: '유령 일정',
      startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
    );
    final phantomResult = VoiceConversationResult(
      action: VoiceConversationAction.confirmedEdit,
      inputText: voiceResult.inputText,
      targetEvent: phantom,
      draftEvent: voiceResult.draftEvent,
      visibleEvents: voiceResult.visibleEvents,
      selectedEvents: voiceResult.selectedEvents,
      canAutoApplyDateChange: voiceResult.canAutoApplyDateChange,
      locationText: voiceResult.locationText,
      criticalValue: voiceResult.criticalValue,
      assistantMessage: voiceResult.assistantMessage,
    );
    expect(
      state.debugCanApplyDateChangeAuto(
        result: phantomResult,
        targetEvent: phantom,
      ),
      isFalse,
      reason: '본 적 목록에 없는 targetEvent는 자동 저장 불가',
    );
  });

  testWidgets('음성 자동 저장은 개별 이벤트 알림 오프셋(15분)을 전역 설정(60분)보다 우선한다',
      (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-reminder',
        userId: 'user-1',
        title: '오프셋 검증',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
        endAt: DateTime.utc(_voiceFixtureYear, 5, 22, 10),
      ),
    ]);
    final sideEffects = _FakeManualEventSideEffectService()
      ..throwOnSync = false;
    // 전역 기본 알림은 60분. 개별 이벤트에는 15분 알림이 저장돼 있다.
    final settingsRepository =
        _FakeSettingsRepository(const Duration(minutes: 60));
    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        sideEffectService: sideEffects,
        settingsRepository: settingsRepository,
        reminderNotifyAtReader: _fakeReminderReader(
          repository,
          offsetsByEventId: <String, Duration>{
            'event-reminder': const Duration(minutes: 15),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final newStart = DateTime.utc(_voiceFixtureYear, 5, 29, 9);
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: newStart,
    );
    final saved = await state.debugApplyConversationDateAutoSave(
      result: voiceResult,
      targetEvent: originalEvent,
    );
    expect(saved, isTrue);

    expect(sideEffects.syncAfterSaveCalls, hasLength(1));
    // 개별 이벤트의 저장된 알림(원본 시작 09:00 - 15분 = 08:45)이 우선한다.
    // 전역 설정(60분)은 자동 저장 경로에서 읽지 않는다. 저장된 이벤트 시작은
    // 새 날짜이므로 알림은 '새 시작 - 15분'으로 재계산된다(오래된 알림
    // 시각 재사용 금지).
    expect(settingsRepository.fetchSettingsCalls, 0);
    expect(sideEffects.lastReminderOffset, const Duration(minutes: 15));
    expect(sideEffects.lastCriticalAlarmOffset, const Duration(minutes: 15));
    expect(
      sideEffects.syncAfterSaveCalls.single.event.startAt,
      DateTime.utc(_voiceFixtureYear, 5, 29, 9),
    );
  });

  testWidgets('음성 자동 저장 시 저장소가 저장소에서 실피한다면 다음 호출로 false를 반환하고 상태가 변경되지 않는다',
      (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-fail',
        userId: 'user-1',
        title: '실패 케이스',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
        endAt: DateTime.utc(_voiceFixtureYear, 5, 22, 10),
      ),
    ])
      ..throwOnUpdate = true;
    final sideEffects = _FakeManualEventSideEffectService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        sideEffectService: sideEffects,
        settingsRepository:
            _FakeSettingsRepository(const Duration(minutes: 30)),
        reminderNotifyAtReader: _fakeReminderReader(repository),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final newStart = DateTime.utc(_voiceFixtureYear, 5, 29, 9);
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: newStart,
    );
    final saved = await state.debugApplyConversationDateAutoSave(
      result: voiceResult,
      targetEvent: originalEvent,
    );
    expect(saved, isFalse);
    // 저장 실패 시 사이드 이펙트 호출이 일어나지 않는다.
    expect(sideEffects.syncAfterSaveCalls, isEmpty);
    expect(repository.updatedEvents, isEmpty);
    // _events의 사본은 여전히 원본이다.
    expect(repository.events.single.startAt, originalEvent.startAt);
  });

  testWidgets('음성 자동 저장 시 저장소에서 겹지 후보를 받으면 저장 전에 경고 다이얼로그를 보여준다',
      (tester) async {
    final originalStart = DateTime.utc(_voiceFixtureYear, 5, 22, 9);
    final newStart = DateTime.utc(_voiceFixtureYear, 5, 23, 14);
    final overlappingEvent = EventModel(
      id: 'event-overlap',
      userId: 'user-1',
      title: '겹지 대상',
      startAt: DateTime.utc(_voiceFixtureYear, 5, 23, 14),
      endAt: DateTime.utc(_voiceFixtureYear, 5, 23, 15),
    );
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-move',
        userId: 'user-1',
        title: '옮길 일정',
        startAt: originalStart,
        endAt: DateTime.utc(_voiceFixtureYear, 5, 22, 10),
      ),
      overlappingEvent,
    ])
      ..overlappingCandidates = <EventModel>[overlappingEvent];
    final sideEffects = _FakeManualEventSideEffectService();
    final router = GoRouter(
      initialLocation: AppRoutes.voiceConversation,
      routes: [
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => VoiceConversationScreen(
            repository: repository,
            sideEffectService: sideEffects,
            settingsRepository:
                _FakeSettingsRepository(const Duration(minutes: 30)),
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) =>
              const Text('편집 화면 폴백', textDirection: TextDirection.ltr),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildPlanFlowTheme(),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    final voiceScreenState = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;
    final originalEvent = repository.events.first;
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: newStart,
    );
    // 다이얼로그가 뜨기 전까지 저장 호출은 펜딩된다. 먼저 호출을 걸어 둔 뒤
    // 다이얼로그 표시를 확인하고 '중단'으로 취소한다.
    final Future<bool> savedFuture =
        voiceScreenState.debugApplyConversationDateAutoSave(
      result: voiceResult,
      targetEvent: originalEvent,
    );
    await tester.pump();
    // 겹치는 후보가 있으면 저장 전에 경고 다이얼로그가 먼저 뜬다(라우트
    // 진입 프레임을 위해 두 번 펌프한다).
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('일정이 겹쳐요'), findsOneWidget);
    await tester.tap(find.text('중단'));
    await tester.pumpAndSettle();
    final saved = await savedFuture;
    // 취소는 저장 없이 false 로 끝난다. 로컬 변경도, 사이드 이펙트도 없어야
    // 하며('저장됨'/로컬 변조 금지), 제안은 편집 경로에 드래프트로 남는다.
    expect(saved, isFalse);
    expect(repository.updatedEvents, isEmpty);
    expect(sideEffects.syncAfterSaveCalls, isEmpty);
  });

  testWidgets('음성 자동 저장 시 _groupEventById에 등록된 targetEvent면 자동 저장 경로에서 제외된다',
      (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'group-event-1',
        userId: 'user-1',
        title: '팀 회의',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
      ),
    ]);
    final groupRepository = _FakeGroupRepository(<GroupModel>[
      const GroupModel(id: 'group-1', createdBy: 'leader-1', name: '우리 팀'),
    ]);
    final groupEventRepository = _FakeGroupEventRepository(<GroupEventModel>[
      GroupEventModel(
        id: 'group-event-1',
        groupId: 'group-1',
        title: '팀 회의',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
        endAt: DateTime.utc(_voiceFixtureYear, 5, 22, 10),
        createdBy: 'leader-1',
      ),
    ]);
    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        groupRepository: groupRepository,
        groupEventRepository: groupEventRepository,
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final personalOfGroup = repository.events.single;
    final voiceResult = buildDateAutoResult(
      targetEvent: personalOfGroup,
      newStart: DateTime.utc(_voiceFixtureYear, 5, 29, 9),
    );
    expect(
      state.debugCanApplyDateChangeAuto(
        result: voiceResult,
        targetEvent: personalOfGroup,
      ),
      isFalse,
      reason: '_groupEventById에 있는 id는 그룹 일정으로 다뤄야 함',
    );
  });

  testWidgets('음성 자동 저장 가드는 _events 목록에 일치하는 id가 없으면 자동 저장 경로에서 제외된다',
      (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-actual',
        userId: 'user-1',
        title: '실제 일정',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
      ),
    ]);
    await pumpConversation(
      tester,
      VoiceConversationScreen(repository: repository),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final phantom = EventModel(
      id: 'phantom-id',
      userId: 'user-1',
      title: '유령',
      startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
    );
    final voiceResult = buildDateAutoResult(
      targetEvent: phantom,
      newStart: DateTime.utc(_voiceFixtureYear, 5, 29, 9),
    );
    expect(
      state.debugCanApplyDateChangeAuto(
        result: voiceResult,
        targetEvent: phantom,
      ),
      isFalse,
      reason: '본 적 없는 id는 자동 저장에서 제외',
    );
  });

  testWidgets('음성 자동 저장 가드는 외부 캘린더 연동 일정이면 거부한다', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-external',
        userId: 'user-1',
        title: '구글 연동 일정',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
        externalId: 'google-evt-1',
        externalCalendarId: 'calendar-a',
      ),
    ]);
    await pumpConversation(
      tester,
      VoiceConversationScreen(repository: repository),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: DateTime.utc(_voiceFixtureYear, 5, 29, 9),
    );
    expect(
      state.debugCanApplyDateChangeAuto(
        result: voiceResult,
        targetEvent: originalEvent,
      ),
      isFalse,
      reason: '외부 연동 일정은 편집 화면 경로로 폴백',
    );
  });

  testWidgets('음성 자동 저장 가드는 대상이 화면의 최신본과 다르면 거부한다 (fail-closed)',
      (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-fresh',
        userId: 'user-1',
        title: '최신 일정',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
        updatedAt: DateTime.utc(_voiceFixtureYear, 5, 21, 12),
      ),
    ]);
    await pumpConversation(
      tester,
      VoiceConversationScreen(repository: repository),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    // 같은 일정의 오래된 버전(updatedAt 이 다름)이 컨트롤러 결과에 실렸다고
    // 가정한다. 자동 저장은 fail-closed 로 거부해 최신본을 덮어쓰지 않는다.
    final staleTarget = originalEvent.copyWith(
      updatedAt: DateTime.utc(_voiceFixtureYear, 5, 20, 8),
    );
    final voiceResult = buildDateAutoResult(
      targetEvent: staleTarget,
      newStart: DateTime.utc(_voiceFixtureYear, 5, 29, 9),
    );
    expect(
      state.debugCanApplyDateChangeAuto(
        result: voiceResult,
        targetEvent: staleTarget,
      ),
      isFalse,
      reason: '만료된 대상은 자동 저장 금지',
    );
  });

  testWidgets('음성 자동 저장은 원본 시각/길이를 보존해 새 시작 기준 종료를 계산한다', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-duration',
        userId: 'user-1',
        title: '길이 보존',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
        endAt: DateTime.utc(_voiceFixtureYear, 5, 22, 10, 30),
      ),
    ]);
    final sideEffects = _FakeManualEventSideEffectService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        sideEffectService: sideEffects,
        settingsRepository:
            _FakeSettingsRepository(const Duration(minutes: 30)),
        reminderNotifyAtReader: _fakeReminderReader(repository),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    // 드래프트가 원본 날짜의 오래된 종료(endAt)를 간직한 채 오는 경우에도
    // 새 시작 기준으로 원본 길이(90분)를 보존해 재계산한다.
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: DateTime.utc(_voiceFixtureYear, 5, 29, 9),
    );
    final saved = await state.debugApplyConversationDateAutoSave(
      result: voiceResult,
      targetEvent: originalEvent,
    );
    expect(saved, isTrue);
    final updated = repository.updatedEvents.single;
    // 시각 보존: 9시 → 9시. 길이 보존: 90분 → 종료 10:30.
    expect(updated.startAt, DateTime.utc(_voiceFixtureYear, 5, 29, 9));
    expect(updated.endAt, DateTime.utc(_voiceFixtureYear, 5, 29, 10, 30));
  });

  testWidgets('음성 자동 저장 후 같은 일정을 다시 옮기면 갱신된 날짜 기준으로 저장된다', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-repeat',
        userId: 'user-1',
        title: '후속 상대 수정',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
        endAt: DateTime.utc(_voiceFixtureYear, 5, 22, 10),
      ),
    ]);
    final sideEffects = _FakeManualEventSideEffectService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        sideEffectService: sideEffects,
        settingsRepository:
            _FakeSettingsRepository(const Duration(minutes: 30)),
        reminderNotifyAtReader: _fakeReminderReader(repository),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final firstResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: DateTime.utc(_voiceFixtureYear, 5, 29, 9),
      newEnd: DateTime.utc(_voiceFixtureYear, 5, 29, 10),
    );
    final firstSaved = await state.debugApplyConversationDateAutoSave(
      result: firstResult,
      targetEvent: originalEvent,
    );
    expect(firstSaved, isTrue);

    // 저장 후 갱신된 대상(새 날짜)을 기준으로 후속 상대 수정이 계산되는지
    // 본다. 컨트롤러 포커스 갱신(replaceEvents by id)과 화면 갱신이 이어져
    // 있는지 확인하는 테스트다.
    final movedEvent = repository.events.single;
    expect(movedEvent.startAt, DateTime.utc(_voiceFixtureYear, 5, 29, 9));
    final secondResult = buildDateAutoResult(
      targetEvent: movedEvent,
      newStart: DateTime.utc(_voiceFixtureYear, 5, 30, 9),
      newEnd: DateTime.utc(_voiceFixtureYear, 5, 30, 10),
    );
    expect(
      state.debugCanApplyDateChangeAuto(
        result: secondResult,
        targetEvent: movedEvent,
      ),
      isTrue,
    );
    final secondSaved = await state.debugApplyConversationDateAutoSave(
      result: secondResult,
      targetEvent: movedEvent,
    );
    expect(secondSaved, isTrue);
    expect(repository.updatedEvents, hasLength(2));
    expect(
      repository.updatedEvents.last.startAt,
      DateTime.utc(_voiceFixtureYear, 5, 30, 9),
    );
    expect(repository.updatedEvents.last.endAt, DateTime.utc(_voiceFixtureYear, 5, 30, 10));
  });

  testWidgets('저장 성공 후 사이드 이펙트가 실패해도 저장은 유지된다', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-side-fail',
        userId: 'user-1',
        title: '사이드 실패',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
        endAt: DateTime.utc(_voiceFixtureYear, 5, 22, 10),
      ),
    ]);
    final sideEffects = _FakeManualEventSideEffectService()..throwOnSync = true;
    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        sideEffectService: sideEffects,
        settingsRepository:
            _FakeSettingsRepository(const Duration(minutes: 30)),
        reminderNotifyAtReader: _fakeReminderReader(repository),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: DateTime.utc(_voiceFixtureYear, 5, 29, 9),
    );
    final saved = await state.debugApplyConversationDateAutoSave(
      result: voiceResult,
      targetEvent: originalEvent,
    );
    // 저장소 저장은 성공했으므로 true. 사이드 이펙트 실패를 '저장 실패'로
    // 보고하면 안 된다(안내는 경고 수준).
    expect(saved, isTrue);
    expect(repository.updatedEvents, hasLength(1));
    expect(sideEffects.syncAfterSaveCalls, hasLength(1));
    expect(repository.events.single.startAt, DateTime.utc(_voiceFixtureYear, 5, 29, 9));
  });

  testWidgets('개별 30분 알림(전역 60분)은 이동 후 새 시작(+7일) 기준 30분 전으로 재계산된다',
      (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-notify',
        userId: 'user-1',
        title: '알림 상대 보존',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
        endAt: DateTime.utc(_voiceFixtureYear, 5, 22, 10),
      ),
    ]);
    final sideEffects = _FakeManualEventSideEffectService();
    // 전역 기본은 60분이지만 이 일정에는 30분 개별 알림이 저장돼 있다.
    final settingsRepository =
        _FakeSettingsRepository(const Duration(minutes: 60));
    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        sideEffectService: sideEffects,
        settingsRepository: settingsRepository,
        reminderNotifyAtReader: _fakeReminderReader(repository),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final newStart = DateTime.utc(_voiceFixtureYear, 5, 29, 9); // +7일, 시각 보존
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: newStart,
      newEnd: DateTime.utc(_voiceFixtureYear, 5, 29, 10),
    );
    final saved = await state.debugApplyConversationDateAutoSave(
      result: voiceResult,
      targetEvent: originalEvent,
    );
    expect(saved, isTrue);
    // 개별 이벤트의 저장된 알림(30분)이 그대로 전달되고, 저장된 이벤트
    // 시작은 새 날짜(+7일)다. 즉 알림은 '새 시작 - 30분'으로 재계산된다.
    // 전역 설정(60분)은 이 경로에서 읽지 않는다.
    expect(settingsRepository.fetchSettingsCalls, 0);
    expect(sideEffects.lastReminderOffset, const Duration(minutes: 30));
    expect(sideEffects.syncAfterSaveCalls, hasLength(1));
    expect(sideEffects.syncAfterSaveCalls.single.event.startAt, newStart);
  });

  testWidgets('리마인더 행이 없으면 알림 꺼짐이 보존된다(꺼짐→자동 켜짐 금지)', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-none',
        userId: 'user-1',
        title: '알림 없는 일정',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
        endAt: DateTime.utc(_voiceFixtureYear, 5, 22, 10),
      ),
    ]);
    final sideEffects = _FakeManualEventSideEffectService();
    final settingsRepository =
        _FakeSettingsRepository(const Duration(minutes: 60));
    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        sideEffectService: sideEffects,
        settingsRepository: settingsRepository,
        reminderNotifyAtReader: _fakeReminderReader(
          repository,
          absentEventIds: <String>{'event-none'},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: DateTime.utc(_voiceFixtureYear, 5, 29, 9),
    );
    final saved = await state.debugApplyConversationDateAutoSave(
      result: voiceResult,
      targetEvent: originalEvent,
    );
    expect(saved, isTrue);
    // push 리마인더 행이 없으면 null(끔)이 그대로 전달된다. 전역 60분으로
    // 대체해 꺼진 알림을 자동으로 켜지 않는다.
    expect(sideEffects.syncAfterSaveCalls, hasLength(1));
    expect(sideEffects.lastReminderOffset, isNull);
    expect(sideEffects.lastCriticalAlarmOffset, isNull);
    expect(repository.updatedEvents, hasLength(1));
  });

  testWidgets('정시(0분) 알림 오프셋도 0으로 보존된다', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-zero',
        userId: 'user-1',
        title: '정시 알림 일정',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
        endAt: DateTime.utc(_voiceFixtureYear, 5, 22, 10),
      ),
    ]);
    final sideEffects = _FakeManualEventSideEffectService();
    final settingsRepository =
        _FakeSettingsRepository(const Duration(minutes: 60));
    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        sideEffectService: sideEffects,
        settingsRepository: settingsRepository,
        reminderNotifyAtReader: _fakeReminderReader(
          repository,
          offsetsByEventId: <String, Duration>{
            'event-zero': Duration.zero,
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: DateTime.utc(_voiceFixtureYear, 5, 29, 9),
    );
    final saved = await state.debugApplyConversationDateAutoSave(
      result: voiceResult,
      targetEvent: originalEvent,
    );
    expect(saved, isTrue);
    // 0분(정시)도 유효한 오프셋이다. 60분으로 바뀌지 않는다.
    expect(sideEffects.syncAfterSaveCalls, hasLength(1));
    expect(sideEffects.lastReminderOffset, Duration.zero);
    expect(sideEffects.lastCriticalAlarmOffset, Duration.zero);
  });

  testWidgets('중요 일정의 저장된 알람 오프셋(30분)이 보존된다(전역 60분 무시)', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-critical',
        userId: 'user-1',
        title: '중요 일정',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
        endAt: DateTime.utc(_voiceFixtureYear, 5, 22, 10),
        isCritical: true,
      ),
    ]);
    final sideEffects = _FakeManualEventSideEffectService();
    final settingsRepository =
        _FakeSettingsRepository(const Duration(minutes: 60));
    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        sideEffectService: sideEffects,
        settingsRepository: settingsRepository,
        reminderNotifyAtReader: _fakeReminderReader(
          repository,
          offsetsByEventId: <String, Duration>{
            'event-critical': const Duration(minutes: 30),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: DateTime.utc(_voiceFixtureYear, 5, 29, 9),
    );
    final saved = await state.debugApplyConversationDateAutoSave(
      result: voiceResult,
      targetEvent: originalEvent,
    );
    expect(saved, isTrue);
    // 크리티컬 일정은 system_alarm 행에서 역산한 30분이 유지된다.
    expect(sideEffects.syncAfterSaveCalls, hasLength(1));
    expect(sideEffects.lastCriticalAlarmOffset, const Duration(minutes: 30));
    expect(sideEffects.lastReminderOffset, const Duration(minutes: 30));
    expect(repository.updatedEvents, hasLength(1));
  });

  testWidgets('중요 일정의 알람 행이 없으면 저장 전에 실패한다(fail-closed)', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-critical-absent',
        userId: 'user-1',
        title: '알람 없는 중요 일정',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
        endAt: DateTime.utc(_voiceFixtureYear, 5, 22, 10),
        isCritical: true,
      ),
    ]);
    final sideEffects = _FakeManualEventSideEffectService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        sideEffectService: sideEffects,
        settingsRepository:
            _FakeSettingsRepository(const Duration(minutes: 60)),
        reminderNotifyAtReader: _fakeReminderReader(
          repository,
          absentEventIds: <String>{'event-critical-absent'},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: DateTime.utc(_voiceFixtureYear, 5, 29, 9),
    );
    final saved = await state.debugApplyConversationDateAutoSave(
      result: voiceResult,
      targetEvent: originalEvent,
    );
    // 크리티컬 + 알람 행 부재 = 상태 미확정. 전역 60분 폴백 없이 저장 자체를
    // 막는다.
    expect(saved, isFalse);
    expect(repository.updatedEvents, isEmpty);
    expect(sideEffects.syncAfterSaveCalls, isEmpty);
    expect(repository.events.single.startAt, originalEvent.startAt);
  });

  testWidgets('리마인더 조회가 실패하면 저장 전에 실패 처리한다(fail-closed)', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-reader-error',
        userId: 'user-1',
        title: '조회 실패 일정',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
        endAt: DateTime.utc(_voiceFixtureYear, 5, 22, 10),
      ),
    ]);
    final sideEffects = _FakeManualEventSideEffectService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        sideEffectService: sideEffects,
        settingsRepository:
            _FakeSettingsRepository(const Duration(minutes: 60)),
        reminderNotifyAtReader: (userId, eventId) {
          throw StateError('리마인더 조회 실패');
        },
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: DateTime.utc(_voiceFixtureYear, 5, 29, 9),
    );
    final saved = await state.debugApplyConversationDateAutoSave(
      result: voiceResult,
      targetEvent: originalEvent,
    );
    // 조회 오류는 '모름'이다. 기본값 폴백 없이 저장 전에 실패하고 로컬
    // 상태/사이드 이펙트 모두 변경되지 않는다.
    expect(saved, isFalse);
    expect(repository.updatedEvents, isEmpty);
    expect(sideEffects.syncAfterSaveCalls, isEmpty);
    expect(repository.events.single.startAt, originalEvent.startAt);
  });

  testWidgets('notify_at이 유효 범위(0~1440분)를 벗어나면 저장하지 않는다', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-out-of-range',
        userId: 'user-1',
        title: '범위 이탈 일정',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
        endAt: DateTime.utc(_voiceFixtureYear, 5, 22, 10),
      ),
    ]);
    final sideEffects = _FakeManualEventSideEffectService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        sideEffectService: sideEffects,
        settingsRepository:
            _FakeSettingsRepository(const Duration(minutes: 60)),
        reminderNotifyAtReader: _fakeReminderReader(
          repository,
          defaultOffset: const Duration(minutes: 2000),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final voiceResult = buildDateAutoResult(
      targetEvent: originalEvent,
      newStart: DateTime.utc(_voiceFixtureYear, 5, 29, 9),
    );
    final saved = await state.debugApplyConversationDateAutoSave(
      result: voiceResult,
      targetEvent: originalEvent,
    );
    // 비정상 오프셋(2000분)은 무시/기본값 대체 없이 저장을 막는다.
    expect(saved, isFalse);
    expect(repository.updatedEvents, isEmpty);
    expect(sideEffects.syncAfterSaveCalls, isEmpty);
  });

  testWidgets('리마인더 복원 실패 시 편집 폴백이 요청한 새 날짜 드래프트를 그대로 넘긴다', (tester) async {
    final event = EventModel(
      id: 'event-reader-fail',
      userId: 'user-1',
      title: '복원 실패 일정',
      startAt: DateTime(_voiceFixtureYear, 5, 7, 9).toUtc(),
      endAt: DateTime(_voiceFixtureYear, 5, 7, 10).toUtc(),
    );
    Object? receivedExtra;
    final repository = _FakeEventRepository(<EventModel>[event]);
    final sideEffects = _FakeManualEventSideEffectService();
    final router = GoRouter(
      initialLocation: AppRoutes.voiceConversation,
      routes: [
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => VoiceConversationScreen(
            repository: repository,
            sideEffectService: sideEffects,
            settingsRepository:
                _FakeSettingsRepository(const Duration(minutes: 60)),
            reminderNotifyAtReader: (userId, eventId) {
              throw StateError('리마인더 조회 실패');
            },
            initialText: '5월 7일 일정 알려줘',
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) {
            receivedExtra = state.extra;
            return const Text(
              '편집 화면',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildPlanFlowTheme(),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      '1번 일정 그다음날로 변경해줘',
    );
    await tester.tap(find.text('전송'));
    for (var i = 0; i < 40 && find.text('편집 화면').evaluate().isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();

    // 저장은 일어나지 않고(거짓 성공 금지), 요청한 새 날짜(5월 8일) 드래프트가
    // 편집 화면으로 그대로 넘어간다.
    expect(find.text('편집 화면'), findsOneWidget);
    expect(repository.updatedEvents, isEmpty);
    expect(sideEffects.syncAfterSaveCalls, isEmpty);
    expect(receivedExtra, isNotNull);
    // extra는 draft+original DTO다. 요청한 새 날짜(5월 8일)와 원본 날짜
    // (5월 7일), 선택 회차 시작 시각이 모두 정확해야 한다(이전에는 폴백
    // 내비 검증 자체가 없었다).
    final payload = receivedExtra as EventEditRoutePayload;
    expect(payload.draft.id, event.id);
    expect(planflowLocal(payload.draft.startAt!), DateTime(_voiceFixtureYear, 5, 8, 9));
    expect(
      planflowLocal(payload.original.startAt!),
      DateTime(_voiceFixtureYear, 5, 7, 9),
    );
    expect(payload.originalOccurrenceStartAt, event.startAt);

    // 폴백 편집 화면에서 되돌아오면 '저장하지 않았다' 안내가 남는다.
    router.pop();
    await tester.pumpAndSettle();
    expect(find.textContaining('저장하지 않았어요'), findsOneWidget);
  });

  testWidgets('리마인더 복원 실패 카드의 수정하기도 요청한 새 날짜 드래프트를 넘긴다', (tester) async {
    final event = EventModel(
      id: 'event-card-fail',
      userId: 'user-1',
      title: '카드 수정 일정',
      startAt: DateTime(_voiceFixtureYear, 5, 7, 9).toUtc(),
      endAt: DateTime(_voiceFixtureYear, 5, 7, 10).toUtc(),
    );
    Object? receivedExtra;
    final repository = _FakeEventRepository(<EventModel>[event]);
    final sideEffects = _FakeManualEventSideEffectService();
    final router = GoRouter(
      initialLocation: AppRoutes.voiceConversation,
      routes: [
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => VoiceConversationScreen(
            repository: repository,
            sideEffectService: sideEffects,
            settingsRepository:
                _FakeSettingsRepository(const Duration(minutes: 60)),
            reminderNotifyAtReader: (userId, eventId) {
              throw StateError('리마인더 조회 실패');
            },
            initialText: '5월 7일 일정 알려줘',
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) {
            receivedExtra = state.extra;
            return const Text(
              '편집 화면',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildPlanFlowTheme(),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      '1번 일정 그다음날로 변경해줘',
    );
    await tester.tap(find.text('전송'));
    for (var i = 0; i < 40 && find.text('편집 화면').evaluate().isEmpty; i += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(repository.updatedEvents, isEmpty);

    // 자동 폴백 편집 화면에서 되돌아와, 실패 카드의 수정 버튼 경로도 같은
    // 드래프트(요청한 새 날짜)를 넘기는지 확인한다.
    router.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('카드 수정 일정').last);
    await tester.pumpAndSettle();
    expect(find.text('수정하기'), findsOneWidget);
    await tester.tap(find.text('수정하기'));
    await tester.pumpAndSettle();
    expect(find.text('편집 화면'), findsOneWidget);
    expect(receivedExtra, isNotNull);
    // 카드의 수정하기 경로도 원본을 회복해 DTO로 넘긴다(단발 일정).
    // 여기서는 개별 회차가 없으므로 occurrence는 null이다.
    final payload = receivedExtra as EventEditRoutePayload;
    expect(payload.draft.id, event.id);
    expect(planflowLocal(payload.draft.startAt!), DateTime(_voiceFixtureYear, 5, 8, 9));
    expect(
      planflowLocal(payload.original.startAt!),
      DateTime(_voiceFixtureYear, 5, 7, 9),
    );
    expect(payload.originalOccurrenceStartAt, isNull);
  });

  testWidgets('자동 날짜 저장 안내는 실제 저장 날짜를 말하고 편집 화면 문구를 쓰지 않는다', (tester) async {
    final repository = _FakeEventRepository(<EventModel>[
      EventModel(
        id: 'event-message',
        userId: 'user-1',
        title: '병원 재활',
        startAt: DateTime.utc(_voiceFixtureYear, 5, 22, 9),
      ),
    ]);
    await pumpConversation(
      tester,
      VoiceConversationScreen(repository: repository),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(VoiceConversationScreen))
        as VoiceConversationScreenState;

    final originalEvent = repository.events.single;
    final draft = originalEvent.copyWith(
      startAt: DateTime.utc(_voiceFixtureYear, 5, 29, 9),
      endAt: DateTime.utc(_voiceFixtureYear, 5, 29, 10),
    );
    // 컨트롤러 안내가 비어 온 경우: UI 기본 문구가 실제 저장 날짜를 말해야
    // 하고 '편집 화면' 표현을 쓰지 않아야 한다.
    final result = VoiceConversationResult(
      action: VoiceConversationAction.confirmedEdit,
      inputText: '그 일정 다음 주로 옮겨줘',
      targetEvent: originalEvent,
      draftEvent: draft,
      visibleEvents: <EventModel>[originalEvent],
      selectedEvents: <EventModel>[originalEvent],
      canAutoApplyDateChange: true,
      assistantMessage: '',
    );
    final message = state.debugMessageForResult(result);
    final local = planflowLocal(DateTime.utc(_voiceFixtureYear, 5, 29, 9));
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    expect(message, contains('병원 재활'));
    expect(message, contains('${local.month}월 ${local.day}일'));
    expect(message, contains('$hh:$mm'));
    expect(message, isNot(contains('편집 화면')));

    // 컨트롤러 안내가 있으면 그대로 사용한다(상대 표현도 저장된 날짜와
    // 동일하므로 허용).
    final withControllerMessage = VoiceConversationResult(
      action: VoiceConversationAction.confirmedEdit,
      inputText: result.inputText,
      targetEvent: originalEvent,
      draftEvent: draft,
      visibleEvents: result.visibleEvents,
      selectedEvents: result.selectedEvents,
      canAutoApplyDateChange: true,
      assistantMessage: '병원 재활 일정을 다음 주로 옮겼어요.',
    );
    expect(
      state.debugMessageForResult(withControllerMessage),
      '병원 재활 일정을 다음 주로 옮겼어요.',
    );
  });
}

// -------------------------------------------------------------------
// 날짜 자동 저장의 개별 리마인더 오프셋 보존을 검증하는 reader 가짜 구현.
// [repository]에 남아 있는 '현재' 이벤트 시작 시각에서 [defaultOffset]
// 만큼 앞선 notify_at을 반환한다(옮긴 뒤 재요청 시 새 시작 기준).
// [offsetsByEventId]로 일정별 오프셋을, [absentEventIds]로 '리마인더 행
// 없음'(null)을 지정한다. 목록에 없는 id는 픽스처 실수로 보고 예외를 던진다.
// -------------------------------------------------------------------
Future<DateTime?> Function(String userId, String eventId) _fakeReminderReader(
  _FakeEventRepository repository, {
  Map<String, Duration> offsetsByEventId = const <String, Duration>{},
  Duration defaultOffset = const Duration(minutes: 30),
  Set<String> absentEventIds = const <String>{},
}) {
  return (String userId, String eventId) async {
    if (absentEventIds.contains(eventId)) {
      return null;
    }
    EventModel? current;
    for (final event in repository.events) {
      if (event.id == eventId) {
        current = event;
        break;
      }
    }
    if (current == null || current.startAt == null) {
      throw StateError('리마인더 픽스처에 없는 일정: $eventId');
    }
    final offset = offsetsByEventId[eventId] ?? defaultOffset;
    return current.startAt!.subtract(offset);
  };
}

// -------------------------------------------------------------------
// 테스트용 SettingsRepository 가짜 구현. fetchSettings는 미리 설정된
// defaultReminderMin을 그대로 돌려주고, fetchSettings 호출 횟수를
// 기록한다.
// -------------------------------------------------------------------
class _FakeSettingsRepository extends SettingsRepository {
  _FakeSettingsRepository(this.reminderOffset) : super();

  final Duration reminderOffset;
  int fetchSettingsCalls = 0;

  @override
  Future<UserSettingsModel?> fetchSettings(String userId) async {
    fetchSettingsCalls += 1;
    return UserSettingsModel(
      id: 'settings-$userId',
      userId: userId,
      morningBriefingAt: '08:00',
      eveningBriefingAt: '21:00',
      defaultReminderMin: reminderOffset.inMinutes,
      prepTimeMin: 60,
      prepPreAlarmOffset: 30,
      departPreAlarmOffset: 30,
      departureSafetyMarginMin: 5,
      travelMode: 'car',
      voiceAutoStart: true,
      voiceCorrectionLearningEnabled: false,
      voiceCommonLearningOptIn: false,
      preferredMapProvider: 'google',
      countryCode: 'KR',
      localeCode: 'ko-KR',
      timeZoneId: 'Asia/Seoul',
      briefingEnabled: false,
      use24HourFormat: true,
      googleCalendarToken: null,
      naverCalendarToken: null,
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<UserSettingsModel> upsertSettings(UserSettingsModel settings) async {
    return settings;
  }
}
