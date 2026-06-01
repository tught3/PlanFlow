import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/local_time.dart';
import '../data/models/event_model.dart';
import '../data/models/pre_action_model.dart';
import 'notification_service.dart';

class SmartPreparationAlarmService {
  const SmartPreparationAlarmService({
    NotificationService? notificationService,
  }) : _notificationService = notificationService;

  static const String label = '스마트 준비 알람';
  static const int maxScheduledAlarmsPerEvent = 20;
  static const int defaultPrepTimeMin = 30;
  static const int defaultPrepPreAlarmOffset = 30;
  static const int defaultDepartPreAlarmOffset = 30;
  static const int defaultTravelBufferMin = 30;
  static const int externalScheduleSlackMin = 30;

  static const List<String> internalKeywords = <String>[
    '집',
    '재택',
    '자택',
    '집에서',
    '집앞',
    '온라인',
    '화상',
    '줌',
    'zoom',
    'zep',
    'webex',
    '구글밋',
    'google meet',
    'teams',
    'ms teams',
    '전화',
    '통화',
    '콜',
    '전화회의',
    '컨퍼런스콜',
    '내부',
    '사내',
    '팀내',
    '오피스',
    '자체',
  ];

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
    final purposeText = _normalizeText(
      <String>[
        rawText,
        title ?? '',
        memo ?? '',
        ...supplies,
      ].join(' '),
    );
    final locationText = _normalizeText(location ?? '');
    final searchable = _normalizeText(
      <String>[
        purposeText,
        locationText,
      ].join(' '),
    );
    final hasMedicalContext = _hasMedicalContext(
      purposeText: purposeText,
      locationText: locationText,
    );
    final hasFastingContext = _hasFastingContext(
      purposeText: purposeText,
      locationText: locationText,
    );
    final hasPatientVisitContext = _hasPatientVisitContext(purposeText);

    void add(String title, int offsetHours) {
      candidates.add(
        SmartPreparationAlarmCandidate(
          title: title,
          offsetHours: offsetHours,
          notifyAt: eventStartAt?.subtract(Duration(hours: offsetHours)),
        ),
      );
    }

    if (hasMedicalContext) {
      add('병원 준비사항 확인', 24);
      add('신분증과 서류 챙기기', 3);
    }

    if (hasFastingContext) {
      add('금식/복약 안내 확인', 12);
    }

    if (hasPatientVisitContext) {
      add('꽃이나 선물 챙기기', 3);
    }

