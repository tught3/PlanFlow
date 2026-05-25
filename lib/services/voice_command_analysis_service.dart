import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/env.dart';
import '../core/event_metadata.dart';
import '../core/local_time.dart';
import 'gpt_service.dart';
import 'remote_config_service.dart';
import 'voice_command_router.dart';
import 'voice_schedule_structure_service.dart';
import 'voice_text_cleanup_service.dart';

enum VoiceCommandAnalysisStage {
  partial,
  complete,
}

enum VoiceCommandIntent {
  add,
  edit,
  delete,
  query,
  choose,
}

enum VoiceCommandAnalysisMethod {
  none,
  local,
  ai,
  cache,
}

class VoiceAnalysisRequestBudget {
  VoiceAnalysisRequestBudget({
    required this.maxAiRequests,
  });

  final int maxAiRequests;
  int _usedAiRequests = 0;

  int get usedAiRequests => _usedAiRequests;

  int get remainingAiRequests => maxAiRequests - _usedAiRequests;

  bool get hasRemaining => _usedAiRequests < maxAiRequests;

  bool tryConsume([int amount = 1]) {
    if (amount <= 0) {
      return true;
    }
    if (_usedAiRequests + amount > maxAiRequests) {
      return false;
    }
    _usedAiRequests += amount;
    return true;
  }

  void reset() {
    _usedAiRequests = 0;
  }
}

class VoiceCommandAnalysisResult {
  const VoiceCommandAnalysisResult({
    required this.rawText,
    required this.cleanedText,
    required this.normalizedText,
    required this.intent,
    required this.confidence,
    required this.uncertainFields,
    required this.scheduleFields,
    required this.targetEventHint,
    required this.requestedChanges,
    required this.method,
    required this.stage,
    required this.analysisSignature,
    required this.fromCache,
  });

  final String rawText;
  final String cleanedText;
  final String normalizedText;
  final VoiceCommandIntent intent;
  final double confidence;
  final List<String> uncertainFields;
  final Map<String, dynamic> scheduleFields;
  final Map<String, dynamic>? targetEventHint;
  final List<String> requestedChanges;
  final VoiceCommandAnalysisMethod method;
  final VoiceCommandAnalysisStage stage;
  final String analysisSignature;
  final bool fromCache;

  bool get usedAi =>
      method == VoiceCommandAnalysisMethod.ai ||
      method == VoiceCommandAnalysisMethod.cache;

  bool get isLocalOnly => method == VoiceCommandAnalysisMethod.local;

  VoiceCommandAnalysisResult copyWith({
    String? rawText,
    String? cleanedText,
    String? normalizedText,
    VoiceCommandIntent? intent,
    double? confidence,
    List<String>? uncertainFields,
    Map<String, dynamic>? scheduleFields,
    Map<String, dynamic>? targetEventHint,
    List<String>? requestedChanges,
    VoiceCommandAnalysisMethod? method,
    VoiceCommandAnalysisStage? stage,
    String? analysisSignature,
    bool? fromCache,
  }) {
    return VoiceCommandAnalysisResult(
      rawText: rawText ?? this.rawText,
      cleanedText: cleanedText ?? this.cleanedText,
      normalizedText: normalizedText ?? this.normalizedText,
      intent: intent ?? this.intent,
      confidence: confidence ?? this.confidence,
      uncertainFields: uncertainFields ?? this.uncertainFields,
      scheduleFields: scheduleFields ?? this.scheduleFields,
      targetEventHint: targetEventHint ?? this.targetEventHint,
      requestedChanges: requestedChanges ?? this.requestedChanges,
      method: method ?? this.method,
      stage: stage ?? this.stage,
      analysisSignature: analysisSignature ?? this.analysisSignature,
      fromCache: fromCache ?? this.fromCache,
    );
  }

