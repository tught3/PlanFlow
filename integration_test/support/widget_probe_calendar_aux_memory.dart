// Pure in-memory fixtures for the calendar widget probe legs that need to
// cover the real `CalendarScreen` constructor seam for
// `groupCalendarOverlayProvider` + `groupInstructionInboxService` without
// spinning up a Supabase client.
//
// The fixture exposes three repositories that EXTEND the public abstract
// classes (`GroupRepository`, `GroupEventRepository`,
// `GroupEventCommentRepository`). Read methods return empty lists with a
// per-method counter (the screen legitimately sees "no groups" / "no
// unread instructions"), and any non-read path throws `UnsupportedError`
// so the fixture is fail-closed: it cannot mask an actual code path with
// a fake HTTP success.
//
// CalendarAuxMemory owns the overlay and context borrowed by the screen.
// Call disposeAfterWidgetUnmount after the widget has been unmounted,
// including when assertions fail, to preserve the borrowed lifecycle.
//
// The injected service and memory repositories add:
//   * no SDK initializer / client overrides,
//   * no new dependencies,
//   * no readiness flag toggles,
//   * no fake auth.
//
// These classes intentionally have NO coupling to `supabase_flutter`, so
// they may be loaded in unit-test or integration-test binaries alike.

import 'package:flutter_test/flutter_test.dart' show Fake;
import 'package:planflow/features/groups/models/group_event_comment_model.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_calendar_overlay_provider.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/repositories/group_event_comment_repository.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/features/groups/services/group_instruction_inbox_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory `GroupRepository`: reads return the same constant empty list,
/// every other path throws `UnsupportedError` so the fixture cannot mask
/// an actual production code path with a fake success.
class MemoryGroupRepository extends GroupRepository {
  MemoryGroupRepository();

  /// Number of times `listGroups()` has been called (read counter).
  int listGroupsCalls = 0;

  /// Number of times `listMembers(...)` has been called (read counter).
  int listMembersCalls = 0;

  /// Number of times `fetchGroup(...)` has been called (read counter).
  int fetchGroupCalls = 0;

  /// Number of times `listMembersForHistory(...)` has been called.
  int listMembersForHistoryCalls = 0;

  @override
  Future<List<GroupModel>> listGroups() async {
    listGroupsCalls++;
    return const <GroupModel>[];
  }

  @override
  Future<GroupModel?> fetchGroup(String groupId) async {
    fetchGroupCalls++;
    return null;
  }

  @override
  Future<List<GroupMemberModel>> listMembers(String groupId) async {
    listMembersCalls++;
    return const <GroupMemberModel>[];
  }

  @override
  Future<List<GroupMemberModel>> listMembersForHistory(String groupId) async {
    listMembersForHistoryCalls++;
    return const <GroupMemberModel>[];
  }

  @override
  Future<GroupModel> createGroup(GroupModel group) {
    throw UnsupportedError(
      'MemoryGroupRepository has no write paths; createGroup is fail-closed.',
    );
  }

  @override
  Future<GroupModel> updateGroup(GroupModel group) {
    throw UnsupportedError(
      'MemoryGroupRepository has no write paths; updateGroup is fail-closed.',
    );
  }

  @override
  Future<GroupMemberModel> addMember(GroupMemberModel member) {
    throw UnsupportedError(
      'MemoryGroupRepository has no write paths; addMember is fail-closed.',
    );
  }

  @override
  Future<GroupMemberModel> updateMember(GroupMemberModel member) {
    throw UnsupportedError(
      'MemoryGroupRepository has no write paths; updateMember is fail-closed.',
    );
  }
}

/// In-memory `GroupEventRepository`: reads return an empty list with a
/// per-method counter, writes and per-event lookups throw
/// `UnsupportedError`. `fetchGroupEvent` is included so the inbox's
/// "unconfirmed personal event ids" path is covered with a fail-closed
/// lookup (the inbox's outer try/catch converts it to a benign empty
/// result, never a fake success).
class MemoryGroupEventRepository extends GroupEventRepository {
  MemoryGroupEventRepository();

  /// Number of times `getEventsForGroup(...)` has been called.
  int getEventsForGroupCalls = 0;

  /// Number of times `fetchGroupEvent(...)` has been called.
  int fetchGroupEventCalls = 0;

  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async {
    getEventsForGroupCalls++;
    return const <GroupEventModel>[];
  }

  @override
  Future<GroupEventModel> fetchGroupEvent(String eventId) async {
    fetchGroupEventCalls++;
    throw UnsupportedError(
      'MemoryGroupEventRepository has no events; fetchGroupEvent is fail-closed.',
    );
  }

  @override
  Future<GroupEventModel> createGroupEvent(GroupEventModel event) {
    throw UnsupportedError(
      'MemoryGroupEventRepository has no write paths; createGroupEvent is fail-closed.',
    );
  }

  @override
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) {
    throw UnsupportedError(
      'MemoryGroupEventRepository has no write paths; updateGroupEvent is fail-closed.',
    );
  }

  @override
  Future<GroupEventModel> cancelGroupEvent(String eventId) {
    throw UnsupportedError(
      'MemoryGroupEventRepository has no write paths; cancelGroupEvent is fail-closed.',
    );
  }

  @override
  Future<GroupEventModel> archiveGroupEvent(String eventId) {
    throw UnsupportedError(
      'MemoryGroupEventRepository has no write paths; archiveGroupEvent is fail-closed.',
    );
  }
}

