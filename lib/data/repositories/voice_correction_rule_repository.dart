import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/voice_correction_rule.dart';

abstract class VoiceCorrectionRuleRepository {
  const VoiceCorrectionRuleRepository();

  factory VoiceCorrectionRuleRepository.supabase({SupabaseClient? client}) =
      SupabaseVoiceCorrectionRuleRepository;

  Future<List<VoiceCorrectionRule>> fetchPersonalRules(String userId);

  Future<List<VoiceCorrectionRule>> fetchTrustedCommonRules();

  Future<VoiceCorrectionRule> recordPersonalRule(VoiceCorrectionRule rule);

  Future<void> disablePersonalRule(String userId, String id);

  Future<void> deletePersonalRule(String userId, String id);

  Future<void> deleteAllPersonalRules(String userId);
}

abstract class VoiceCorrectionRuleGateway {
  Future<List<Map<String, dynamic>>> fetchPersonalRules(String userId);

  Future<List<Map<String, dynamic>>> fetchTrustedCommonRules();

  Future<Map<String, dynamic>?> findPersonalRule(Map<String, dynamic> match);

  Future<Map<String, dynamic>> insertPersonalRule(Map<String, dynamic> payload);

  Future<Map<String, dynamic>> updatePersonalRule(
    String id,
    Map<String, dynamic> payload,
  );

  Future<void> disablePersonalRule(String userId, String id);

  Future<void> deletePersonalRule(String userId, String id);

  Future<void> deleteAllPersonalRules(String userId);
}

class SupabaseVoiceCorrectionRuleRepository
    extends VoiceCorrectionRuleRepository {
  SupabaseVoiceCorrectionRuleRepository({
    SupabaseClient? client,
    VoiceCorrectionRuleGateway? gateway,
  }) : _gateway = gateway ??
            SupabaseVoiceCorrectionRuleGateway(
              client: client ?? Supabase.instance.client,
            );

  final VoiceCorrectionRuleGateway _gateway;

  @override
  Future<List<VoiceCorrectionRule>> fetchPersonalRules(String userId) async {
    final normalizedUserId = _normalizeUserId(userId);
    final rows = await _gateway.fetchPersonalRules(normalizedUserId);
    return rows.map(VoiceCorrectionRule.fromJson).toList(growable: false);
  }

  @override
  Future<List<VoiceCorrectionRule>> fetchTrustedCommonRules() async {
    final rows = await _gateway.fetchTrustedCommonRules();
    return rows.map(VoiceCorrectionRule.fromJson).toList(growable: false);
  }

  @override
  Future<VoiceCorrectionRule> recordPersonalRule(
    VoiceCorrectionRule rule,
  ) async {
    final userId = _normalizeUserId(rule.userId ?? '');
    final normalizedRule = rule.copyWith(userId: userId);
    final match = _matchPayload(normalizedRule);
    final existing = await _gateway.findPersonalRule(match);
    if (existing == null) {
      final inserted = await _gateway.insertPersonalRule(
        normalizedRule.toJson(includeId: false),
      );
      return VoiceCorrectionRule.fromJson(inserted);
    }

    final id = existing['id']?.toString() ?? '';
    final currentCount = VoiceCorrectionRule.fromJson(existing).confidenceCount;
    final updated = await _gateway.updatePersonalRule(
      id,
      <String, dynamic>{
        'confidence_count': currentCount + 1,
        'enabled': true,
      },
    );
    return VoiceCorrectionRule.fromJson(updated);
  }

  @override
  Future<void> disablePersonalRule(String userId, String id) {
    return _gateway.disablePersonalRule(_normalizeUserId(userId), id);
  }

  @override
  Future<void> deleteAllPersonalRules(String userId) {
    return _gateway.deleteAllPersonalRules(_normalizeUserId(userId));
  }

  @override
  Future<void> deletePersonalRule(String userId, String id) {
    return _gateway.deletePersonalRule(_normalizeUserId(userId), id);
  }

  Map<String, dynamic> _matchPayload(VoiceCorrectionRule rule) {
    return <String, dynamic>{
      'user_id': rule.userId,
      'stage': rule.stage.name,
      'field_name': rule.field.name,
      'from_text': rule.fromText,
      'to_text': rule.toText,
      'context_before': rule.contextBefore,
      'context_after': rule.contextAfter,
    };
  }

  String _normalizeUserId(String userId) {
    final normalized = userId.trim();
    if (normalized.isEmpty) {
      throw StateError('A signed-in user is required for correction learning.');
    }
    return normalized;
  }
}

