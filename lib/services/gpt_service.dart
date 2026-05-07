import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/env.dart';
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
    String? apiKey,
    DateTime Function()? now,
  })  : _client = client,
        _endpoint =
            endpoint ?? Uri.parse('https://api.openai.com/v1/chat/completions'),
        _apiKey = apiKey ?? AppEnv.openAiApiKey,
        _now = now ?? DateTime.now;

  final http.Client? _client;
  final Uri _endpoint;
  final String _apiKey;
  final DateTime Function() _now;

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
    if (_apiKey.isEmpty) {
      if (throwOnFailure) {
        throw const GptCompletionException(
          'missing_api_key',
          'OpenAI API 키가 설정되지 않았습니다.',
        );
      }
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
title, date, start_at, end_at, location, location_lat, location_lng, travel_origin_lat, travel_origin_lng, travel_mode, memo, supplies, is_critical, pre_actions.
start_at and end_at must be ISO-8601 date-time strings when possible.
For Korean relative expressions such as "3분 뒤", "2시간 후", "내일 오전 10시", resolve them from the current local date and time.
If only a date is known, use 09:00 local time unless the user clearly implies all-day.
supplies must be an array of strings.
is_critical must be a boolean.
pre_actions must be an array of objects with title and offset_hours.
Return pre_actions when the schedule clearly implies preparation, movement, supplies, medical checks, fasting, departure, documents, or reservation follow-up.
Use Korean user-facing pre_action titles. Examples: "준비물 챙기기", "이동시간과 출발 시간 확인", "금식/복약 안내 확인", "병원 준비사항 확인".
Prefer practical offsets: 24 hours for medical/checkup preparation, 12 hours for fasting/medication checks, 2-3 hours for departure or supplies, 1 hour for simple final checks.
Do not infer medical or fasting pre_actions from place names alone.
Hospital, clinic, dental, court, and school names are locations unless the user's action/purpose is also clear.
For hospitals, distinguish medical care, work/meetings, visiting a patient, and unclear purpose. "병원", "병원 방문", "병원 미팅", and "병문안" must not produce medical or fasting pre_actions unless the text also says 진료, 검진, 검사, 수술, 채혈, 치료, 접종, 처방, 내시경, 금식, or another explicit medical action.
Fasting/medication pre_actions require explicit fasting-sensitive context such as 내시경, 금식, 마취, 수술, or a medical 검사/검진 context. Do not add them for a generic hospital location.
Few-shot guidance:
- Input: "내일 오전 10시 병원" -> pre_actions: []
- Input: "내일 오후 2시 병원 미팅" -> pre_actions may include movement if needed, but no "병원 준비사항 확인" and no "금식/복약 안내 확인".
- Input: "토요일 병원 병문안" -> no medical or fasting pre_actions.
- Input: "월요일 오전 8시 병원 건강검진" -> include "병원 준비사항 확인" and "금식/복약 안내 확인".
- Input: "모레 오전 8시 위내시경 검사" -> include "병원 준비사항 확인" and "금식/복약 안내 확인".
- Input: "내일 법원" or "내일 학교" -> do not infer legal, school, medical, or fasting pre_actions from the place alone.
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
