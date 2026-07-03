import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../core/event_metadata.dart';
import '../core/local_time.dart';
import '../core/region_settings.dart';
import '../data/models/voice_correction_rule.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/voice_correction_rule_repository.dart';
import 'api_usage_guard.dart';
import 'remote_config_service.dart';
import 'voice_correction_learning_service.dart';
import 'voice_schedule_structure_service.dart';
import 'voice_text_cleanup_service.dart';

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
    Duration? completionTimeout,
    VoiceCorrectionRuleRepository? voiceCorrectionRuleRepository,
    VoiceCorrectionLearningService? voiceCorrectionLearningService,
    ApiUsageGuard? usageGuard,
  })  : _client = client,
        _endpoint = endpoint ??
            Uri.parse('${AppEnv.supabaseUrl}/functions/v1/openai-proxy'),
        _now = now ?? planflowNow,
        _completionTimeout = completionTimeout ?? const Duration(seconds: 20),
        _voiceCorrectionRuleRepository = voiceCorrectionRuleRepository,
        _voiceCorrectionLearningService = voiceCorrectionLearningService ??
            const VoiceCorrectionLearningService(),
        _usageGuard = usageGuard;

  final http.Client? _client;
  final Uri _endpoint;
  final DateTime Function() _now;
  final Duration _completionTimeout;
  final VoiceCorrectionRuleRepository? _voiceCorrectionRuleRepository;
  final VoiceCorrectionLearningService _voiceCorrectionLearningService;
  final ApiUsageGuard? _usageGuard;
  static const VoiceScheduleStructureService _voiceScheduleStructureService =
      VoiceScheduleStructureService();

  static String get _model => RemoteConfigService.gptModel;
  static const Map<String, dynamic> _responseFormat = <String, dynamic>{
    'type': 'json_object',
  };

  ApiUsageGuard get _guard => _usageGuard ?? ApiUsageGuard.instance;

  Future<Map<String, dynamic>> parseSchedule(String rawText) async {
    final content = await _requestCompletion(
      systemPrompt: _scheduleSystemPromptForRegion(),
      userPrompt: rawText,
      responseFormat: _responseFormat,
    );

    final parsed = _decodeJsonMap(content);
    if (parsed == null) {
      return _applyCorrectionRulesToParsedSchedule(
        _fallbackSchedule(
          rawText: rawText,
          rawResponse: content,
        ),
      );
    }

    final normalized = _normalizeSchedule(parsed, rawText);

    // 동기 정규화 이후 location 값이 있으면 GPT로 재검증.
    // 700ms 타임아웃 내에 "null" 반환 시 location을 비운다.
    // 타임아웃/예외 발생 시 로컬 판정 결과를 그대로 유지.
    final rawLocation = normalized['location']?.toString();
    if (rawLocation != null && rawLocation.isNotEmpty) {
      try {
        final validated = await validateLocation(rawLocation).timeout(
          const Duration(milliseconds: 700),
          onTimeout: () => rawLocation, // 타임아웃 시 원래 후보 유지
        );
        if (validated == null) {
          normalized['location'] = null;
        }
      } catch (_) {
        // 예외 시 기존 location 그대로 유지
      }
    }

    return _applyCorrectionRulesToParsedSchedule(normalized);
  }

  Future<Map<String, dynamic>> _applyCorrectionRulesToParsedSchedule(
    Map<String, dynamic> parsed,
  ) async {
    if (!AppEnv.isSupabaseReady) {
      return parsed;
    }
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null || userId.trim().isEmpty) {
        return parsed;
      }
      final settings =
          await SettingsRepository.supabase().fetchSettings(userId);
      if (settings?.voiceCorrectionLearningEnabled == false) {
        return parsed;
      }
      final repository = _voiceCorrectionRuleRepository ??
          VoiceCorrectionRuleRepository.supabase();
      final rules = <VoiceCorrectionRule>[
        ...await repository.fetchPersonalRules(userId),
        if (settings?.voiceCommonLearningOptIn == true)
          ...await repository.fetchTrustedCommonRules(),
      ];
      if (rules.isEmpty) {
        return parsed;
      }
      return _voiceCorrectionLearningService.applyParsedScheduleRules(
        parsed,
        rules: rules,
      );
    } catch (error, stackTrace) {
      debugPrint('GptService correction apply skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
      return parsed;
    }
  }

  Future<VoiceTextCleanupResult> cleanupVoiceText(
    String rawText, {
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
    Iterable<VoiceTextCleanupCandidate> candidates = const [],
  }) async {
    final local = VoiceTextCleanupService.cleanLocally(
      rawText,
      context: context,
      candidates: candidates,
    );
    if (!VoiceTextCleanupService.shouldAskAi(local.cleanedText)) {
      return local;
    }

    final candidateLines = candidates.take(12).map((candidate) {
      final startAt = candidate.startAt?.toIso8601String() ?? '시간 미정';
      final location = candidate.location?.trim();
      return '- 제목: ${candidate.title}, 장소: ${location == null || location.isEmpty ? '없음' : location}, 시작: $startAt';
    }).join('\n');

    final content = await _requestCompletion(
      systemPrompt: _voiceTextCleanupPrompt,
      userPrompt: jsonEncode(<String, dynamic>{
        'context': context.name,
        'text': local.cleanedText,
        if (candidateLines.isNotEmpty) 'candidate_events': candidateLines,
      }),
      responseFormat: _responseFormat,
    );
    final decoded = _decodeJsonMap(content);
    if (decoded == null) {
      return local;
    }

    final cleanedText = VoiceTextCleanupService.normalizeBasic(
        decoded['cleaned_text']?.toString() ?? '');
    final changed = decoded['changed'] == true;
    final confidence = _doubleValue(decoded['confidence']) ?? 0;
    if (!changed ||
        confidence < 0.65 ||
        cleanedText.isEmpty ||
        cleanedText == local.cleanedText) {
      return local;
    }

    return VoiceTextCleanupResult(
      originalText: rawText.trim(),
      cleanedText: cleanedText,
      changed: true,
      method: VoiceTextCleanupMethod.ai,
      reason: decoded['reason']?.toString().trim().isEmpty == false
          ? decoded['reason'].toString().trim()
          : 'ai_cleanup',
      confidence: confidence,
    );
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

  /// 텍스트가 실제 장소명(건물명·지역명·주소)인지 GPT로 검증.
  /// 장소명이면 정제된 장소명 반환, 아니면 null.
  Future<String?> validateLocation(String candidate) async {
    if (candidate.trim().isEmpty) return null;
    const systemPrompt = 'You are a location name validator for Korean text. '
        'If the input is a real place name (building, landmark, address, region, or business name), '
        'return ONLY the clean place name without any explanation. '
        'If the input is NOT a place name (e.g. a sentence, a task description, or random text), '
        'return exactly the word: null';
    final content = await _requestCompletion(
      systemPrompt: systemPrompt,
      userPrompt: candidate.trim(),
      // 단답 분류이므로 경량 모델 고정, 토큰 최소화
      model: 'gpt-4o-mini',
      maxTokens: 20,
    );
    final response = content?.trim();
    if (response == null || response.isEmpty || response == 'null') return null;
    return response;
  }

  Future<String?> _requestCompletion({
    required String systemPrompt,
    required String userPrompt,
    Map<String, dynamic>? responseFormat,
    bool throwOnFailure = false,
    // 특정 호출(validateLocation 등)에서 모델·토큰 수 재정의 가능.
    // null이면 기존 _model / 제한 없음 동작 그대로 유지.
    String? model,
    int? maxTokens,
  }) async {
    final client = _client ?? http.Client();
    try {
      // GPT API 호출빈도 가드 확인 (20회/분 한도)
      if (!await _guard.tryConsume(ApiName.gpt)) {
        debugPrint('ApiUsageGuard: gpt blocked — rate limit exceeded');
        return null;
      }

      final response = await client
          .post(
            _endpoint,
            headers: <String, String>{
              'Authorization': 'Bearer ${AppEnv.supabaseAnonKey}',
              'apikey': AppEnv.supabaseAnonKey,
              'Content-Type': 'application/json',
            },
            body: jsonEncode(<String, dynamic>{
              'model': model ?? _model,
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
              if (maxTokens != null) 'max_tokens': maxTokens,
            }),
          )
          .timeout(_completionTimeout);

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
    } on TimeoutException catch (error) {
      if (throwOnFailure) {
        throw GptCompletionException(
          'timeout',
          'OpenAI 요청 시간이 초과되었습니다.',
          cause: error,
        );
      }
      return null;
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

  double? _doubleValue(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
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
    } catch (e) {
      debugPrint('GptService JSON 파싱 실패 무시: $e');
    }

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
    } catch (e) {
      debugPrint('GptService JSON 파싱 실패 무시: $e');
    }

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
    _normalizeTitleMemoAndLocation(normalized, rawText);
    normalized['recurrence_rule'] =
        _normalizeRecurrenceFromRawText(rawText, normalized['recurrence_rule']);
    _normalizeEventTypeFromRawText(rawText, normalized);
    normalized['supplies'] = _normalizeSupplies(normalized['supplies']);
    normalized['pre_actions'] = _normalizePreActions(normalized['pre_actions']);
    final inferredStartAt = _inferStartAtFromRawText(rawText);
    if (_hasAmbiguousMeridiemTime(rawText)) {
      normalized['time_period_ambiguous'] = true;
    }
    if (inferredStartAt != null &&
        _shouldPreferInferredStartAt(
          rawText: rawText,
          parsedStartAt: _parseDateTime(normalized['start_at']),
          inferredStartAt: inferredStartAt,
        )) {
      normalized['start_at'] = inferredStartAt.toIso8601String();
    }
    _applyLocalDateRange(rawText, normalized);
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
      if (_hasAmbiguousMeridiemTime(rawText)) 'time_period_ambiguous': true,
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
      'participants': <String>[],
      'targets': <String>[],
      'is_critical': false,
      'pre_actions': <Map<String, dynamic>>[],
    };
    _normalizeTitleMemoAndLocation(fallback, rawText);
    _normalizeEventTypeFromRawText(rawText, fallback);
    _applyLocalDateRange(rawText, fallback);
    return fallback;
  }

  void _normalizeTitleMemoAndLocation(
    Map<String, dynamic> schedule,
    String rawText,
  ) {
    final normalizedRawText =
        _voiceScheduleStructureService.stripDateRangeExpression(
      _stripExplicitMemoClause(rawText),
      now: _now(),
    );
    final contentClause = _extractContentClause(normalizedRawText);
    final structured = _voiceScheduleStructureService
        .analyze(contentClause ?? normalizedRawText);
    final rawTitle = schedule['title']?.toString();
    final normalizedTitle = _normalizeScheduleTitle(
      rawTitle,
      contentClause ?? normalizedRawText,
      structured: structured,
    );
    schedule['title'] = normalizedTitle;
    final peopleFields = _voiceScheduleStructureService.extractPeopleFields(
      contentClause ?? normalizedRawText,
    );
    schedule['participants'] = _mergeStringLists(
      schedule['participants'],
      peopleFields.participants,
    );
    schedule['targets'] = _mergeStringLists(
      schedule['targets'],
      peopleFields.targets,
    );

    final normalizedLocation = _normalizeScheduleLocation(
      schedule['location']?.toString(),
      structured.contentText.isEmpty
          ? contentClause ?? normalizedRawText
          : structured.contentText,
      normalizedTitle,
    );
    schedule['location'] = normalizedLocation;
    if (normalizedLocation != null && normalizedTitle.isNotEmpty) {
      final compactLocation = normalizedLocation.replaceAll(RegExp(r'\s+'), '');
      if (normalizedTitle == '출발' || normalizedTitle == '도착') {
        schedule['title'] = '$normalizedLocation ${normalizedTitle.trim()}';
      } else if (normalizedTitle == compactLocation) {
        schedule['title'] = '$normalizedLocation 출발';
      }
    }

    final memo = schedule['memo']?.toString();
    schedule['memo'] = _normalizeScheduleMemo(memo, rawText);
    _preserveDeliveryContent(
      schedule,
      structured.contentText.isEmpty
          ? contentClause ?? normalizedRawText
          : structured.contentText,
    );
  }

  String _normalizeScheduleTitle(
    String? title,
    String rawText, {
    VoiceScheduleStructure? structured,
  }) {
    return _voiceScheduleStructureService.normalizeParsedScheduleTitle(
      title,
      rawText: rawText,
      structured: structured,
    );
  }

  String? _normalizeScheduleLocation(
    String? location,
    String rawText,
    String title,
  ) {
    return _voiceScheduleStructureService.normalizeScheduleLocation(
      location: location,
      rawText: rawText,
      title: title,
    );
  }

  String? _normalizeScheduleMemo(String? memo, String rawText) {
    return _voiceScheduleStructureService.extractExplicitMemo(rawText);
  }

  List<String> _mergeStringLists(Object? existing, List<String> inferred) {
    final values = <String>[];
    void add(String value) {
      final normalized = value.trim();
      if (normalized.isNotEmpty && !values.contains(normalized)) {
        values.add(normalized);
      }
    }

    if (existing is Iterable) {
      for (final item in existing) {
        add(item.toString());
      }
    } else if (existing != null) {
      add(existing.toString());
    }
    for (final value in inferred) {
      add(value);
    }
    return values;
  }

  String? _extractContentClause(String rawText) {
    final source = _normalizeKoreanText(rawText);
    final match = RegExp(
      r'(?:내용은|내용\s*[:：]|할\s*일은|일정\s*내용은)\s*(.+)$',
    ).firstMatch(source);
    final content = match?.group(1)?.trim();
    if (content == null || content.isEmpty) {
      return null;
    }
    return content.replaceFirst(RegExp(r'^[.。,\s]+'), '').trim();
  }

  String _stripExplicitMemoClause(String text) {
    return _voiceScheduleStructureService.stripExplicitMemoClause(text);
  }

  String _stripRelativeDayWordsIfContent(String text) {
    return _voiceScheduleStructureService
        .stripRelativeDayWordsForTimeText(text);
  }

  void _preserveDeliveryContent(
    Map<String, dynamic> schedule,
    String contentText,
  ) {
    return _voiceScheduleStructureService.preserveDeliveryContent(
      schedule,
      contentText,
    );
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
    final localRange = _voiceScheduleStructureService.extractDateRange(
      normalized,
      now: now,
    );
    if (localRange != null) {
      if (localRange.isAllDay &&
          !localRange.isMultiDay &&
          !_hasExplicitTimeCue(normalized)) {
        return DateTime(
          localRange.startAt.year,
          localRange.startAt.month,
          localRange.startAt.day,
          9,
        );
      }
      return localRange.startAt;
    }

    final dateTimeText = _stripRelativeDayWordsIfContent(normalized);
    final relative = _extractRelativeOffsetFromText(dateTimeText, now);
    if (relative != null) {
      return relative;
    }

    final recurringDate =
        _extractMonthlyRecurringDateFromText(dateTimeText, now);
    final date = recurringDate ?? _extractDateFromText(dateTimeText, now);
    final time = _normalizeAmbiguousLeadingTime(
      dateTimeText,
      _extractTimeFromText(dateTimeText),
    );

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
      // 오전/오후를 말하지 않은 애매한 시각(7~12시)이 이미 지났으면, 무조건
      // 다음날 같은 시각(오전 해석)으로 미루지 않는다. "지금 오후 7:55에
      // '8시'라고 하면" 다음날 오전 8시(약 12시간 뒤)보다 오늘 오후 8시
      // (약 5분 뒤)가 훨씬 자연스럽다 — 오전 8시를 의도했다면 "내일 8시"처럼
      // 날짜를 같이 말했을 것이기 때문. 두 후보 중 지금(now) 이후로
      // 가장 가까운 쪽을 고른다. 두 후보 다 이미 지났을 때만(예: 자정 직전)
      // 기존처럼 다음날로 넘긴다.
      if (_hasAmbiguousMeridiemTime(dateTimeText)) {
        final pmCandidate = candidate.add(const Duration(hours: 12));
        candidate = pmCandidate.isBefore(now)
            ? candidate.add(const Duration(days: 1))
            : pmCandidate;
      } else {
        candidate = candidate.add(const Duration(days: 1));
      }
    }

    return candidate;
  }

  bool _hasExplicitTimeCue(String text) {
    return _extractTimeFromText(text) != null ||
        RegExp(r'\d{1,3}\s*(분|시간)\s*(뒤|후|있다가|이따)').hasMatch(text);
  }

  DateTime? _extractMonthlyRecurringDateFromText(String text, DateTime now) {
    final monthlyOrdinal = RegExp(
      r'매월\s*(첫\s*번째|첫째|두\s*번째|둘째|세\s*번째|셋째|네\s*번째|넷째|마지막)\s*([월화수목금토일])요일',
    ).firstMatch(text);
    if (monthlyOrdinal != null) {
      final orderToken = monthlyOrdinal.group(1)?.replaceAll(' ', '') ?? '';
      final weekdayToken = monthlyOrdinal.group(2);
      final order = switch (orderToken) {
        '첫번째' || '첫째' => 1,
        '두번째' || '둘째' => 2,
        '세번째' || '셋째' => 3,
        '네번째' || '넷째' => 4,
        '마지막' => -1,
        _ => 1,
      };
      final weekday = _weekdayShortToken(weekdayToken);
      if (weekday != null) {
        return _monthlyWeekdayDate(now, weekday: weekday, order: order);
      }
    }

    final monthlyDay = RegExp(r'매월\s*(\d{1,2})일').firstMatch(text);
    if (monthlyDay != null) {
      final day = int.tryParse(monthlyDay.group(1) ?? '');
      if (day == null || day < 1) {
        return null;
      }

      final lastDayOfMonth = DateTime(now.year, now.month + 1, 0).day;
      final clampedDay = day > lastDayOfMonth ? lastDayOfMonth : day;
      return DateTime(now.year, now.month, clampedDay);
    }
    return null;
  }

  DateTime? _monthlyWeekdayDate(
    DateTime now, {
    required String weekday,
    required int order,
  }) {
    final targetWeekday = switch (weekday) {
      'MO' => DateTime.monday,
      'TU' => DateTime.tuesday,
      'WE' => DateTime.wednesday,
      'TH' => DateTime.thursday,
      'FR' => DateTime.friday,
      'SA' => DateTime.saturday,
      'SU' => DateTime.sunday,
      _ => null,
    };
    if (targetWeekday == null) {
      return null;
    }

    final firstDayOfMonth = DateTime(now.year, now.month, 1);
    final nextMonthStart = DateTime(now.year, now.month + 1, 1);
    if (order == -1) {
      var cursor = nextMonthStart.subtract(const Duration(days: 1));
      while (cursor.month == now.month && cursor.weekday != targetWeekday) {
        cursor = cursor.subtract(const Duration(days: 1));
      }
      return cursor.month == now.month ? cursor : null;
    }

    var cursor = firstDayOfMonth;
    while (cursor.weekday != targetWeekday) {
      cursor = cursor.add(const Duration(days: 1));
    }
    cursor = cursor.add(Duration(days: 7 * (order - 1)));
    return cursor.month == now.month ? cursor : null;
  }

  _ClockTime? _normalizeAmbiguousLeadingTime(
    String text,
    _ClockTime? clock,
  ) {
    if (clock == null) {
      return null;
    }

    final hasExplicitPeriod = RegExp(
          r'(?:(오전|오후|아침|낮|점심|저녁|밤|새벽)\s*)?\d{1,2}\s*시',
        ).firstMatch(text)?.group(1) !=
        null;
    if (hasExplicitPeriod) {
      return clock;
    }

    if (!RegExp(r'^(?:\s*(?:오늘|내일|모레|글피))\s*\d{1,2}\s*시').hasMatch(text)) {
      return clock;
    }

    if (clock.hour < 1 || clock.hour > 6) {
      return clock;
    }

    return _clockTimeFromParts(
      period: '오후',
      hour: clock.hour,
      minute: clock.minute,
    );
  }

  String _scheduleSystemPromptForRegion() {
    final region = PlanFlowRegionController.instance.region;
    final now = _now();
    final todayDate = DateTime(now.year, now.month, now.day);
    final weekStart = todayDate.subtract(Duration(days: now.weekday - 1));
    final weekEnd = weekStart.add(const Duration(days: 6));
    final nextWeekStart = weekStart.add(const Duration(days: 7));
    final nextWeekEnd = nextWeekStart.add(const Duration(days: 6));
    String ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    const weekdayNames = ['월', '화', '수', '목', '금', '토', '일'];
    final todayName = weekdayNames[now.weekday - 1];
    // 월 경계 예시: 오늘 기준 "다음주 금요일"의 실제 날짜를 직접 계산해 GPT에 제시
    final nextWeekFriday = nextWeekStart.add(const Duration(days: 4));
    return '''
Current user region: ${region.countryName} (${region.countryCode}).
Current locale: ${region.localeCode}.
Current time zone: ${region.timeZoneId}.
Current local date-time: ${now.toIso8601String()}.
Today is ${ymd(todayDate)} ($todayName요일).
This week (이번주): ${ymd(weekStart)} (월) ~ ${ymd(weekEnd)} (일).
Next week (다음주): ${ymd(nextWeekStart)} (월) ~ ${ymd(nextWeekEnd)} (일).

Weekday resolution rules (IMPORTANT, follow exactly):
- "이번주 <요일>" = that weekday inside the This week range above.
- "다음주 <요일>" = that weekday inside the Next week range above.
- A month boundary does NOT reset the week. On ${ymd(todayDate)}, "다음주 금요일" is ${ymd(nextWeekFriday)}, even when it falls in the next month.
- A bare "<요일>" with no 이번주/다음주 means the nearest upcoming occurrence (today or later).

$_scheduleSystemPrompt
''';
  }

  bool _shouldPreferInferredStartAt({
    required String rawText,
    required DateTime? parsedStartAt,
    required DateTime inferredStartAt,
  }) {
    if (_hasRecurringDateHint(rawText)) {
      return true;
    }
    if (parsedStartAt == null) {
      return true;
    }
    if (_hasAmbiguousMeridiemTime(rawText)) {
      return false;
    }
    // "이번주/다음주 X요일"처럼 시간 표현이 없는 상대 요일 표현은 로컬 파서가
    // 결정적으로 정확하다. GPT는 주차 경계(특히 월을 넘는 다음주) 계산을 자주
    // 틀리므로, 이 경우 로컬 추론 날짜를 우선한다. (시간이 있는 표현은 기존
    // 동작을 유지해 시간 정보 손실을 막는다.)
    if (_hasRelativeWeekdayDateHint(rawText) &&
        !_hasExplicitKoreanTimeExpression(rawText) &&
        !_sameCalendarDay(parsedStartAt, inferredStartAt)) {
      return true;
    }
    if (!_hasExplicitKoreanTimeExpression(rawText)) {
      return false;
    }
    return parsedStartAt.difference(inferredStartAt).abs() >
        const Duration(minutes: 1);
  }

  bool _sameCalendarDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  bool _hasRelativeWeekdayDateHint(String rawText) {
    final text = _normalizeKoreanText(rawText);
    // 이번주/다음주 + 요일, 또는 이번주/다음주 단독 표현
    return RegExp(r'(이번|다음)\s*주').hasMatch(text);
  }

  bool _hasAmbiguousMeridiemTime(String rawText) {
    final clock = _extractAmbiguousMeridiemClock(rawText);
    return clock != null && clock.hour >= 7 && clock.hour <= 12;
  }

  _ClockTime? _extractAmbiguousMeridiemClock(String rawText) {
    final text = _normalizeKoreanText(rawText);
    final numericMatch = RegExp(
      r'(?:(오전|오후|아침|낮|점심|저녁|밤|새벽)\s*)?(\d{1,2})\s*시(?:\s*(\d{1,2})\s*분?|\s*(반))?',
    ).firstMatch(text);
    if (numericMatch != null) {
      if (numericMatch.group(1) != null) {
        return null;
      }
      final hasHalf = numericMatch.group(4) != null;
      return _clockTimeFromParts(
        period: null,
        hour: int.tryParse(numericMatch.group(2) ?? ''),
        minute: hasHalf
            ? 30
            : numericMatch.group(3) == null
                ? 0
                : int.tryParse(numericMatch.group(3)!),
      );
    }

    final koreanMatch = RegExp(
      r'(?:(오전|오후|아침|낮|점심|저녁|밤|새벽)\s*)?([가-힣]{1,8})\s*시(?:\s*([가-힣]{1,8}|\d{1,2})\s*분?|\s*(반))?',
    ).firstMatch(text);
    if (koreanMatch == null || koreanMatch.group(1) != null) {
      return null;
    }
    final minuteText = koreanMatch.group(3);
    final hasHalf = koreanMatch.group(4) != null || minuteText == '반';
    return _clockTimeFromParts(
      period: null,
      hour: _parseKoreanNumber(koreanMatch.group(2)),
      minute: hasHalf
          ? 30
          : minuteText == null
              ? 0
              : int.tryParse(minuteText) ?? _parseKoreanNumber(minuteText),
    );
  }

  bool _hasRecurringDateHint(String rawText) {
    final text = _normalizeKoreanText(rawText);
    return RegExp(r'매월\s*\d{1,2}\s*일').hasMatch(text);
  }

  void _normalizeEventTypeFromRawText(
    String rawText,
    Map<String, dynamic> normalized,
  ) {
    final text = _normalizeKoreanText(rawText);
    final localRange =
        _voiceScheduleStructureService.extractDateRange(text, now: _now());
    if (localRange != null) {
      normalized['is_multi_day'] = localRange.isMultiDay;
      normalized['is_all_day'] = localRange.isAllDay;
      return;
    }

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

  void _applyLocalDateRange(String rawText, Map<String, dynamic> schedule) {
    final range = _voiceScheduleStructureService.extractDateRange(
      rawText,
      now: _now(),
    );
    if (range == null) {
      return;
    }
    final shouldDefaultToMorning =
        range.isAllDay && !range.isMultiDay && !_hasExplicitTimeCue(rawText);
    final startAt = shouldDefaultToMorning
        ? DateTime(
            range.startAt.year,
            range.startAt.month,
            range.startAt.day,
            9,
          )
        : range.startAt;
    schedule['start_at'] = startAt.toIso8601String();
    schedule['end_at'] = range.endAt.toIso8601String();
    schedule['is_all_day'] = range.isAllDay;
    schedule['is_multi_day'] = range.isMultiDay;
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
    if (text.contains('매월')) {
      return 'FREQ=MONTHLY';
    }
    final yearly = RegExp(r'매년\s*(\d{1,2})월\s*(\d{1,2})일').firstMatch(text);
    if (yearly != null) {
      return 'FREQ=YEARLY;BYMONTH=${yearly.group(1)};BYMONTHDAY=${yearly.group(2)}';
    }
    if (text.contains('매년')) {
      return 'FREQ=YEARLY';
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
        RegExp(r'(?:(오전|오후)\s*)?\d{1,2}\s*시').hasMatch(text) ||
        _extractTimeFromText(text) != null;
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

    // '내일모레'/'내일모래'(STT 오인식)/'모레'는 2일 뒤. '내일' 단독보다 먼저 검사한다
    // ('내일모레'가 '내일'에 먼저 걸려 1일 뒤로 오인되는 것 방지).
    if (text.contains('내일모레') || text.contains('내일모래') || text.contains('모레')) {
      return today.add(const Duration(days: 2));
    }
    if (text.contains('글피')) {
      return today.add(const Duration(days: 3));
    }
    if (text.contains('내일')) {
      return today.add(const Duration(days: 1));
    }
    if (text.contains('오늘')) {
      return today;
    }

    final monthOffset = RegExp(
      r'(?:지금으로부터\s*)?(?<months>\d{1,2})\s*(?:개월|달|월)\s*(?:뒤|후)',
    ).firstMatch(text);
    if (monthOffset != null) {
      final months = int.tryParse(monthOffset.namedGroup('months') ?? '');
      if (months != null && months >= 0) {
        return DateTime(today.year, today.month + months, today.day);
      }
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

    final dayOnly =
        RegExp(r'(?<!\d)(?<day>\d{1,2})일(?:로|에|부터|까지)?').firstMatch(text);
    if (dayOnly != null) {
      final day = int.tryParse(dayOnly.namedGroup('day') ?? '');
      if (day != null && day >= 1) {
        final candidate = _resolveDayOnlyDate(now, day);
        if (candidate != null) {
          return candidate;
        }
      }
    }

    final weekDay = _extractWeekdayOffset(text);
    if (weekDay != null) {
      return weekDay;
    }

    return null;
  }

  DateTime? _resolveDayOnlyDate(DateTime now, int day) {
    final today = DateTime(now.year, now.month, now.day);
    for (var monthOffset = 0; monthOffset < 12; monthOffset += 1) {
      final candidate = DateTime(now.year, now.month + monthOffset, day);
      if (candidate.day != day) {
        continue;
      }
      if (candidate.isBefore(today)) {
        continue;
      }
      return DateTime(candidate.year, candidate.month, candidate.day, 9);
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
    final numericMatch = RegExp(
      r'(?:(오전|오후|아침|낮|점심|저녁|밤|새벽)\s*)?(\d{1,2})\s*시(?:\s*(\d{1,2})\s*분?|\s*(반))?',
    ).firstMatch(text);
    if (numericMatch != null) {
      final period = numericMatch.group(1);
      final hourText = numericMatch.group(2);
      final minuteText = numericMatch.group(3);
      final hasHalf = numericMatch.group(4) != null;
      return _clockTimeFromParts(
        period: period,
        hour: int.tryParse(hourText ?? ''),
        minute:
            hasHalf ? 30 : (minuteText == null ? 0 : int.tryParse(minuteText)),
      );
    }

    final koreanMatch = RegExp(
      r'(?:(오전|오후|아침|낮|점심|저녁|밤|새벽)\s*)?([가-힣]{1,8})\s*시(?:\s*([가-힣]{1,8}|\d{1,2})\s*분?|\s*(반))?',
    ).firstMatch(text);
    if (koreanMatch == null) {
      return null;
    }

    final period = koreanMatch.group(1);
    final hour = _parseKoreanNumber(koreanMatch.group(2));
    final minuteText = koreanMatch.group(3);
    final hasHalf = koreanMatch.group(4) != null || minuteText == '반';
    final minute = hasHalf
        ? 30
        : minuteText == null
            ? 0
            : int.tryParse(minuteText) ?? _parseKoreanNumber(minuteText);
    return _clockTimeFromParts(period: period, hour: hour, minute: minute);
  }

  _ClockTime? _clockTimeFromParts({
    required String? period,
    required int? hour,
    required int? minute,
  }) {
    final normalizedMinute = minute ?? 0;
    if (hour == null || normalizedMinute < 0 || normalizedMinute > 59) {
      return null;
    }
    if (hour < 0 || hour > 23) {
      return null;
    }

    if ((period == '오후' || period == '저녁' || period == '밤') && hour < 12) {
      hour += 12;
    } else if ((period == '오전' || period == '아침' || period == '새벽') &&
        hour == 12) {
      hour = 0;
    }

    return _ClockTime(hour: hour, minute: normalizedMinute);
  }

  int? _parseKoreanNumber(String? rawText) {
    if (rawText == null) {
      return null;
    }
    final text = rawText
        .replaceAll(RegExp(r'\s+'), '')
        .replaceFirst(RegExp(r'분$'), '')
        .trim();
    if (text.isEmpty) {
      return null;
    }
    final numeric = int.tryParse(text);
    if (numeric != null) {
      return numeric;
    }

    const nativeNumbers = <String, int>{
      '영': 0,
      '공': 0,
      '한': 1,
      '하나': 1,
      '한시': 1,
      '두': 2,
      '둘': 2,
      '세': 3,
      '셋': 3,
      '네': 4,
      '넷': 4,
      '다섯': 5,
      '여섯': 6,
      '일곱': 7,
      '여덟': 8,
      '아홉': 9,
      '열': 10,
      '열한': 11,
      '열하나': 11,
      '열두': 12,
      '열둘': 12,
      '스물': 20,
      '스물한': 21,
      '스물하나': 21,
      '스물두': 22,
      '스물둘': 22,
      '스물세': 23,
      '스물셋': 23,
      '스물네': 24,
      '스물넷': 24,
      '반': 30,
    };
    final native = nativeNumbers[text];
    if (native != null) {
      return native;
    }

    const sinoDigits = <String, int>{
      '일': 1,
      '이': 2,
      '삼': 3,
      '사': 4,
      '오': 5,
      '육': 6,
      '륙': 6,
      '칠': 7,
      '팔': 8,
      '구': 9,
    };
    if (text == '십') {
      return 10;
    }
    final tenMatch =
        RegExp(r'^(?:(일|이|삼|사|오|육|륙|칠|팔|구)?십)?(일|이|삼|사|오|육|륙|칠|팔|구)?$')
            .firstMatch(text);
    if (tenMatch != null && tenMatch.group(0)!.isNotEmpty) {
      final tens = tenMatch.group(1);
      final ones = tenMatch.group(2);
      var value = text.contains('십') ? (sinoDigits[tens] ?? 1) * 10 : 0;
      value += sinoDigits[ones] ?? 0;
      return value == 0 ? null : value;
    }
    return null;
  }

  String _normalizeKoreanText(String text) {
    return VoiceTextCleanupService.normalizeBasic(text);
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
title, date, start_at, end_at, location, location_lat, location_lng, travel_origin_lat, travel_origin_lng, travel_mode, memo, supplies, participants, targets, is_critical, recurrence_rule, is_all_day, is_multi_day, category, pre_actions.
start_at and end_at must be ISO-8601 date-time strings when possible.
Keep date, time, recurrence, and reminder expressions out of title and memo; put them only into the structured fields.
Location names must be kept in the title even when extracted into the location field. Never remove a place name from the title — only remove date, time, recurrence, reminder, and filler words (e.g. "만들어줘", "해줘").
For Korean relative and colloquial time expressions such as "3분 뒤", "2시간 후", "내일 오전 10시", "열두시반", "오후 두시 반", and "저녁 일곱시 삼십분", resolve them from the current local date and time.
"내일" means tomorrow (today + 1 day). "모레" and "내일모레" mean the day after tomorrow (today + 2 days); STT often mishears "모레" as "모래", so "내일모래" also means today + 2 days. "글피" means today + 3 days. Resolve "모레"/"내일모레"/"내일모래" to today + 2 days, never to tomorrow.
For day-only expressions like "28일" or "28일로", resolve to the 28th of the current month. If that date has already passed, use the 28th of the next month instead. Always output the full date in ISO-8601 format.
If only a date is known, use 09:00 local time unless the user clearly implies all-day.
For recurring schedules, return recurrence_rule as an iCal RRULE such as "FREQ=WEEKLY;BYDAY=TU". Otherwise return null.
For all-day schedules, set is_all_day true. For multi-day schedules such as "5월 1일부터 3일까지", set is_multi_day true and return both start_at and end_at.
category must be one of "업무", "개인", "건강", "교육", "기타"; infer conservatively and default to "기타".
Category examples: "병원 진료" and "헬스장" -> "건강"; "세미나 참석" and "강의" -> "교육"; "JW제약 미팅" -> "업무"; "친구 약속" -> "개인".
Keep date, time, recurrence, and reminder phrases out of title and memo once they are represented as structured fields.
Memo is only for an explicit note/description the user wants to keep, and only when the user explicitly says it with phrases like "메모에", "설명에", or "노트로". Do not copy the full raw utterance into memo.
When the user says "내용은 ..." or "할 일은 ...", treat the following phrase as the schedule content/title source, not as memo.
Keep people words, names, job titles, and recipient particles in the title. Do not shorten "김태형 PM한테" to "PM한테" or move the person out of the title.
Keep location names in the title even after extracting them into the location field.
participants and targets are compatibility fields only; leave them empty unless the source explicitly needs legacy export metadata.
Example: "내일 오전 9시에 대전출발" -> title "대전 출발", location "대전", start_at tomorrow 09:00 local, memo null.
Example: "12시까지 모란역으로 가기" -> title "모란역으로 가기", location "모란역", start_at today 12:00 local, memo null.
Example: "내일 오전 11시 팀장님 원주세브란스방문" -> title "팀장님 원주세브란스 방문", location "원주세브란스", participants ["팀장님"], targets [].
Example: "내일 오전 9시에 대전출발 메모에 주차장 B2 확인" -> title "대전 출발", location "대전", start_at tomorrow 09:00 local, memo "주차장 B2 확인".
For delivery/drop-off tasks at hospitals or clinics, keep recipient/customer names and items in title. Example: "내용은 원주기독 정형외과 김두섭 리바로 갖다주기" -> location "원주기독 정형외과", title "김두섭 리바로 갖다주기", supplies ["리바로"].
supplies must be an array of strings.
is_critical must be a boolean. Set to true when user speech includes "중요", "중요한 일정", "중요하게", "꼭 기억해야", "꼭 챙겨야", "놓치면 안 되는", "절대 잊으면 안 되는" or similar emphasis. Default is false.
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
- Input: "내일 오후 2시 병원 미팅" -> pre_actions: [] unless the text explicitly asks for departure, travel, supplies, or documents.
- Input: "토요일 병원 병문안" -> include "꽃이나 선물 챙기기", but no medical or fasting pre_actions.
- Input: "월요일 오전 8시 병원 건강검진" -> include "병원 준비사항 확인" and "금식/복약 안내 확인".
- Input: "모레 오전 8시 위내시경 검사" -> include "병원 준비사항 확인" and "금식/복약 안내 확인".
- Input: "내일 법원" or "내일 학교" -> do not infer legal, school, medical, or fasting pre_actions from the place alone.
travel_mode must be "car", "transit", or null.
Only include latitude/longitude values when they are explicitly known from the input or prior context.
If a field is not known, use null or an empty array.
''';

const String _voiceTextCleanupPrompt = '''
You are a Korean STT cleanup assistant for a schedule app.
Return only a valid JSON object with these keys:
cleaned_text, changed, reason, confidence.

Task:
- Make the recognized Korean schedule command natural and readable.
- Correct likely STT segmentation, repeated particles, repeated words, and awkward Korean when context makes the correction obvious.
- Use candidate_events only as context for edit/delete/query target wording.
- Do not add new schedule facts.
- Do not change dates, times, recurrence, action intent, or locations unless the original text clearly contains a recognition/spacing error.
- If unsure, return the original text with changed false and confidence below 0.65.

Examples:
- "내일 열두시반 병원" -> keep as is.
- "서울에서 출발해서 아산에서 도착" -> keep as is.
- If a candidate event title/location clearly joins words that STT split with particles, repair the phrase.
''';

const String _morningBriefingPrompt = '''
당신은 한국어 일정 브리핑 비서입니다.
오늘 일정을 시간순으로, 실제 비서가 말하듯 자연스럽게 브리핑하세요.
각 일정은 한 문장으로 말하되, 장소가 있는 일정만 "오전 9시, 강남역에서 고객 미팅이 있습니다."처럼 장소를 포함하세요.
장소가 없는 일정은 장소를 지어내지 말고 "오전 9시, 고객 미팅이 있습니다."처럼 시간과 일정명만 말하세요.
중요 일정은 문장 끝에 "중요"만 붙이지 말고, 일정 안내 전에 "중요한 일정입니다." 또는 "다음은 중요한 일정입니다."라고 먼저 말하세요.
두 번째 일정부터는 "다음 일정은 ..." 또는 "그다음 일정은 ..."처럼 이어서 말하세요.
명시된 장소가 있는 일정들 사이에서만 이동 관련 조언을 하세요.
장소가 없거나 이동시간을 판단할 근거가 없으면 "이동", "출발", "서둘러" 같은 표현을 쓰지 마세요.
과도한 조언이나 해석은 하지 말고, 마크다운 없이 한국어 음성 안내 문장으로만 답하세요.
''';

const String _eveningBriefingPrompt = '''
당신은 한국어 일정 브리핑 비서입니다.
내일 일정을 시간순으로, 실제 비서가 말하듯 자연스럽게 브리핑하세요.
각 일정은 한 문장으로 말하되, 장소가 있는 일정만 "오전 9시, 강남역에서 고객 미팅이 있습니다."처럼 장소를 포함하세요.
장소가 없는 일정은 장소를 지어내지 말고 "오전 9시, 고객 미팅이 있습니다."처럼 시간과 일정명만 말하세요.
중요 일정은 문장 끝에 "중요"만 붙이지 말고, 일정 안내 전에 "중요한 일정입니다." 또는 "다음은 중요한 일정입니다."라고 먼저 말하세요.
두 번째 일정부터는 "다음 일정은 ..." 또는 "그다음 일정은 ..."처럼 이어서 말하세요.
명시된 장소가 있는 일정들 사이에서만 이동 관련 조언을 하세요.
장소가 없거나 이동시간을 판단할 근거가 없으면 "이동", "출발", "서둘러" 같은 표현을 쓰지 마세요.
과도한 조언이나 해석은 하지 말고, 마크다운 없이 한국어 음성 안내 문장으로만 답하세요.
''';