class SupabaseVoiceCorrectionRuleGateway implements VoiceCorrectionRuleGateway {
  SupabaseVoiceCorrectionRuleGateway({required SupabaseClient client})
      : _client = client;

  static const String personalTable = 'voice_correction_rules';
  static const String commonTable = 'voice_common_correction_rules';
  static const String personalSelect =
      'id, user_id, stage, field_name, from_text, to_text, context_before, context_after, '
      'confidence_count, reject_count, enabled, is_sensitive, created_at, updated_at';
  static const String commonSelect =
      'id, stage, field_name, from_text, to_text, context_before, context_after, '
      'support_count, conflict_count, confidence_score, enabled, created_at, updated_at';

  final SupabaseClient _client;

  @override
  Future<List<Map<String, dynamic>>> fetchPersonalRules(String userId) async {
    final response = await _client
        .from(personalTable)
        .select(personalSelect)
        .eq('user_id', userId)
        .eq('enabled', true)
        .order('confidence_count', ascending: false)
        .limit(200);
    return (response as List)
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTrustedCommonRules() async {
    final response = await _client
        .from(commonTable)
        .select(commonSelect)
        .eq('enabled', true)
        .gte('support_count', 5)
        .eq('conflict_count', 0)
        .gte('confidence_score', 0.85)
        .order('confidence_score', ascending: false)
        .limit(100);
    return (response as List)
        .whereType<Map>()
        .map((row) => _commonRowToRuleRow(Map<String, dynamic>.from(row)))
        .toList(growable: false);
  }

  @override
  Future<Map<String, dynamic>?> findPersonalRule(
    Map<String, dynamic> match,
  ) async {
    final response = await _client
        .from(personalTable)
        .select(personalSelect)
        .eq('user_id', match['user_id'])
        .eq('stage', match['stage'])
        .eq('field_name', match['field_name'])
        .eq('from_text', match['from_text'])
        .eq('to_text', match['to_text'])
        .eq('context_before', match['context_before'])
        .eq('context_after', match['context_after'])
        .maybeSingle();
    return response == null ? null : Map<String, dynamic>.from(response as Map);
  }

  @override
  Future<Map<String, dynamic>> insertPersonalRule(
    Map<String, dynamic> payload,
  ) async {
    final response = await _client
        .from(personalTable)
        .insert(payload)
        .select(personalSelect)
        .single();
    return Map<String, dynamic>.from(response as Map);
  }

  @override
  Future<Map<String, dynamic>> updatePersonalRule(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final response = await _client
        .from(personalTable)
        .update(payload)
        .eq('id', id)
        .select(personalSelect)
        .single();
    return Map<String, dynamic>.from(response as Map);
  }

  @override
  Future<void> deleteAllPersonalRules(String userId) async {
    await _client.from(personalTable).delete().eq('user_id', userId);
  }

  @override
  Future<void> deletePersonalRule(String userId, String id) async {
    await _client
        .from(personalTable)
        .delete()
        .eq('user_id', userId)
        .eq('id', id);
  }

  @override
  Future<void> disablePersonalRule(String userId, String id) async {
    await _client
        .from(personalTable)
        .update(<String, dynamic>{'enabled': false})
        .eq('user_id', userId)
        .eq('id', id);
  }

  Map<String, dynamic> _commonRowToRuleRow(Map<String, dynamic> row) {
    return <String, dynamic>{
      ...row,
      'confidence_count': row['support_count'] ?? 0,
      'reject_count': row['conflict_count'] ?? 0,
      'is_sensitive': false,
    };
  }
}