  Map<String, dynamic> toParsedScheduleMap() {
    final schedule = <String, dynamic>{
      'parse_failed': false,
      'raw_text': rawText,
      'title': scheduleFields['title'] ?? normalizedText,
      'date': scheduleFields['date'],
      'start_at': scheduleFields['start_at'],
      'end_at': scheduleFields['end_at'],
      'location': scheduleFields['location'],
      'location_lat': scheduleFields['location_lat'],
      'location_lng': scheduleFields['location_lng'],
      'travel_origin_lat': scheduleFields['travel_origin_lat'],
      'travel_origin_lng': scheduleFields['travel_origin_lng'],
      'travel_mode': scheduleFields['travel_mode'],
      'memo': scheduleFields['memo'],
      'supplies': scheduleFields['supplies'] ?? <String>[],
      'participants': scheduleFields['participants'] ?? <String>[],
      'targets': scheduleFields['targets'] ?? <String>[],
      'is_critical': scheduleFields['is_critical'] ?? false,
      'recurrence_rule': scheduleFields['recurrence_rule'],
      'is_all_day': scheduleFields['is_all_day'] ?? false,
      'is_multi_day': scheduleFields['is_multi_day'] ?? false,
      'category': scheduleFields['category'] ?? '기타',
      'pre_actions': scheduleFields['pre_actions'] ?? <Map<String, dynamic>>[],
      'normalized_text': normalizedText,
      'voice_intent': intent.name,
      'confidence': confidence,
      'uncertain_fields': uncertainFields,
    };
    if (targetEventHint != null) {
      schedule['target_event_hint'] = targetEventHint;
    }
    if (requestedChanges.isNotEmpty) {
      schedule['requested_changes'] = requestedChanges;
    }
    return schedule;
  }
}

class VoiceCommandAnalysisService {
  VoiceCommandAnalysisService({
    http.Client? client,
    Uri? endpoint,
    DateTime Function()? now,
    int maxAiRequests = 3,
  })  : _client = client,
        _endpoint = endpoint ??
            Uri.parse('${AppEnv.supabaseUrl}/functions/v1/openai-proxy'),
        _now = now ?? planflowNow,
        _sessionBudget =
            VoiceAnalysisRequestBudget(maxAiRequests: maxAiRequests);

  final http.Client? _client;
  final Uri _endpoint;
  final DateTime Function() _now;
  final VoiceAnalysisRequestBudget _sessionBudget;
  final Map<String, VoiceCommandAnalysisResult> _aiCache =
      <String, VoiceCommandAnalysisResult>{};
  static const VoiceCommandRouter _router = VoiceCommandRouter();
  static const VoiceScheduleStructureService _voiceScheduleStructureService =
      VoiceScheduleStructureService();

  VoiceCommandAnalysisResult? _latestDraft;

  static const Map<String, dynamic> _responseFormat = <String, dynamic>{
    'type': 'json_object',
  };

  VoiceCommandAnalysisResult? get latestDraft => _latestDraft;

  void resetSession() {
    _aiCache.clear();
    _latestDraft = null;
    _sessionBudget.reset();
  }

  bool shouldRequestAi(
    String rawText, {
    VoiceCommandAnalysisStage stage = VoiceCommandAnalysisStage.partial,
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
    Iterable<VoiceTextCleanupCandidate> candidates = const [],
    VoiceCommandAnalysisResult? previousDraft,
  }) {
    final cleanup = VoiceTextCleanupService.cleanLocally(
      rawText,
      context: context,
      candidates: candidates,
    );
    final normalized = cleanup.cleanedText;

    if (stage == VoiceCommandAnalysisStage.complete) {
      return true;
    }
    if (VoiceTextCleanupService.shouldAskAi(normalized)) {
      return true;
    }
    if (_hasCommandCue(normalized) || _hasScheduleCue(normalized)) {
      return true;
    }
    if (previousDraft != null &&
        hasMeaningfulChange(previousDraft.normalizedText, normalized)) {
      return _hasCommandCue(normalized) || _hasScheduleCue(normalized);
    }
    return false;
  }

