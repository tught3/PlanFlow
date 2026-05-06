import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models/pre_action_model.dart';
import 'notification_service.dart';

class SmartPreparationAlarmService {
  const SmartPreparationAlarmService({
    NotificationService? notificationService,
  }) : _notificationService = notificationService;

  static const String label = '스마트 준비 알람';
  static const int maxScheduledAlarmsPerEvent = 20;

  final NotificationService? _notificationService;

  NotificationService get _notifications =>
      _notificationService ?? NotificationService();

  List<Map<String, dynamic>> enrichParsedSchedule(
    Map<String, dynamic> schedule, {
    required String rawText,
  }) {
    final eventStartAt = _dateTimeValue(schedule['start_at']);
    final candidates = buildCandidates(
      rawText: rawText,
      title: _stringValue(schedule['title']),
      location: _stringValue(schedule['location']),
      memo: _stringValue(schedule['memo']),
      supplies: _stringListValue(schedule['supplies']),
      existingPreActions: schedule['pre_actions'],
      eventStartAt: eventStartAt,
    );
    return candidates.map((candidate) => candidate.toJson()).toList();
  }

  List<SmartPreparationAlarmCandidate> buildCandidates({
    required String rawText,
    String? title,
    String? location,
    String? memo,
    List<String> supplies = const <String>[],
    Object? existingPreActions,
    DateTime? eventStartAt,
  }) {
    final candidates = <SmartPreparationAlarmCandidate>[
      ..._existingCandidates(existingPreActions, eventStartAt: eventStartAt),
    ];
    final searchable = _normalizeText(
      <String>[
        rawText,
        title ?? '',
        location ?? '',
        memo ?? '',
        ...supplies,
      ].join(' '),
    );

    void add(String title, int offsetHours) {
      candidates.add(
        SmartPreparationAlarmCandidate(
          title: title,
          offsetHours: offsetHours,
          notifyAt: eventStartAt?.subtract(Duration(hours: offsetHours)),
        ),
      );
    }

    if (_containsAny(searchable, const <String>[
      '의료',
      '검사',
      '내시경',
      '병원',
      '건강검진',
      '검진',
      '진료',
      '수술',
      '치과',
      '채혈',
    ])) {
      add('병원 준비사항 확인', 24);
      add('신분증과 서류 챙기기', 3);
    }

    if (_containsAny(searchable, const <String>[
      '내시경',
      '위내시경',
      '대장내시경',
      '금식',
      '마취',
      '검진',
      '검사',
    ])) {
      add('금식/복약 안내 확인', 12);
    }

    if (_containsAny(searchable, const <String>[
      '이동',
      '방문',
      '미팅',
      '회의',
      '예약',
      '약속',
      '면접',
      '출발',
      '도착',
    ])) {
      add('이동시간과 출발 시간 확인', 2);
    }

    if (supplies.isNotEmpty ||
        _containsAny(searchable, const <String>[
          '준비물',
          '챙겨',
          '챙기',
          '가져가',
          '여권',
          '충전기',
          '서류',
          '자료',
        ])) {
      add('준비물 챙기기', 3);
    }

    return _deduplicate(candidates);
  }

  List<Map<String, dynamic>> buildPayloads({
    required String eventId,
    required String userId,
    required DateTime eventStartAt,
    required Iterable<SmartPreparationAlarmCandidate> candidates,
  }) {
    final now = DateTime.now();
    return candidates
        .map((candidate) {
          final title = candidate.title.trim();
          if (title.isEmpty) {
            return null;
          }
          final offsetHours =
              candidate.offsetHours < 0 ? 0 : candidate.offsetHours;
          final notifyAt = candidate.notifyAt ??
              eventStartAt.subtract(Duration(hours: offsetHours));
          if (!notifyAt.isAfter(now)) {
            return null;
          }
          return <String, dynamic>{
            'event_id': eventId,
            'user_id': userId,
            'title': title,
            'notify_at': notifyAt.toIso8601String(),
            'is_done': false,
          };
        })
        .whereType<Map<String, dynamic>>()
        .toList(growable: true);
  }