    if (_hasMovementPreparationContext(
      purposeText: purposeText,
      locationText: locationText,
      hasMedicalContext: hasMedicalContext,
      hasPatientVisitContext: hasPatientVisitContext,
    )) {
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

  bool isExternalEvent({
    required String title,
    String? location,
  }) {
    final normalizedLocation = (location ?? '').trim().toLowerCase();
    if (normalizedLocation.isEmpty) {
      return false;
    }
    final normalizedTitle = title.trim().toLowerCase();
    for (final keyword in internalKeywords) {
      final normalizedKeyword = keyword.toLowerCase();
      if (normalizedLocation.contains(normalizedKeyword) ||
          normalizedTitle.contains(normalizedKeyword)) {
        return false;
      }
    }
    return true;
  }

  bool isFirstExternalEventOfDay({
    required EventModel event,
    required Iterable<EventModel> dayEvents,
  }) {
    final eventStartAt = event.startAt;
    if (eventStartAt == null ||
        !isExternalEvent(title: event.title, location: event.location)) {
      return false;
    }
    final externalEvents = dayEvents.where((candidate) {
      final startAt = candidate.startAt;
      if (startAt == null || !planflowIsSameLocalDay(startAt, eventStartAt)) {
        return false;
      }
      return isExternalEvent(
        title: candidate.title,
        location: candidate.location,
      );
    }).toList(growable: false)
      ..sort(
        (a, b) => (a.startAt ?? DateTime(0)).compareTo(
          b.startAt ?? DateTime(0),
        ),
      );
    if (externalEvents.isEmpty) {
      return false;
    }
    return externalEvents.first.id == event.id;
  }

  List<Map<String, dynamic>> buildExternalEventPayloads({
    required String eventId,
    required String userId,
    required String title,
    required DateTime eventStartAt,
    required String? location,
    int prepTimeMin = defaultPrepTimeMin,
    int prepPreAlarmOffset = defaultPrepPreAlarmOffset,
    int departPreAlarmOffset = defaultDepartPreAlarmOffset,
    int travelMinutes = defaultTravelBufferMin,
    bool travelMinutesIsFallback = false,
    int departureSafetyMarginMin = externalScheduleSlackMin,
    bool includePreparationAlarms = false,
    bool isFirstExternalEventOfDay = true,
    DateTime? now,
  }) {
    if (!isExternalEvent(title: title, location: location)) {
      return const <Map<String, dynamic>>[];
    }

    final safeNow = now ?? DateTime.now();
    final safePrepMin = prepTimeMin.clamp(5, 240).toInt();
    final safeTravelMin = travelMinutes.clamp(0, 360).toInt();
    final safeSafetyMarginMin = departureSafetyMarginMin.clamp(0, 120).toInt();
    final departureAt = eventStartAt.subtract(
      Duration(minutes: safeTravelMin + safeSafetyMarginMin),
    );
    final specs = <_ExternalAlarmSpec>[];

    if (isFirstExternalEventOfDay && includePreparationAlarms) {
      final prepStartAt = departureAt.subtract(Duration(minutes: safePrepMin));
      for (final offset in _expandedPreAlarmOffsets(prepPreAlarmOffset)) {
        specs.add(
          _ExternalAlarmSpec(
            title: '$offset분 뒤부터 준비 시작하세요 🔔',
            notifyAt: prepStartAt.subtract(Duration(minutes: offset)),
          ),
        );
      }
      specs.add(
        _ExternalAlarmSpec(
          title: '지금 준비 시작하세요 🚿',
          notifyAt: prepStartAt,
        ),
      );
    }

    for (final offset in _expandedPreAlarmOffsets(departPreAlarmOffset)) {
      specs.add(
        _ExternalAlarmSpec(
          title: '$offset분 뒤 출발해야 해요 🔔',
          notifyAt: departureAt.subtract(Duration(minutes: offset)),
        ),
      );
    }
    final departureTitle = travelMinutesIsFallback
        ? '지금 출발하세요 🚗 (이동 약 $safeTravelMin분 — 위치 확인 불가, 기본값)'
        : '지금 출발하세요 🚗 (이동 약 $safeTravelMin분)';
    specs.add(
      _ExternalAlarmSpec(
        title: departureTitle,
        notifyAt: departureAt,
      ),
    );

    final merged = <_ExternalAlarmSpec>[];
    for (final spec in specs
      ..sort((a, b) => a.notifyAt.compareTo(b.notifyAt))) {
      if (!spec.notifyAt.isAfter(safeNow)) {
        continue;
      }
      if (merged.isNotEmpty &&
          spec.notifyAt.difference(merged.last.notifyAt).inMinutes.abs() < 5) {
        merged[merged.length - 1] = _ExternalAlarmSpec(
          title: '${merged.last.title} / ${spec.title}',
          notifyAt: merged.last.notifyAt,
        );
        continue;
      }
      merged.add(spec);
    }

    return merged
        .map(
          (spec) => <String, dynamic>{
            'event_id': eventId,
            'user_id': userId,
            'title': spec.title,
            'notify_at': spec.notifyAt.toIso8601String(),
            'is_done': false,
            'source': 'external_preparation',
          },
        )
        .toList(growable: false);
  }

  List<int> _expandedPreAlarmOffsets(int offset) {
    if (offset == 31) {
      return const <int>[30, 10];
    }
    if (offset <= 0) {
      return const <int>[];
    }
    return <int>[offset];
  }

  Future<void> schedulePayloads({
    required String eventId,
    required String eventTitle,
    required List<Map<String, dynamic>> payloads,
    String notificationKeyPrefix = 'smart_preparation',
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
          '$eventId:$notificationKeyPrefix:$index',
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
        .eq('source', 'external_preparation')
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
        .eq('source', 'external_preparation')
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

  bool _hasMovementPreparationContext({
    required String purposeText,
    required String locationText,
    required bool hasMedicalContext,
    required bool hasPatientVisitContext,
  }) {
    final combined = '$purposeText $locationText'.trim();
    if (hasMedicalContext || hasPatientVisitContext) {
      return true;
    }
    if (_containsAny(combined, const <String>[
      '이동',
      '출발',
      '도착',
      '공항',
      '터미널',
      '기차역',
      '버스터미널',
      '면접',
    ])) {
      return true;
    }
    if (_containsAny(locationText, const <String>[
      '역',
      '공항',
      '터미널',
    ])) {
      return true;
    }
    return false;
  }

  bool _hasMedicalContext({
    required String purposeText,
    required String locationText,
  }) {
    final combined = '$purposeText $locationText'.trim();
    if (_containsExplicitMedicalProcedure(purposeText)) {
      return true;
    }

    final hasMedicalPlace = _containsAny(combined, const <String>[
      '병원',
      '의원',
      '클리닉',
      '치과',
      '한의원',
      '내과',
      '외과',
      '산부인과',
      '정형외과',
      '이비인후과',
      '검진센터',
    ]);
    if (!hasMedicalPlace) {
      return false;
    }

    final hasMedicalAction = _containsContextualMedicalAction(purposeText);
    if (_containsAny(purposeText, const <String>[
          '회의',
          '미팅',
          '업무',
          '출근',
          '면접',
          '병문안',
          '문병',
          '납품',
          '배송',
          '배달',
          '강의',
          '수업',
        ]) &&
        !hasMedicalAction) {
      return false;
    }

    return hasMedicalAction;
  }

  bool _containsContextualMedicalAction(String text) {
    if (RegExp(r'검진(?!센터)').hasMatch(text)) {
      return true;
    }
    return _containsAny(text, const <String>[
      '의료',
      '진료',
      '검사',
      '수술',
      '채혈',
      '치료',
      '접종',
      '처방',
      '입원',
      '퇴원',
      '예약',
      '상담',
    ]);
  }

  bool _hasFastingContext({
    required String purposeText,
    required String locationText,
  }) {
    if (_containsExplicitFastingContext(purposeText)) {
      return true;
    }

    if (!_hasMedicalContext(
      purposeText: purposeText,
      locationText: locationText,
    )) {
      return false;
    }

    return _containsAny(purposeText, const <String>[
      '검진',
      '검사',
      '수술',
    ]);
  }

  bool _containsExplicitMedicalProcedure(String text) {
    return RegExp(r'(?:위내시경|대장내시경|내시경|건강검진)(?!센터)').hasMatch(text);
  }

  bool _containsExplicitFastingContext(String text) {
    return _containsExplicitMedicalProcedure(text) ||
        _containsAny(text, const <String>[
          '금식',
          '마취',
        ]);
  }

  bool _hasPatientVisitContext(String text) {
    return _containsAny(text, const <String>[
      '병문안',
      '문병',
    ]);
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

class _ExternalAlarmSpec {
  const _ExternalAlarmSpec({
    required this.title,
    required this.notifyAt,
  });

  final String title;
  final DateTime notifyAt;
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