  Future<VoiceCommandAnalysisResult> analyze(
    String rawText, {
    VoiceCommandAnalysisStage stage = VoiceCommandAnalysisStage.partial,
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
    Iterable<VoiceTextCleanupCandidate> candidates = const [],
    VoiceAnalysisRequestBudget? budget,
    VoiceCommandAnalysisResult? previousDraft,
  }) async {
    final cleanup = VoiceTextCleanupService.cleanLocally(
      rawText,
      context: context,
      candidates: candidates,
    );
    final normalized = cleanup.cleanedText;
    final signature = analysisSignatureFor(
      normalized,
      context: context,
      candidates: candidates,
    );
    final effectivePreviousDraft = previousDraft ?? _latestDraft;
    final cacheHit = _aiCache[signature];
    if (cacheHit != null) {
      final cachedResult = cacheHit.copyWith(
        rawText: cleanup.originalText,
        cleanedText: normalized,
        fromCache: true,
        method: VoiceCommandAnalysisMethod.cache,
        stage: stage,
      );
      _latestDraft = cachedResult;
      return cachedResult;
    }

    final localResult = _buildLocalResult(
      cleanup: cleanup,
      stage: stage,
      context: context,
      candidates: candidates,
      signature: signature,
    );

    final shouldRequest = shouldRequestAi(
      rawText,
      stage: stage,
      context: context,
      candidates: candidates,
      previousDraft: effectivePreviousDraft,
    );
    final effectiveBudget = budget ?? _sessionBudget;
    if (!shouldRequest || !effectiveBudget.tryConsume()) {
      _latestDraft = localResult;
      return localResult;
    }

    final candidateLines = candidates.take(12).map((candidate) {
      final startAt = candidate.startAt?.toIso8601String() ?? '시간 미정';
      final location = candidate.location?.trim();
      return '- 제목: ${candidate.title}, 장소: ${location == null || location.isEmpty ? '없음' : location}, 시작: $startAt';
    }).join('\n');

    final content = await _requestCompletion(
      systemPrompt: _voiceCommandAnalysisPrompt,
      userPrompt: jsonEncode(<String, dynamic>{
        'stage': stage.name,
        'context': context.name,
        'text': normalized,
        'raw_text': cleanup.originalText,
        if (effectivePreviousDraft != null)
          'previous_draft': <String, dynamic>{
            'normalized_text': effectivePreviousDraft.normalizedText,
            'intent': effectivePreviousDraft.intent.name,
            'confidence': effectivePreviousDraft.confidence,
            'schedule_fields': effectivePreviousDraft.scheduleFields,
            if (effectivePreviousDraft.targetEventHint != null)
              'target_event_hint': effectivePreviousDraft.targetEventHint,
            if (effectivePreviousDraft.requestedChanges.isNotEmpty)
              'requested_changes': effectivePreviousDraft.requestedChanges,
          },
        if (candidateLines.isNotEmpty) 'candidate_events': candidateLines,
      }),
      responseFormat: _responseFormat,
    );
    final parsed = _decodeJsonMap(content);
    if (parsed == null) {
      _latestDraft = localResult;
      return localResult;
    }

    final aiResult = _buildAiResult(
      parsed: parsed,
      cleanup: cleanup,
      stage: stage,
      context: context,
      candidates: candidates,
      signature: signature,
      fallback: localResult,
    );
    _aiCache[signature] = aiResult;
    _latestDraft = aiResult;
    return aiResult;
  }

  VoiceCommandAnalysisResult _buildLocalResult({
    required VoiceTextCleanupResult cleanup,
    required VoiceCommandAnalysisStage stage,
    required VoiceTextCleanupContext context,
    required Iterable<VoiceTextCleanupCandidate> candidates,
    required String signature,
  }) {
    final normalized = cleanup.cleanedText;
    final intent = _inferLocalIntent(normalized, context: context);
    final targetEventHint = _buildTargetEventHint(
      normalized,
      candidates,
      context: context,
    );
    final requestedChanges = _inferRequestedChanges(normalized);
    final startAt = GptService(now: _now).inferStartAtFromRawText(normalized);
    final scheduleFields = _normalizeScheduleFields(
      <String, dynamic>{
        'title': _deriveLocalTitle(normalized),
        'date': null,
        'start_at': startAt?.toIso8601String(),
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
        'recurrence_rule': null,
        'is_all_day': false,
        'is_multi_day': false,
        'category': _inferCategoryFromRawText(normalized),
        'pre_actions': <Map<String, dynamic>>[],
      },
      rawText: cleanup.originalText,
      normalizedText: normalized,
      intent: intent,
      fallbackStartAt: startAt,
    );
    final uncertainFields = _localUncertainFields(
      intent: intent,
      scheduleFields: scheduleFields,
      targetEventHint: targetEventHint,
      requestedChanges: requestedChanges,
      context: context,
    );

    return VoiceCommandAnalysisResult(
      rawText: cleanup.originalText,
      cleanedText: cleanup.cleanedText,
      normalizedText: normalized,
      intent: intent,
      confidence: _localConfidence(
        normalized: normalized,
        intent: intent,
        scheduleFields: scheduleFields,
        targetEventHint: targetEventHint,
      ),
      uncertainFields: uncertainFields,
      scheduleFields: Map<String, dynamic>.unmodifiable(scheduleFields),
      targetEventHint: targetEventHint == null
          ? null
          : Map<String, dynamic>.unmodifiable(targetEventHint),
      requestedChanges: List<String>.unmodifiable(requestedChanges),
      method: VoiceCommandAnalysisMethod.local,
      stage: stage,
      analysisSignature: signature,
      fromCache: false,
    );
  }

