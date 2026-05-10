import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/env.dart';
import '../core/event_metadata.dart';
import 'remote_config_service.dart';
import 'smart_preparation_alarm_service.dart';

class GptCompletionException implements Exception {
  const GptCompletionException(
    this.reason,
    this.message, {
    this.statusCode,
    this.bodySnippet,
    this.cause,
  });

  final String reason;
  final String message;
  final int? statusCode;
  final String? bodySnippet;
  final Object? cause;

  @override
  String toString() {
    final parts = <String>[
      'GptCompletionException(reason: $reason, message: $message',
      if (statusCode != null) 'statusCode: $statusCode',
      if (bodySnippet != null && bodySnippet!.isNotEmpty) 'body: $bodySnippet',
      if (cause != null) 'cause: $cause',
    ];
    return '${parts.join(', ')})';
  }
}

class GptService {
  GptService({
    http.Client? client,
    Uri? endpoint,
    DateTime Function()? now,
  })  : _client = client,
        _endpoint = endpoint ??
            Uri.parse('${AppEnv.supabaseUrl}/functions/v1/openai-proxy'),
        _now = now ?? DateTime.now;

  final http.Client? _client;
  final Uri _endpoint;
  final DateTime Function() _now;

  static String get _model => RemoteConfigService.gptModel;
  static const Map<String, dynamic> _responseFormat = <String, dynamic>{
    'type': 'json_object',
  };

  Future<Map<String, dynamic>> parseSchedule(String rawText) async {
    final content = await _requestCompletion(
      systemPrompt: _scheduleSystemPrompt,
      userPrompt: rawText,
      responseFormat: _responseFormat,
    );

    final parsed = _decodeJsonMap(content);
    if (parsed == null) {
      return _fallbackSchedule(
        rawText: rawText,
        rawResponse: content,
      );
    }

    return _normalizeSchedule(parsed, rawText);
  }

  DateTime? inferStartAtFromRawText(String rawText) {
    return _inferStartAtFromRawText(rawText);
  }

  Future<String> generateMorningBriefing(String rawText) {
    return generateBriefing(rawText: rawText, isMorning: true);
  }

  Future<String> generateEveningBriefing(String rawText) {
    return generateBriefing(rawText: rawText, isMorning: false);
  }

  Future<String> generateBriefing({
    required String rawText,
    required bool isMorning,
  }) async {
    final content = await _requestCompletion(
      systemPrompt: isMorning ? _morningBriefingPrompt : _eveningBriefingPrompt,
      userPrompt: rawText,
      throwOnFailure: true,
    );

    final briefing = content?.trim();
    if (briefing == null || briefing.isEmpty) {
      throw const GptCompletionException(
        'empty_content',
        'OpenAI 응답이 비어 있습니다.',
      );
    }

    return briefing;
  }