  Future<void> schedulePayloads({
    required String eventId,
    required String eventTitle,
    required List<Map<String, dynamic>> payloads,
  }) async {
    for (var index = 0; index < payloads.length; index += 1) {
      final payload = payloads[index];
      final notifyAt = _dateTimeValue(payload['notify_at']);
      if (notifyAt == null || !notifyAt.isAfter(DateTime.now())) {
        continue;
      }
      final title = _stringValue(payload['title']) ?? label;
      await _notifications.scheduleEventReminder(
        id: _notifications.notificationIdFor(
          '$eventId:smart_preparation:$index',
        ),
        title: label,
        body: '$label: $title\n$eventTitle 일정 전에 필요한 준비를 확인해 주세요.',
        notifyAt: notifyAt,
      );
    }
  }

  Future<void> cancelForEvent(String eventId) {
    return _notifications.cancelSmartPreparationAlarms(eventId);
  }

  Future<List<PreActionModel>> listForEvent({
    required String eventId,
    required String userId,
  }) async {
    final response = await Supabase.instance.client
        .from('pre_actions')
        .select()
        .eq('event_id', eventId)
        .eq('user_id', userId)
        .order('notify_at', ascending: true);

    return response
        .whereType<Map<String, dynamic>>()
        .map(PreActionModel.fromJson)
        .toList(growable: false);
  }

  Future<Set<String>> listEventIdsWithSmartAlarms({
    required String userId,
    required Iterable<String> eventIds,
  }) async {
    final ids = eventIds.where((id) => id.trim().isNotEmpty).toSet();
    if (ids.isEmpty) {
      return const <String>{};
    }

    final response = await Supabase.instance.client
        .from('pre_actions')
        .select('event_id')
        .eq('user_id', userId)
        .inFilter('event_id', ids.toList(growable: false));

    return response
        .whereType<Map<String, dynamic>>()
        .map((row) => row['event_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  List<SmartPreparationAlarmCandidate> _existingCandidates(
    Object? rawPreActions, {
    DateTime? eventStartAt,
  }) {
    if (rawPreActions is! List) {
      return const <SmartPreparationAlarmCandidate>[];
    }
    return rawPreActions
        .whereType<Map>()
        .map((item) {
          final title = _stringValue(item['title']);
          if (title == null) {
            return null;
          }
          final offsetHours = _intValue(item['offset_hours']) ?? 1;
          return SmartPreparationAlarmCandidate(
            title: title,
            offsetHours: offsetHours,
            notifyAt: _dateTimeValue(item['notify_at']) ??
                eventStartAt?.subtract(Duration(hours: offsetHours)),
          );
        })
        .whereType<SmartPreparationAlarmCandidate>()
        .toList(growable: false);
  }

  List<SmartPreparationAlarmCandidate> _deduplicate(
    List<SmartPreparationAlarmCandidate> candidates,
  ) {
    final seen = <String>{};
    final deduplicated = <SmartPreparationAlarmCandidate>[];
    for (final candidate in candidates) {
      final key = _normalizeText(candidate.title);
      if (key.isEmpty || seen.contains(key)) {
        continue;
      }
      seen.add(key);
      deduplicated.add(candidate);
    }
    return deduplicated;
  }

  bool _containsAny(String text, List<String> keywords) {
    return keywords.any(text.contains);
  }

  String _normalizeText(String text) {
    return text
        .replaceAll(RegExp(r'[,\.\!\?\(\)\[\]\{\}/]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase();
  }

  String? _stringValue(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return text;
  }

  List<String> _stringListValue(Object? value) {
    if (value is List) {
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    return const <String>[];
  }

  int? _intValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value.toString());
  }

  DateTime? _dateTimeValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is DateTime) {
      return value;
    }
    final text = value.toString().trim();
    if (text.isEmpty) {
      return null;
    }
    return DateTime.tryParse(text);
  }
}

class SmartPreparationAlarmCandidate {
  const SmartPreparationAlarmCandidate({
    required this.title,
    required this.offsetHours,
    this.notifyAt,
  });

  final String title;
  final int offsetHours;
  final DateTime? notifyAt;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'title': title,
      'offset_hours': offsetHours,
      if (notifyAt != null) 'notify_at': notifyAt!.toIso8601String(),
    };
  }
}
