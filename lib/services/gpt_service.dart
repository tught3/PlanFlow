import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/env.dart';
import 'smart_preparation_alarm_service.dart';

class GptService {
  GptService({
    http.Client? client,
    Uri? endpoint,
    String? apiKey,
  })  : _client = client,
        _endpoint =
            endpoint ?? Uri.parse('https://api.openai.com/v1/chat/completions'),
        _apiKey = apiKey ?? AppEnv.openAiApiKey;

  final http.Client? _client;
  final Uri _endpoint;
  final String _apiKey;

  static const String _model = 'gpt-4o-mini';
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
    );

    final briefing = content?.trim();
    if (briefing == null || briefing.isEmpty) {
      return isMorning ? '모닝 브리핑을 불러오지 못했습니다.' : '이브닝 브리핑을 불러오지 못했습니다.';
    }

    return briefing;
  }

  Future<String?> _requestCompletion({
    required String systemPrompt,
    required String userPrompt,
    Map<String, dynamic>? responseFormat,
  }) async {
    if (_apiKey.isEmpty) {
      return null;
    }

    final client = _client ?? http.Client();
    try {
      final response = await client.post(
        _endpoint,
        headers: <String, String>{
          'Authorization': 'Bearer $_apiKey',
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
        return null;
      }

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) {
        return null;
      }

      final firstChoice = choices.first;
      if (firstChoice is! Map<String, dynamic>) {
        return null;
      }

      final message = firstChoice['message'];
      if (message is! Map<String, dynamic>) {
        return null;
      }

      final content = message['content'];
      if (content is! String) {
        return null;
      }

      return content;
    } catch (_) {
      return null;
    } finally {
      if (_client == null) {
        client.close();
      }
    }
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
    normalized['supplies'] = _normalizeSupplies(normalized['supplies']);
    normalized['pre_actions'] = _normalizePreActions(normalized['pre_actions']);
    final inferredStartAt = _inferStartAtFromRawText(rawText);
    if (_parseDateTime(normalized['start_at']) == null &&
        inferredStartAt != null) {
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
    return <String, dynamic>{
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

    final now = DateTime.now();
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

    final now = DateTime.now();
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
title, date, start_at, end_at, location, location_lat, location_lng, travel_origin_lat, travel_origin_lng, travel_mode, memo, supplies, is_critical, pre_actions.
start_at and end_at must be ISO-8601 date-time strings when possible.
If only a date is known, use 09:00 local time unless the user clearly implies all-day.
supplies must be an array of strings.
is_critical must be a boolean.
pre_actions must be an array of objects with title and offset_hours.
Return pre_actions aggressively when the schedule implies preparation, movement, supplies, medical checks, fasting, departure, documents, or reservation follow-up.
Use Korean user-facing pre_action titles. Examples: "준비물 챙기기", "이동시간과 출발 시간 확인", "금식/복약 안내 확인", "병원 준비사항 확인".
Prefer practical offsets: 24 hours for medical/checkup preparation, 12 hours for fasting/medication checks, 2-3 hours for departure or supplies, 1 hour for simple final checks.
travel_mode must be "car", "transit", or null.
Only include latitude/longitude values when they are explicitly known from the input or prior context.
If a field is not known, use null or an empty array.
''';

const String _morningBriefingPrompt = '''
당신은 시간의 주권자를 보좌하는 권위 있고 전문적인 비서입니다.
성공적인 하루를 설계하기 위한 핵심 통찰을 2-4문장으로 브리핑하세요.
긴급한 일정과 준비가 필요한 항목을 먼저 요약하고, 마크다운 없이 한국어로만 답하세요.
''';

const String _eveningBriefingPrompt = '''
당신은 오늘의 성취를 분석하고 내일의 승리를 예견하는 통찰력 있는 리포터입니다.
오늘의 데이터 흐름을 요약하고 내일을 위한 전략적 제언을 2-4문장으로 브리핑하세요.
차분하고 권위 있는 어조를 유지하고, 마크다운 없이 한국어로만 답하세요.
''';