  Future<String?> _requestCompletion({
    required String systemPrompt,
    required String userPrompt,
    Map<String, dynamic>? responseFormat,
    bool throwOnFailure = false,
  }) async {
    final client = _client ?? http.Client();
    try {
      final response = await client.post(
        _endpoint,
        headers: <String, String>{
          'Authorization': 'Bearer ${AppEnv.supabaseAnonKey}',
          'apikey': AppEnv.supabaseAnonKey,
          'Content-Type': 'application/json',
        },
        body: jsonEncode(<String, dynamic>{
          'model': _model,
          'messages': <Map<String, String>>[
            <String, String>{
              'role': 'system',
              'content': systemPrompt,
            },
            <String, String>{
              'role': 'user',
              'content': userPrompt,
            },
          ],
          if (responseFormat != null) 'response_format': responseFormat,
        }),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (throwOnFailure) {
          throw GptCompletionException(
            'http_${response.statusCode}',
            'OpenAI 요청이 실패했습니다.',
            statusCode: response.statusCode,
            bodySnippet: _safeBodySnippet(response),
          );
        }
        return null;
      }

      final decodedText = utf8.decode(response.bodyBytes);
      final decoded = jsonDecode(decodedText);
      if (decoded is! Map<String, dynamic>) {
        if (throwOnFailure) {
          throw GptCompletionException(
            'invalid_json_shape',
            'OpenAI 응답 형식이 올바르지 않습니다.',
            bodySnippet: _truncate(decodedText),
          );
        }
        return null;
      }

      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) {
        if (throwOnFailure) {
          throw const GptCompletionException(
            'missing_choices',
            'OpenAI 응답에 choices가 없습니다.',
          );
        }
        return null;
      }

      final firstChoice = choices.first;
      if (firstChoice is! Map<String, dynamic>) {
        if (throwOnFailure) {
          throw const GptCompletionException(
            'invalid_choice',
            'OpenAI choices 항목 형식이 올바르지 않습니다.',
          );
        }
        return null;
      }

      final message = firstChoice['message'];
      if (message is! Map<String, dynamic>) {
        if (throwOnFailure) {
          throw const GptCompletionException(
            'missing_message',
            'OpenAI 응답에 message가 없습니다.',
          );
        }
        return null;
      }

      final content = message['content'];
      if (content is! String) {
        if (throwOnFailure) {
          throw const GptCompletionException(
            'missing_content',
            'OpenAI 응답에 content가 없습니다.',
          );
        }
        return null;
      }

      return content;
    } on GptCompletionException {
      rethrow;
    } catch (error) {
      if (throwOnFailure) {
        throw GptCompletionException(
          'network_or_parse_error',
          'OpenAI 요청 또는 응답 처리 중 오류가 발생했습니다.',
          cause: error,
        );
      }
      return null;
    } finally {
      if (_client == null) {
        client.close();
      }
    }
  }

  String _safeBodySnippet(http.Response response) {
    try {
      return _truncate(utf8.decode(response.bodyBytes));
    } catch (_) {
      return _truncate(response.body);
    }
  }

  String _truncate(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 300) {
      return normalized;
    }
    return '${normalized.substring(0, 300)}...';
  }

  Map<String, dynamic>? _decodeJsonMap(String? content) {
    if (content == null) {
      return null;
    }

    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}

    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return null;
    }

    try {
      final decoded = jsonDecode(trimmed.substring(start, end + 1));
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}

    return null;
  }

  Map<String, dynamic> _normalizeSchedule(
    Map<String, dynamic> parsed,
    String rawText,
  ) {
    final normalized = Map<String, dynamic>.from(parsed);
    normalized['parse_failed'] = false;
    normalized.putIfAbsent('raw_text', () => rawText);
    normalized.putIfAbsent('location_lat', () => null);
    normalized.putIfAbsent('location_lng', () => null);
    normalized.putIfAbsent('travel_origin_lat', () => null);
    normalized.putIfAbsent('travel_origin_lng', () => null);
    normalized.putIfAbsent('travel_mode', () => null);
    normalized.putIfAbsent('recurrence_rule', () => null);
    normalized.putIfAbsent('is_all_day', () => false);
    normalized.putIfAbsent('is_multi_day', () => false);
    normalized.putIfAbsent('category', () => '기타');
    normalized['category'] = _normalizeCategoryFromRawText(
      rawText,
      normalized['category'],
    );
    normalized['recurrence_rule'] =
        _normalizeRecurrenceFromRawText(rawText, normalized['recurrence_rule']);
    _normalizeEventTypeFromRawText(rawText, normalized);
    normalized['supplies'] = _normalizeSupplies(normalized['supplies']);
    normalized['pre_actions'] = _normalizePreActions(normalized['pre_actions']);
    final inferredStartAt = _inferStartAtFromRawText(rawText);
    if (inferredStartAt != null &&
        _shouldPreferInferredStartAt(
          rawText: rawText,
          parsedStartAt: _parseDateTime(normalized['start_at']),
          inferredStartAt: inferredStartAt,
        )) {
      normalized['start_at'] = inferredStartAt.toIso8601String();
    }
    normalized['pre_actions'] =
        const SmartPreparationAlarmService().enrichParsedSchedule(
      normalized,
      rawText: rawText,
    );
    return normalized;
  }

  Map<String, dynamic> _fallbackSchedule({
    required String rawText,
    String? rawResponse,
  }) {
    final inferredStartAt = _inferStartAtFromRawText(rawText);
    final fallback = <String, dynamic>{
      'parse_failed': true,
      'raw_text': rawText,
      if (rawResponse != null && rawResponse.isNotEmpty)
        'raw_response': rawResponse,
      'title': rawText.trim(),
      'date': null,
      'start_at': inferredStartAt?.toIso8601String(),
      'end_at': null,
      'location': null,
      'location_lat': null,
      'location_lng': null,
      'travel_origin_lat': null,
      'travel_origin_lng': null,
      'travel_mode': null,
      'recurrence_rule': _normalizeRecurrenceFromRawText(rawText, null),
      'is_all_day': false,
      'is_multi_day': false,
      'category': _inferCategoryFromRawText(rawText),
      'memo': null,
      'supplies': <String>[],
      'is_critical': false,
      'pre_actions': const SmartPreparationAlarmService().enrichParsedSchedule(
        <String, dynamic>{
          'title': rawText.trim(),
          'start_at': inferredStartAt?.toIso8601String(),
          'supplies': <String>[],
          'pre_actions': <Map<String, dynamic>>[],
        },
        rawText: rawText,
      ),
    };
    _normalizeEventTypeFromRawText(rawText, fallback);
    return fallback;
  }

  List<String> _normalizeSupplies(Object? supplies) {
    if (supplies is List) {
      return supplies
          .whereType<String>()
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }

    if (supplies is String) {
      return supplies
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }

    return <String>[];
  }

  List<Map<String, dynamic>> _normalizePreActions(Object? preActions) {
    if (preActions is! List) {
      return <Map<String, dynamic>>[];
    }

    return preActions
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) => item['title'] != null && item['offset_hours'] != null)
        .toList(growable: false);
  }

  DateTime? _parseDateTime(Object? value) {
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

  DateTime? _inferStartAtFromRawText(String rawText) {
    final normalized = _normalizeKoreanText(rawText);
    if (normalized.isEmpty) {
      return null;
    }

    final now = _now();
    final relative = _extractRelativeOffsetFromText(normalized, now);
    if (relative != null) {
      return relative;
    }

    final date = _extractDateFromText(normalized, now);
    final time = _extractTimeFromText(normalized);

    if (date == null && time == null) {
      return null;
    }

    final baseDate = date ?? DateTime(now.year, now.month, now.day);
    final clock = time ?? const _ClockTime(hour: 9, minute: 0);
    var candidate = DateTime(
      baseDate.year,
      baseDate.month,
      baseDate.day,
      clock.hour,
      clock.minute,
    );

    if (date == null && time != null && candidate.isBefore(now)) {
      candidate = candidate.add(const Duration(days: 1));
    }

    return candidate;
  }

  bool _shouldPreferInferredStartAt({
    required String rawText,
    required DateTime? parsedStartAt,
    required DateTime inferredStartAt,
  }) {
    if (parsedStartAt == null) {
      return true;
    }
    if (!_hasExplicitKoreanTimeExpression(rawText)) {
      return false;
    }
    return parsedStartAt.difference(inferredStartAt).abs() >
        const Duration(minutes: 1);
  }

  void _normalizeEventTypeFromRawText(
    String rawText,
    Map<String, dynamic> normalized,
  ) {
    final text = _normalizeKoreanText(rawText);
    if (RegExp(r'(부터|에서).{0,24}(까지|동안)').hasMatch(text) ||
        RegExp(r'\d{1,2}월\s*\d{1,2}일\s*[-~]\s*\d{1,2}월?\s*\d{1,2}일')
            .hasMatch(text)) {
      normalized['is_multi_day'] = true;
      normalized['is_all_day'] = false;
      return;
    }

    final explicitTime = _extractTimeFromText(text) != null ||
        RegExp(r'\d{1,3}\s*(분|시간)\s*(뒤|후|있다가|이따)').hasMatch(text);
    if (!explicitTime &&
        RegExp(r'(종일|하루\s*종일|하루종일|온종일|휴가|연차|기념일|생일)').hasMatch(text)) {
      normalized['is_all_day'] = true;
      normalized['is_multi_day'] = false;
    }
  }

  String _normalizeCategoryFromRawText(String rawText, Object? parsedCategory) {
    final normalized = PlanFlowEventCategories.normalize(parsedCategory);
    if (normalized != PlanFlowEventCategories.etc) {
      return normalized;
    }
    return _inferCategoryFromRawText(rawText);
  }

  String _inferCategoryFromRawText(String rawText) {
    final text = _normalizeKoreanText(rawText);
    if (RegExp(r'(병원|의원|치과|한의원|검진|건강검진|운동|헬스|시술|진료|치료|처방|내시경|약\s*받)')
        .hasMatch(text)) {
      return PlanFlowEventCategories.health;
    }
    if (RegExp(r'(강의|세미나|워크샵|워크숍|교육|연수|수업|강좌|학원|학교|시험|스터디)').hasMatch(text)) {
      return PlanFlowEventCategories.education;
    }
    if (RegExp(r'(미팅|회의|보고|출장|거래처|영업|업무|면접|발표|제안|컨퍼런스)').hasMatch(text)) {
      return PlanFlowEventCategories.work;
    }
    if (RegExp(r'(약속|취미|여가|친구|가족\s*모임|모임|데이트|여행|휴가|식사)').hasMatch(text)) {
      return PlanFlowEventCategories.personal;
    }
    return PlanFlowEventCategories.etc;
  }

  String? _normalizeRecurrenceFromRawText(String rawText, Object? parsedRule) {
    final existing = parsedRule?.toString().trim();
    if (existing != null && existing.isNotEmpty && existing != 'null') {
      return existing;
    }
    final text = _normalizeKoreanText(rawText);
    final weekday = _weekdayRRuleToken(text);

    if (text.contains('격주')) {
      return 'FREQ=WEEKLY;INTERVAL=2${weekday == null ? '' : ';BYDAY=$weekday'}';
    }
    if (text.contains('매주')) {
      return 'FREQ=WEEKLY${weekday == null ? '' : ';BYDAY=$weekday'}';
    }
    final monthlyOrdinal = RegExp(
            r'매월\s*(첫\s*번째|첫째|두\s*번째|둘째|세\s*번째|셋째|네\s*번째|넷째|마지막)\s*([월화수목금토일])요일')
        .firstMatch(text);
    if (monthlyOrdinal != null) {
      final ordinal = switch (monthlyOrdinal.group(1)?.replaceAll(' ', '')) {
        '첫번째' || '첫째' => '1',
        '두번째' || '둘째' => '2',
        '세번째' || '셋째' => '3',
        '네번째' || '넷째' => '4',
        '마지막' => '-1',
        _ => '1',
      };
      final day = _weekdayShortToken(monthlyOrdinal.group(2));
      if (day != null) {
        return 'FREQ=MONTHLY;BYDAY=$ordinal$day';
      }
    }
    final monthlyDay = RegExp(r'매월\s*(\d{1,2})일').firstMatch(text);
    if (monthlyDay != null) {
      return 'FREQ=MONTHLY;BYMONTHDAY=${monthlyDay.group(1)}';
    }
    final yearly = RegExp(r'매년\s*(\d{1,2})월\s*(\d{1,2})일').firstMatch(text);
    if (yearly != null) {
      return 'FREQ=YEARLY;BYMONTH=${yearly.group(1)};BYMONTHDAY=${yearly.group(2)}';
    }
    final custom = RegExp(r'(\d{1,2})\s*(일|주|개월|달|월|년)\s*마다').firstMatch(text);
    if (custom != null) {
      final interval = custom.group(1);
      final unit = custom.group(2);
      final freq = switch (unit) {
        '일' => 'DAILY',
        '주' => 'WEEKLY',
        '개월' || '달' || '월' => 'MONTHLY',
        '년' => 'YEARLY',
        _ => null,
      };
      if (freq != null) {
        return 'FREQ=$freq;INTERVAL=$interval';
      }
    }
    return null;
  }

  String? _weekdayRRuleToken(String text) {
    final tokens = <String>[];
    const days = <String, String>{
      '월': 'MO',
      '화': 'TU',
      '수': 'WE',
      '목': 'TH',
      '금': 'FR',
      '토': 'SA',
      '일': 'SU',
    };
    for (final entry in days.entries) {
      if (text.contains('${entry.key}요일')) {
        tokens.add(entry.value);
      }
    }
    final compact =
        RegExp(r'(?:매주|격주)\s*([월화수목금토일,\s·]+)').firstMatch(text)?.group(1);
    if (compact != null) {
      for (final entry in days.entries) {
        if (compact.contains(entry.key)) {
          tokens.add(entry.value);
        }
      }
    }
    if (RegExp(r'(^|[\s,·])일($|[\s,·])').hasMatch(text)) {
      tokens.add('SU');
    }
    return tokens.isEmpty ? null : tokens.toSet().join(',');
  }

  String? _weekdayShortToken(String? text) {
    return switch (text) {
      '월' => 'MO',
      '화' => 'TU',
      '수' => 'WE',
      '목' => 'TH',
      '금' => 'FR',
      '토' => 'SA',
      '일' => 'SU',
      _ => null,
    };
  }

  bool _hasExplicitKoreanTimeExpression(String rawText) {
    final text = _normalizeKoreanText(rawText);
    return RegExp(r'\d{1,2}\s*분\s*(뒤|후|있다가|이따)').hasMatch(text) ||
        RegExp(r'\d{1,2}\s*시간(?:\s*\d{1,2}\s*분)?\s*(뒤|후|있다가|이따)')
            .hasMatch(text) ||
        RegExp(r'(오늘|내일|모레|글피)').hasMatch(text) ||
        RegExp(r'(?:(?:\d{4})년\s*)?\d{1,2}월\s*\d{1,2}일').hasMatch(text) ||
        RegExp(r'(?:(오전|오후)\s*)?\d{1,2}\s*시').hasMatch(text);
  }

  DateTime? _extractRelativeOffsetFromText(String text, DateTime now) {
    final hourMinuteMatch = RegExp(
      r'(?:(?<hours>\d{1,2})\s*시간)\s*(?:(?<minutes>\d{1,2})\s*분)?\s*(뒤|후|있다가|이따)',
    ).firstMatch(text);
    if (hourMinuteMatch != null) {
      final hours = int.tryParse(hourMinuteMatch.namedGroup('hours') ?? '');
      final minutes =
          int.tryParse(hourMinuteMatch.namedGroup('minutes') ?? '') ?? 0;
      if (hours != null && hours >= 0 && minutes >= 0 && minutes < 60) {
        return now.add(Duration(hours: hours, minutes: minutes));
      }
    }

    final minuteMatch = RegExp(
      r'(?<minutes>\d{1,3})\s*분\s*(뒤|후|있다가|이따)',
    ).firstMatch(text);
    if (minuteMatch != null) {
      final minutes = int.tryParse(minuteMatch.namedGroup('minutes') ?? '');
      if (minutes != null && minutes >= 0) {
        return now.add(Duration(minutes: minutes));
      }
    }

    return null;
  }

  DateTime? _extractDateFromText(String text, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);

    if (text.contains('내일')) {
      return today.add(const Duration(days: 1));
    }
    if (text.contains('모레')) {
      return today.add(const Duration(days: 2));
    }
    if (text.contains('글피')) {
      return today.add(const Duration(days: 3));
    }
    if (text.contains('오늘')) {
      return today;
    }

    final explicitDate = RegExp(
      r'(?:(?<year>\d{4})년\s*)?(?<month>\d{1,2})월\s*(?<day>\d{1,2})일',
    ).firstMatch(text);
    if (explicitDate != null) {
      final yearText = explicitDate.namedGroup('year');
      final monthText = explicitDate.namedGroup('month');
      final dayText = explicitDate.namedGroup('day');
      final month = int.tryParse(monthText ?? '');
      final day = int.tryParse(dayText ?? '');
      if (month != null && day != null) {
        final year = int.tryParse(yearText ?? '') ?? now.year;
        var candidate = DateTime(year, month, day);
        if (yearText == null &&
            candidate.isBefore(today) &&
            candidate.year == now.year) {
          candidate = DateTime(year + 1, month, day);
        }
        return candidate;
      }
    }

    final weekDay = _extractWeekdayOffset(text);
    if (weekDay != null) {
      return weekDay;
    }

    return null;
  }

  DateTime? _extractWeekdayOffset(String text) {
    const weekdays = <String, int>{
      '일요일': DateTime.sunday,
      '월요일': DateTime.monday,
      '화요일': DateTime.tuesday,
      '수요일': DateTime.wednesday,
      '목요일': DateTime.thursday,
      '금요일': DateTime.friday,
      '토요일': DateTime.saturday,
    };

    final now = _now();
    for (final entry in weekdays.entries) {
      if (!text.contains(entry.key)) {
        continue;
      }
      final currentWeekday = now.weekday;
      final targetWeekday = entry.value;
      var delta = targetWeekday - currentWeekday;
      if (delta <= 0) {
        delta += 7;
      }
      return DateTime(now.year, now.month, now.day).add(Duration(days: delta));
    }

    return null;
  }

  _ClockTime? _extractTimeFromText(String text) {
    final match = RegExp(
      r'(?:(오전|오후)\s*)?(\d{1,2})\s*시(?:\s*(\d{1,2})\s*분)?',
    ).firstMatch(text);
    if (match == null) {
      return null;
    }

    final period = match.group(1);
    var hour = int.tryParse(match.group(2) ?? '');
    final minute = int.tryParse(match.group(3) ?? '') ?? 0;
    if (hour == null || minute < 0 || minute > 59) {
      return null;
    }
    if (hour < 0 || hour > 23) {
      return null;
    }

    if (period == '오후' && hour < 12) {
      hour += 12;
    } else if (period == '오전' && hour == 12) {
      hour = 0;
    }

    return _ClockTime(hour: hour, minute: minute);
  }

  String _normalizeKoreanText(String text) {
    return text
        .replaceAll(RegExp(r'[,\.\!\?\(\)\[\]\{\}]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

class _ClockTime {
  const _ClockTime({
    required this.hour,
    required this.minute,
  });

  final int hour;
  final int minute;
}

const String _scheduleSystemPrompt = '''
You are a Korean schedule parser.
Return only a valid JSON object.
Use these keys:
title, date, start_at, end_at, location, location_lat, location_lng, travel_origin_lat, travel_origin_lng, travel_mode, memo, supplies, is_critical, recurrence_rule, is_all_day, is_multi_day, category, pre_actions.
start_at and end_at must be ISO-8601 date-time strings when possible.
For Korean relative expressions such as "3분 뒤", "2시간 후", "내일 오전 10시", resolve them from the current local date and time.
If only a date is known, use 09:00 local time unless the user clearly implies all-day.
For recurring schedules, return recurrence_rule as an iCal RRULE such as "FREQ=WEEKLY;BYDAY=TU". Otherwise return null.
For all-day schedules, set is_all_day true. For multi-day schedules such as "5월 1일부터 3일까지", set is_multi_day true and return both start_at and end_at.
category must be one of "업무", "개인", "건강", "교육", "기타"; infer conservatively and default to "기타".
Category examples: "병원 진료" and "헬스장" -> "건강"; "세미나 참석" and "강의" -> "교육"; "JW제약 미팅" -> "업무"; "친구 약속" -> "개인".
supplies must be an array of strings.
is_critical must be a boolean.
pre_actions must be an array of objects with title and offset_hours.
Return pre_actions when the schedule clearly implies preparation, movement, supplies, medical checks, fasting, departure, documents, or reservation follow-up.
Use Korean user-facing pre_action titles. Examples: "준비물 챙기기", "이동시간과 출발 시간 확인", "금식/복약 안내 확인", "병원 준비사항 확인", "꽃이나 선물 챙기기".
Prefer practical offsets: 24 hours for medical/checkup preparation, 12 hours for fasting/medication checks, 2-3 hours for departure or supplies, 1 hour for simple final checks.
Do not infer medical or fasting pre_actions from place names alone.
Hospital, clinic, dental, court, and school names are locations unless the user's action/purpose is also clear.
For hospitals, distinguish medical care, work/meetings, visiting a patient, and unclear purpose. "병원", "병원 방문", "병원 미팅", and "병문안" must not produce medical or fasting pre_actions unless the text also says 진료, 검진, 검사, 수술, 채혈, 치료, 접종, 처방, 내시경, 금식, or another explicit medical action.
For "병문안" or "문병", add a visit-oriented pre_action such as "꽃이나 선물 챙기기" instead of medical or fasting preparation.
Fasting/medication pre_actions require explicit fasting-sensitive context such as 내시경, 금식, 마취, 수술, or a medical 검사/검진 context. Do not add them for a generic hospital location.
Few-shot guidance:
- Input: "내일 오전 10시 병원" -> pre_actions: []
- Input: "내일 오후 2시 병원 미팅" -> pre_actions may include movement if needed, but no "병원 준비사항 확인" and no "금식/복약 안내 확인".
- Input: "토요일 병원 병문안" -> include "꽃이나 선물 챙기기", but no medical or fasting pre_actions.
- Input: "월요일 오전 8시 병원 건강검진" -> include "병원 준비사항 확인" and "금식/복약 안내 확인".
- Input: "모레 오전 8시 위내시경 검사" -> include "병원 준비사항 확인" and "금식/복약 안내 확인".
- Input: "내일 법원" or "내일 학교" -> do not infer legal, school, medical, or fasting pre_actions from the place alone.
travel_mode must be "car", "transit", or null.
Only include latitude/longitude values when they are explicitly known from the input or prior context.
If a field is not known, use null or an empty array.
''';

const String _morningBriefingPrompt = '''
당신은 한국어 일정 브리핑 비서입니다.
오늘 일정을 시간순으로 간단히 요약하세요.
각 일정은 몇 시에 어떤 일정인지 말하고, 중요 일정은 중요하다고만 표시하세요.
일정 간격이 빠듯하면 빠르게 움직여야 한다는 짧은 코멘트만 덧붙이세요.
일정 내용에 대해 과도한 조언이나 해석을 하지 말고, 마크다운 없이 한국어로만 답하세요.
''';

const String _eveningBriefingPrompt = '''
당신은 한국어 일정 브리핑 비서입니다.
내일 일정을 시간순으로 간단히 요약하세요.
각 일정은 몇 시에 어떤 일정인지 말하고, 중요 일정은 중요하다고만 표시하세요.
일정 간격이 빠듯하면 빠르게 움직여야 한다는 짧은 코멘트만 덧붙이세요.
일정 내용에 대해 과도한 조언이나 해석을 하지 말고, 마크다운 없이 한국어로만 답하세요.
''';