  VoiceCommandAnalysisResult _buildAiResult({
    required Map<String, dynamic> parsed,
    required VoiceTextCleanupResult cleanup,
    required VoiceCommandAnalysisStage stage,
    required VoiceTextCleanupContext context,
    required Iterable<VoiceTextCleanupCandidate> candidates,
    required String signature,
    required VoiceCommandAnalysisResult fallback,
  }) {
    final normalizedText = _normalizeText(
      parsed['normalized_text']?.toString(),
      fallback.cleanedText,
    );
    final intent =
        _parseIntent(parsed['intent']?.toString()) ?? fallback.intent;
    final uncertainFields = _normalizeStringList(parsed['uncertain_fields']);
    final requestedChanges = _normalizeStringList(parsed['requested_changes']);
    final scheduleFields = _buildScheduleFieldsFromResponse(
      parsed: parsed,
      rawText: cleanup.originalText,
      normalizedText: normalizedText,
      fallback: fallback,
      intent: intent,
    );
    final targetEventHint = _normalizeTargetEventHint(
      parsed['target_event_hint'],
      fallback: fallback,
      candidates: candidates,
      normalizedText: normalizedText,
      context: context,
    );
    final confidence = _clampConfidence(
      _doubleValue(parsed['confidence']) ?? fallback.confidence,
      fallback.confidence,
    );

    return VoiceCommandAnalysisResult(
      rawText: cleanup.originalText,
      cleanedText: cleanup.cleanedText,
      normalizedText: normalizedText,
      intent: intent,
      confidence: confidence,
      uncertainFields: uncertainFields.isEmpty
          ? _localUncertainFields(
              intent: intent,
              scheduleFields: scheduleFields,
              targetEventHint: targetEventHint,
              requestedChanges: requestedChanges,
              context: context,
            )
          : List<String>.unmodifiable(uncertainFields),
      scheduleFields: Map<String, dynamic>.unmodifiable(scheduleFields),
      targetEventHint: targetEventHint == null
          ? null
          : Map<String, dynamic>.unmodifiable(targetEventHint),
      requestedChanges: List<String>.unmodifiable(requestedChanges),
      method: VoiceCommandAnalysisMethod.ai,
      stage: stage,
      analysisSignature: signature,
      fromCache: false,
    );
  }

  Map<String, dynamic> _buildScheduleFieldsFromResponse({
    required Map<String, dynamic> parsed,
    required String rawText,
    required String normalizedText,
    required VoiceCommandAnalysisResult fallback,
    required VoiceCommandIntent intent,
  }) {
    final rawFields = parsed['schedule_fields'];
    Map<String, dynamic>? source;
    if (rawFields is Map) {
      source = Map<String, dynamic>.from(rawFields);
    } else {
      final allowedKeys = <String>{
        'title',
        'date',
        'start_at',
        'end_at',
        'location',
        'location_lat',
        'location_lng',
        'travel_origin_lat',
        'travel_origin_lng',
        'travel_mode',
        'memo',
        'supplies',
        'participants',
        'targets',
        'is_critical',
        'recurrence_rule',
        'is_all_day',
        'is_multi_day',
        'category',
        'pre_actions',
      };
      source = <String, dynamic>{};
      for (final entry in parsed.entries) {
        if (allowedKeys.contains(entry.key)) {
          source[entry.key] = entry.value;
        }
      }
    }

    return _normalizeScheduleFields(
      source,
      rawText: rawText,
      normalizedText: normalizedText,
      fallback: fallback,
      fallbackStartAt: _parseDateTime(fallback.scheduleFields['start_at']),
      intent: intent,
    );
  }

