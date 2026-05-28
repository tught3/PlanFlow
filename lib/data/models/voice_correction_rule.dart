enum VoiceCorrectionStage {
  stt,
  parse,
}

enum VoiceCorrectionField {
  transcript,
  title,
  location,
  startAt,
  endAt,
  recurrence,
  isCritical,
  supplies,
}

class VoiceCorrectionRule {
  const VoiceCorrectionRule({
    this.id = '',
    this.userId,
    required this.stage,
    required this.field,
    required this.fromText,
    required this.toText,
    this.contextBefore = '',
    this.contextAfter = '',
    this.confidenceCount = 1,
    this.rejectCount = 0,
    this.enabled = true,
    bool? isSensitive,
    this.createdAt,
    this.updatedAt,
  }) : isSensitive = isSensitive ?? field == VoiceCorrectionField.location;

  factory VoiceCorrectionRule.fromJson(Map<String, dynamic> json) {
    return VoiceCorrectionRule(
      id: _stringValue(json['id']),
      userId: _optionalStringValue(json['user_id']),
      stage: voiceCorrectionStageFromValue(json['stage']),
      field: voiceCorrectionFieldFromValue(json['field_name'] ?? json['field']),
      fromText: _stringValue(json['from_text']),
      toText: _stringValue(json['to_text']),
      contextBefore: _stringValue(json['context_before']),
      contextAfter: _stringValue(json['context_after']),
      confidenceCount: _intValue(json['confidence_count'], 1),
      rejectCount: _intValue(json['reject_count'], 0),
      enabled: _boolValue(json['enabled'], true),
      isSensitive: _boolValue(json['is_sensitive'], false),
      createdAt: _dateTimeValue(json['created_at']),
      updatedAt: _dateTimeValue(json['updated_at']),
    );
  }

  final String id;
  final String? userId;
  final VoiceCorrectionStage stage;
  final VoiceCorrectionField field;
  final String fromText;
  final String toText;
  final String contextBefore;
  final String contextAfter;
  final int confidenceCount;
  final int rejectCount;
  final bool enabled;
  final bool isSensitive;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  // Intentionally absent in persisted rules. Tests use these getters to guard
  // against accidentally storing whole user utterances in correction rules.
  String? get rawText => null;
  String? get memoText => null;

  bool get canAutoApply => enabled && confidenceCount >= 2 && rejectCount == 0;

  bool get canContributeToCommon =>
      !isSensitive &&
      field != VoiceCorrectionField.location &&
      field != VoiceCorrectionField.supplies;

  VoiceCorrectionRule copyWith({
    String? id,
    String? userId,
    VoiceCorrectionStage? stage,
    VoiceCorrectionField? field,
    String? fromText,
    String? toText,
    String? contextBefore,
    String? contextAfter,
    int? confidenceCount,
    int? rejectCount,
    bool? enabled,
    bool? isSensitive,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return VoiceCorrectionRule(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      stage: stage ?? this.stage,
      field: field ?? this.field,
      fromText: fromText ?? this.fromText,
      toText: toText ?? this.toText,
      contextBefore: contextBefore ?? this.contextBefore,
      contextAfter: contextAfter ?? this.contextAfter,
      confidenceCount: confidenceCount ?? this.confidenceCount,
      rejectCount: rejectCount ?? this.rejectCount,
      enabled: enabled ?? this.enabled,
      isSensitive: isSensitive ?? this.isSensitive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson({bool includeId = true}) {
    return <String, dynamic>{
      if (includeId && id.trim().isNotEmpty) 'id': id,
      if (userId?.trim().isNotEmpty == true) 'user_id': userId,
      'stage': stage.name,
      'field_name': field.name,
      'from_text': fromText,
      'to_text': toText,
      'context_before': contextBefore,
      'context_after': contextAfter,
      'confidence_count': confidenceCount,
      'reject_count': rejectCount,
      'enabled': enabled,
      'is_sensitive': isSensitive,
    };
  }

  static String _stringValue(Object? value) {
    return value?.toString().trim() ?? '';
  }

  static String? _optionalStringValue(Object? value) {
    final text = _stringValue(value);
    return text.isEmpty ? null : text;
  }

  static int _intValue(Object? value, int fallback) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static bool _boolValue(Object? value, bool fallback) {
    if (value is bool) {
      return value;
    }
    final text = value?.toString().trim().toLowerCase();
    if (text == 'true' || text == '1') {
      return true;
    }
    if (text == 'false' || text == '0') {
      return false;
    }
    return fallback;
  }

  static DateTime? _dateTimeValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is DateTime) {
      return value;
    }
    final text = value.toString();
    return text.isEmpty ? null : DateTime.tryParse(text);
  }
}

VoiceCorrectionStage voiceCorrectionStageFromValue(Object? value) {
  final text = value?.toString().trim();
  return VoiceCorrectionStage.values.firstWhere(
    (stage) => stage.name == text,
    orElse: () => VoiceCorrectionStage.stt,
  );
}

VoiceCorrectionField voiceCorrectionFieldFromValue(Object? value) {
  final text = value?.toString().trim();
  return VoiceCorrectionField.values.firstWhere(
    (field) => field.name == text,
    orElse: () => VoiceCorrectionField.transcript,
  );
}
