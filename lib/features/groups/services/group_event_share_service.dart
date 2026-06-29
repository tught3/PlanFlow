import '../../../core/local_time.dart';
import '../../../data/models/event_model.dart';
import '../../../data/repositories/event_repository.dart';
import '../models/group_event_model.dart';
import '../repositories/group_event_repository.dart';

class GroupEventShareResult {
  const GroupEventShareResult({
    required this.sharedCount,
    required this.duplicateCount,
    required this.skippedCount,
    required this.failedCount,
  });

  final int sharedCount;
  final int duplicateCount;
  final int skippedCount;
  final int failedCount;

  String get summary =>
      '공유 $sharedCount개 · 중복 제외 $duplicateCount개 · 실패 $failedCount개';
}

class GroupEventShareService {
  const GroupEventShareService({
    required EventRepository eventRepository,
    required GroupEventRepository groupEventRepository,
    DateTime Function()? nowProvider,
  })  : _eventRepository = eventRepository,
        _groupEventRepository = groupEventRepository,
        _nowProvider = nowProvider ?? DateTime.now;

  final EventRepository _eventRepository;
  final GroupEventRepository _groupEventRepository;
  final DateTime Function() _nowProvider;

  Future<GroupEventShareResult> shareUpcomingManualEvents({
    required String userId,
    required String groupId,
  }) async {
    final todayStart = _todayStartUtc();
    final personalEvents = await _eventRepository.listEvents(userId: userId);
    final existingGroupEvents = await _groupEventRepository.getEventsForGroup(
      groupId,
      todayStart,
      DateTime.utc(9999, 12, 31),
    );
    final existingKeys = existingGroupEvents.map(_duplicateKey).toSet();

    var sharedCount = 0;
    var duplicateCount = 0;
    var skippedCount = 0;
    var failedCount = 0;

    for (final event in personalEvents) {
      if (!_isShareCandidate(event, todayStart)) {
        skippedCount += 1;
        continue;
      }

      final groupDraft = _groupEventFromPersonalEvent(event, groupId);
      final key = _duplicateKey(groupDraft);
      if (existingKeys.contains(key)) {
        duplicateCount += 1;
        continue;
      }

      try {
        final created =
            await _groupEventRepository.createGroupEvent(groupDraft);
        existingKeys.add(_duplicateKey(created));
        await _eventRepository.updateEvent(
          event.copyWith(groupEventId: created.id),
        );
        sharedCount += 1;
      } catch (_) {
        failedCount += 1;
      }
    }

    return GroupEventShareResult(
      sharedCount: sharedCount,
      duplicateCount: duplicateCount,
      skippedCount: skippedCount,
      failedCount: failedCount,
    );
  }

  DateTime _todayStartUtc() {
    final localNow = planflowLocal(_nowProvider().toUtc());
    return planflowLocalDateTimeToUtc(
      DateTime(localNow.year, localNow.month, localNow.day),
    );
  }

  bool _isShareCandidate(EventModel event, DateTime todayStartUtc) {
    final startAt = event.startAt;
    if (startAt == null || startAt.toUtc().isBefore(todayStartUtc)) {
      return false;
    }
    return event.source.trim().toLowerCase() == 'manual';
  }

  GroupEventModel _groupEventFromPersonalEvent(
    EventModel event,
    String groupId,
  ) {
    final startAt = event.startAt;
    if (startAt == null) {
      throw StateError('시작 시간이 없는 일정은 공유할 수 없어요.');
    }
    return GroupEventModel(
      id: '',
      groupId: groupId,
      title: event.title,
      description: event.memo,
      location: event.location,
      startAt: startAt,
      endAt: event.endAt ?? startAt.add(const Duration(minutes: 30)),
      allDay: event.isAllDay,
      recurrenceType: _groupRecurrenceTypeFor(event.recurrenceRule),
      createdBy: event.userId,
      personalEventId: event.id,
      status: 'active',
    );
  }

  String _groupRecurrenceTypeFor(String? recurrenceRule) {
    final rule = recurrenceRule?.toUpperCase() ?? '';
    if (rule.contains('FREQ=DAILY')) {
      return 'daily';
    }
    if (rule.contains('FREQ=WEEKLY')) {
      return 'weekly';
    }
    if (rule.contains('FREQ=MONTHLY')) {
      return 'monthly';
    }
    return 'none';
  }

  String _duplicateKey(GroupEventModel event) {
    return [
      event.groupId,
      event.title.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase(),
      event.startAt.toUtc().toIso8601String(),
      event.endAt.toUtc().toIso8601String(),
    ].join('|');
  }
}