  Map<String, dynamic> _normalizeScheduleFields(
    Map<String, dynamic>? fields, {
    required String rawText,
    required String normalizedText,
    required VoiceCommandIntent intent,
    DateTime? fallbackStartAt,
    VoiceCommandAnalysisResult? fallback,
  }) {
    final source = fields ?? <String, dynamic>{};
    final gpt = GptService(now: _now);
    final localDateRange = _voiceScheduleStructureService.extractDateRange(
          normalizedText,
          now: _now(),
        ) ??
        _voiceScheduleStructureService.extractDateRange(
          rawText,
          now: _now(),
        );
    final inferredStartAt = localDateRange?.startAt ??
        _parseDateTime(source['start_at']) ??
        fallbackStartAt ??
        gpt.inferStartAtFromRawText(normalizedText) ??
        gpt.inferStartAtFromRawText(rawText) ??
        _parseDateTime(fallback?.scheduleFields['start_at']);
    final rangeStrippedText =
        _voiceScheduleStructureService.stripDateRangeExpression(
      normalizedText,
      now: _now(),
    );
    final titleSource = _extractContentClause(rangeStrippedText) ??
        _stripExplicitMemoClause(rangeStrippedText);
    final structured = _voiceScheduleStructureService.analyze(
      titleSource,
    );
    final sourceTitle = _normalizeText(
      _voiceScheduleStructureService.stripDateRangeExpression(
        source['title']?.toString() ?? '',
        now: _now(),
      ),
      null,
    );
    final title = sourceTitle.isNotEmpty
        ? _deriveLocalTitle(
            sourceTitle,
            referenceText: normalizedText,
            structured: structured,
          )
        : _deriveLocalTitle(
            titleSource,
            referenceText: normalizedText,
            structured: structured,
          );
    final normalizedLocationText =
        _normalizeText(source['location']?.toString(), null);
    final inferredLocation =
        _voiceScheduleStructureService.normalizeScheduleLocation(
      location:
          normalizedLocationText.isNotEmpty ? normalizedLocationText : null,
      rawText: titleSource,
      title: title,
    );

    final scheduleFields = <String, dynamic>{
      'title': title.isEmpty ? titleSource : title,
      'date': source['date'],
      'start_at': inferredStartAt?.toIso8601String(),
      'end_at': (localDateRange?.endAt ?? _normalizeDateTime(source['end_at']))
          ?.toIso8601String(),
      'location': inferredLocation == null
          ? null
          : _normalizeSpacingForSchedule(inferredLocation),
      'location_lat': _doubleValue(source['location_lat']),
      'location_lng': _doubleValue(source['location_lng']),
      'travel_origin_lat': _doubleValue(source['travel_origin_lat']),
      'travel_origin_lng': _doubleValue(source['travel_origin_lng']),
      'travel_mode': _normalizeText(source['travel_mode']?.toString(), null),
      'memo': _extractExplicitMemo(rawText),
      'supplies': _normalizeStringList(source['supplies']),
      'participants': _normalizeStringList(source['participants']),
      'targets': _normalizeStringList(source['targets']),
      'is_critical': source['is_critical'] == true,
      'recurrence_rule': _normalizeText(
        source['recurrence_rule']?.toString(),
        _inferLocalRecurrence(normalizedText),
      ),
      'is_all_day': localDateRange?.isAllDay ?? source['is_all_day'] == true,
      'is_multi_day':
          localDateRange?.isMultiDay ?? source['is_multi_day'] == true,
      'category': _normalizeCategory(
        _normalizeText(
          source['category']?.toString(),
          _inferCategoryFromRawText(normalizedText),
        ),
      ),
      'pre_actions': _normalizePreActions(source['pre_actions']),
      'voice_intent': intent.name,
    };
    _preserveDeliveryContent(scheduleFields, titleSource);
    _preservePeopleFields(scheduleFields, titleSource);
    return scheduleFields;
  }