/// In-memory `GroupEventCommentRepository`: reads return an empty list
/// with per-method counters, write paths throw `UnsupportedError`.
class MemoryGroupEventCommentRepository extends GroupEventCommentRepository {
  MemoryGroupEventCommentRepository();

  /// Number of times `getCommentsForEvent(...)` has been called.
  int getCommentsForEventCalls = 0;

  /// Number of times `unconfirmedForUser(...)` has been called.
  int unconfirmedForUserCalls = 0;

  @override
  Future<List<GroupEventCommentModel>> getCommentsForEvent(
    String groupEventId,
  ) async {
    getCommentsForEventCalls++;
    return const <GroupEventCommentModel>[];
  }

  @override
  Future<List<GroupEventCommentModel>> unconfirmedForUser(String userId) async {
    unconfirmedForUserCalls++;
    return const <GroupEventCommentModel>[];
  }

  @override
  Future<GroupEventCommentModel> createComment(
    GroupEventCommentModel comment,
  ) {
    throw UnsupportedError(
      'MemoryGroupEventCommentRepository has no write paths; createComment is fail-closed.',
    );
  }

  @override
  Future<GroupEventCommentModel> confirmComment(String commentId) {
    throw UnsupportedError(
      'MemoryGroupEventCommentRepository has no write paths; confirmComment is fail-closed.',
    );
  }
}

/// Instance-local preferences. Unsupported APIs throw via Fake.noSuchMethod;
/// no singleton, platform override, or persistent storage is touched.
class MemoryCalendarPreferences extends Fake implements SharedPreferences {
  final Map<String, String> _values = <String, String>{};

  @override
  String? getString(String key) => _values[key];

  @override
  Future<bool> setString(String key, String value) async {
    _values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _values.remove(key);
    return true;
  }

  @override
  Set<String> getKeys() => _values.keys.toSet();

  @override
  bool containsKey(String key) => _values.containsKey(key);
}

/// Caller-owned helper that exposes all three repositories AND the
/// derived providers the calendar probe needs.
///
/// Construction is intentionally NOT a singleton: each test that uses it
/// must create a fresh `CalendarAuxMemory` so counter assertions cannot
/// leak between cases. The helper holds:
///
///   * `memoryGroups` (GroupRepository)         — `extends GroupRepository`
///   * `memoryGroupEvents` (GroupEventRepository) — `extends GroupEventRepository`
///   * `memoryComments` (GroupEventCommentRepository) — `extends GroupEventCommentRepository`
///   * `context` — `GroupContextProvider(repository: memoryGroups, preferences: memoryPreferences)`
///   * `overlay` — `GroupCalendarOverlayProvider(contextProvider: context, repository: memoryGroupEvents)`
///   * `inbox`   — `GroupInstructionInboxService(commentRepository: memoryComments, eventRepository: memoryGroupEvents)`
///
/// The overlay borrows the context; the screen borrows the overlay.
/// This helper owns both and explicitly releases them after widget unmount.
/// Selected-group preferences are injected through the public constructor
/// and kept in a separate memory map per helper instance.
///
/// Lifecycle contract:
///
///   1. Construct the helper BEFORE the widget mounts.
///   2. Pass `overlay` and `inbox` to the screen constructor seam.
///   3. Drive the screen (pump / wait until rendered / assertions).
///   4. Unmount the widget FIRST (`tester.pumpWidget(SizedBox.shrink())`).
///   5. Call `disposeAfterWidgetUnmount()` AFTER unmount.
///
/// Ordering matters: the CalendarScreen holds a `ChangeNotifier`
/// subscription on the overlay, so disposing the overlay before unmount
/// would log a `setState() called after dispose()` error in the test
/// output and pollute the negative-path expectation set. We unmount the
/// widget first to give the screen's `dispose()` a chance to run.
class CalendarAuxMemory {
  CalendarAuxMemory();

  final MemoryGroupRepository memoryGroups = MemoryGroupRepository();
  final MemoryGroupEventRepository memoryGroupEvents =
      MemoryGroupEventRepository();
  final MemoryGroupEventCommentRepository memoryComments =
      MemoryGroupEventCommentRepository();

  final MemoryCalendarPreferences memoryPreferences =
      MemoryCalendarPreferences();

  late final GroupContextProvider context = GroupContextProvider(
    repository: memoryGroups,
    preferences: memoryPreferences,
  );
  late final GroupCalendarOverlayProvider overlay =
      GroupCalendarOverlayProvider(
    contextProvider: context,
    repository: memoryGroupEvents,
  );
  late final GroupInstructionInboxService inbox =
      GroupInstructionInboxService(
    commentRepository: memoryComments,
    eventRepository: memoryGroupEvents,
  );

  bool _disposed = false;

  /// Owner disposal. Must run AFTER the widget has been unmounted.
  ///
  /// The overlay borrows its context, so this owner disposes both explicitly.
  /// The inbox service has no disposable notifier resources.
  Future<void> disposeAfterWidgetUnmount() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    try {
      overlay.dispose();
    } finally {
      context.dispose();
    }
  }
}