  void _preservePeopleFields(
    Map<String, dynamic> scheduleFields,
    String sourceText,
  ) {
    final people = _voiceScheduleStructureService.extractPeopleFields(
      sourceText,
    );
    scheduleFields['participants'] = _mergeStringLists(
      scheduleFields['participants'],
      people.participants,
    );
    scheduleFields['targets'] = _mergeStringLists(
      scheduleFields['targets'],
      people.targets,
    );

    final title = scheduleFields['title']?.toString() ?? '';
    scheduleFields['title'] =
        _voiceScheduleStructureService.ensurePeopleInTitle(
      title,
      sourceText,
    );
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

  Map<String, dynamic>? _normalizeTargetEventHint(
    Object? targetEventHint, {
    required VoiceCommandAnalysisResult fallback,
    required Iterable<VoiceTextCleanupCandidate> candidates,
    required String normalizedText,
    required VoiceTextCleanupContext context,
  }) {
    if (targetEventHint is Map) {
      final hint = Map<String, dynamic>.from(targetEventHint);
      final title = _normalizeText(hint['title']?.toString(), null);
      final location = _normalizeText(hint['location']?.toString(), null);
      final startAt = _parseDateTime(hint['start_at']);
      return <String, dynamic>{
        if (title.isNotEmpty) 'title': title,
        if (location.isNotEmpty) 'location': location,
        if (startAt != null) 'start_at': startAt.toIso8601String(),
        if (hint['candidate_index'] != null)
          'candidate_index': hint['candidate_index'],
        if (hint['score'] != null) 'score': hint['score'],
      };
    }

    if (targetEventHint is String && targetEventHint.trim().isNotEmpty) {
      return <String, dynamic>{'title': targetEventHint.trim()};
    }

    return _buildTargetEventHint(
          normalizedText,
          candidates,
          context: context,
        ) ??
        fallback.targetEventHint;
  }

  Map<String, dynamic>? _buildTargetEventHint(
    String text,
    Iterable<VoiceTextCleanupCandidate> candidates, {
    required VoiceTextCleanupContext context,
  }) {
    return _router.buildTargetEventHint(
      text,
      candidates,
      context: context,
    );
  }

  List<String> _inferRequestedChanges(String text) {
    return _router.extractRequestedChanges(text);
  }

  List<String> _localUncertainFields({
    required VoiceCommandIntent intent,
    required Map<String, dynamic> scheduleFields,
    required Map<String, dynamic>? targetEventHint,
    required List<String> requestedChanges,
    required VoiceTextCleanupContext context,
  }) {
    final fields = <String>{};
    if (intent == VoiceCommandIntent.add &&
        (scheduleFields['start_at'] == null ||
            scheduleFields['start_at'].toString().trim().isEmpty)) {
      fields.add('start_at');
    }
    if (context != VoiceTextCleanupContext.add && targetEventHint == null) {
      fields.add('target_event_hint');
    }
    if (context != VoiceTextCleanupContext.add && requestedChanges.isEmpty) {
      fields.add('requested_changes');
    }
    return fields.toList(growable: false);
  }

  double _localConfidence({
    required String normalized,
    required VoiceCommandIntent intent,
    required Map<String, dynamic> scheduleFields,
    required Map<String, dynamic>? targetEventHint,
  }) {
    var confidence = 0.3;
    if (_hasCommandCue(normalized) || _hasScheduleCue(normalized)) {
      confidence += 0.2;
    }
    if (scheduleFields['start_at'] != null) {
      confidence += 0.2;
    }
    if (targetEventHint != null) {
      confidence += 0.15;
    }
    if (intent != VoiceCommandIntent.add) {
      confidence += 0.1;
    }
    return confidence.clamp(0.05, 0.95).toDouble();
  }

  VoiceCommandIntent _inferLocalIntent(
    String text, {
    required VoiceTextCleanupContext context,
  }) {
    return switch (_router.resolveIntent(text, context: context)) {
      VoiceCommandRouteIntent.add => VoiceCommandIntent.add,
      VoiceCommandRouteIntent.edit => VoiceCommandIntent.edit,
      VoiceCommandRouteIntent.delete => VoiceCommandIntent.delete,
      VoiceCommandRouteIntent.query => VoiceCommandIntent.query,
      VoiceCommandRouteIntent.choose => VoiceCommandIntent.choose,
    };
  }

  VoiceCommandIntent? _parseIntent(String? rawIntent) {
    final normalized = rawIntent?.trim().toLowerCase();
    return switch (normalized) {
      'add' => VoiceCommandIntent.add,
      'edit' => VoiceCommandIntent.edit,
      'delete' => VoiceCommandIntent.delete,
      'query' => VoiceCommandIntent.query,
      'choose' => VoiceCommandIntent.choose,
      _ => null,
    };
  }

  bool _hasCommandCue(String text) {
    final normalized = _normalizeText(text, '');
    return RegExp(
      r'(추가|등록|저장(?!된|한|되어|돼)|새로|기록|메모|예약|만들어|해줘|해줄래|바꿔|수정|변경|삭제|지워|찾아|검색|알려|이동)',
    ).hasMatch(normalized);
  }

  bool _hasScheduleCue(String text) {
    final normalized = _normalizeText(text, '');
    return _parseDateTimeHint(normalized) != null ||
        RegExp(r'(오늘|내일|모레|글피|이번주|다음주|매주|격주|매월|매년)').hasMatch(normalized);
  }

  String _deriveLocalTitle(
    String text, {
    String? referenceText,
    VoiceScheduleStructure? structured,
  }) {
    return _voiceScheduleStructureService.normalizeLocalVoiceTitle(
      text,
      referenceText: referenceText,
      structured: structured ??
          _voiceScheduleStructureService.analyze(referenceText ?? text),
    );
  }

  String? _extractExplicitMemo(String rawText) {
    return _voiceScheduleStructureService.extractExplicitMemo(rawText);
  }

  String _stripExplicitMemoClause(String text) {
    return _voiceScheduleStructureService.stripExplicitMemoClause(text);
  }

  String? _extractContentClause(String rawText) {
    final source = _normalizeText(rawText, '');
    final match = RegExp(
      r'(?:내용은|내용\s*[:：]|할\s*일은|일정\s*내용은)\s*(.+)$',
    ).firstMatch(source);
    final content = match?.group(1)?.trim();
    if (content == null || content.isEmpty) {
      return null;
    }
    return content.replaceFirst(RegExp(r'^[.。,\s]+'), '').trim();
  }

  void _preserveDeliveryContent(
    Map<String, dynamic> scheduleFields,
    String contentText,
  ) {
    return _voiceScheduleStructureService.preserveDeliveryContent(
      scheduleFields,
      contentText,
    );
  }

  String _normalizeSpacingForSchedule(String text) {
    return _voiceScheduleStructureService.normalizeSpacingForSchedule(text);
  }

  String? _inferLocalRecurrence(String text) {
    final normalized = _normalizeText(text, '');
    final weekday = _weekdayRRuleToken(normalized);

    if (normalized.contains('격주')) {
      return 'FREQ=WEEKLY;INTERVAL=2${weekday == null ? '' : ';BYDAY=$weekday'}';
    }
    if (normalized.contains('매주')) {
      return 'FREQ=WEEKLY${weekday == null ? '' : ';BYDAY=$weekday'}';
    }

    final monthlyOrdinal = RegExp(
      r'매월\s*(첫\s*번째|첫째|두\s*번째|둘째|세\s*번째|셋째|네\s*번째|넷째|마지막)\s*([월화수목금토일])요일',
    ).firstMatch(normalized);
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

    final monthlyDay = RegExp(r'매월\s*(\d{1,2})일').firstMatch(normalized);
    if (monthlyDay != null) {
      return 'FREQ=MONTHLY;BYMONTHDAY=${monthlyDay.group(1)}';
    }

    if (normalized.contains('매월')) {
      return 'FREQ=MONTHLY';
    }

    final yearly =
        RegExp(r'매년\s*(\d{1,2})월\s*(\d{1,2})일').firstMatch(normalized);
    if (yearly != null) {
      return 'FREQ=YEARLY;BYMONTH=${yearly.group(1)};BYMONTHDAY=${yearly.group(2)}';
    }

    if (normalized.contains('매년')) {
      return 'FREQ=YEARLY';
    }

    final custom =
        RegExp(r'(\d{1,2})\s*(일|주|개월|달|월|년)\s*마다').firstMatch(normalized);
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
      if (freq != null && interval != null) {
        return 'FREQ=$freq;INTERVAL=$interval';
      }
    }

    return null;
  }

  String? _weekdayRRuleToken(String text) {
    final match = RegExp(r'([월화수목금토일])요일').firstMatch(text);
    if (match == null) {
      return null;
    }

    return _weekdayShortToken(match.group(1));
  }

  String? _weekdayShortToken(String? weekday) {
    return switch (weekday) {
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

  String _normalizeCategory(String category) {
    return PlanFlowEventCategories.normalize(category);
  }

  String _inferCategoryFromRawText(String rawText) {
    final text = _normalizeText(rawText, '');
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

  List<String> _normalizeStringList(Object? value) {
    if (value is List) {
      return value
          .whereType<String>()
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toSet()
          .toList(growable: false);
    }
    if (value is String) {
      return value
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toSet()
          .toList(growable: false);
    }
    return <String>[];
  }

  DateTime? _normalizeDateTime(Object? value) {
    return _parseDateTime(value);
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

  double? _doubleValue(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

  double _clampConfidence(double value, double fallback) {
    if (value.isNaN || value.isInfinite) {
      return fallback;
    }
    return value.clamp(0.0, 1.0).toDouble();
  }

  String _normalizeText(String? value, String? fallback) {
    final text = value?.trim();
    if (text == null || text.isEmpty) {
      return fallback?.trim() ?? '';
    }
    return VoiceTextCleanupService.normalizeBasic(text);
  }

  bool hasMeaningfulChange(String previousText, String currentText) {
    final previous = VoiceTextCleanupService.normalizeBasic(previousText);
    final current = VoiceTextCleanupService.normalizeBasic(currentText);
    if (previous == current) {
      return false;
    }
    final previousSignature =
        VoiceTextCleanupService.normalizeForSearch(previous);
    final currentSignature =
        VoiceTextCleanupService.normalizeForSearch(current);
    return previousSignature != currentSignature;
  }

  static String analysisSignatureFor(
    String text, {
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
    Iterable<VoiceTextCleanupCandidate> candidates = const [],
  }) {
    final normalizedText = VoiceTextCleanupService.normalizeForSearch(text);
    final candidateSignature = candidates.take(12).map((candidate) {
      final location = candidate.location?.trim() ?? '';
      final startAt = candidate.startAt?.toIso8601String() ?? '';
      return [
        VoiceTextCleanupService.normalizeForSearch(candidate.title),
        VoiceTextCleanupService.normalizeForSearch(location),
        startAt,
      ].join('|');
    }).join('||');
    final source = [
      context.name,
      normalizedText,
      candidateSignature,
    ].join('::');
    return _fnv1aHashHex(source);
  }

  static String _fnv1aHashHex(String input) {
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  Future<String?> _requestCompletion({
    required String systemPrompt,
    required String userPrompt,
    Map<String, dynamic>? responseFormat,
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
          'model': RemoteConfigService.gptModel,
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

      final decodedText = utf8.decode(response.bodyBytes);
      final decoded = jsonDecode(decodedText);
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

  DateTime? _parseDateTimeHint(String text) {
    final gpt = GptService(now: _now);
    return gpt.inferStartAtFromRawText(text);
  }
}

const String _voiceCommandAnalysisPrompt = '''
You are a Korean voice command pre-analyzer for schedule input.
Return only a valid JSON object.

Required keys:
- normalized_text: string
- intent: one of "add", "edit", "delete", "query", "choose"
- confidence: number from 0.0 to 1.0
- uncertain_fields: array of strings
- schedule_fields: object or null
- target_event_hint: object or null
- requested_changes: array of strings

Rules:
- normalized_text must keep the user's meaning after cleanup and command interpretation.
- Do not invent audio or data that was not spoken.
- For add intent, fill schedule_fields with parseSchedule-compatible keys:
  title, date, start_at, end_at, location, location_lat, location_lng,
  travel_origin_lat, travel_origin_lng, travel_mode, memo, supplies,
  participants, targets, is_critical, recurrence_rule, is_all_day,
  is_multi_day, category, pre_actions.
- Keep person words such as "팀장님", "원장님", "교수님", "고객님", or named
  contacts in title and also classify them into people fields when clear.
- Use participants for people attached to the schedule, including
  "랑/와/과/하고/함께/동행" expressions. Use targets only for action recipients
  such as "께/한테/에게/보고/전화/전달/문의/확인".
- Example: "내일 오전 11시 팀장님 원주세브란스방문" -> schedule_fields.title
  "팀장님 원주세브란스 방문", participants ["팀장님"], targets [].
- For edit, delete, and query intents, use target_event_hint and
  requested_changes to identify what should be acted on.
- Use choose when the text is too ambiguous to decide between adding a schedule
  and querying schedules, such as a bare "조회" command.
- Keep uncertain_fields focused on what still needs confirmation.
''';
