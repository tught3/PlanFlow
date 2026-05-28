import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/voice_correction_rule.dart';
import 'package:planflow/data/repositories/voice_correction_rule_repository.dart';

void main() {
  group('VoiceCorrectionRuleRepository', () {
    test('increments an existing personal rule instead of duplicating it',
        () async {
      final gateway = _FakeVoiceCorrectionRuleGateway(
        personalRows: [
          _row(
            id: 'rule-1',
            userId: 'user-1',
            fromText: '조사신청',
            toText: '경조사 신청',
            confidenceCount: 1,
          ),
        ],
      );
      final repository = SupabaseVoiceCorrectionRuleRepository(
        gateway: gateway,
      );

      await repository.recordPersonalRule(
        VoiceCorrectionRule(
          userId: 'user-1',
          stage: VoiceCorrectionStage.stt,
          field: VoiceCorrectionField.transcript,
          fromText: '조사신청',
          toText: '경조사 신청',
        ),
      );

      expect(gateway.insertedRows, isEmpty);
      expect(gateway.updatedRows.single['confidence_count'], 2);
    });

    test('fetches only enabled personal and trusted common rules', () async {
      final gateway = _FakeVoiceCorrectionRuleGateway(
        personalRows: [
          _row(id: 'enabled', userId: 'user-1', confidenceCount: 2),
          _row(id: 'disabled', userId: 'user-1', enabled: false),
        ],
        commonRows: [
          _commonRow(id: 'trusted', supportCount: 5, confidenceScore: 0.9),
          _commonRow(id: 'weak', supportCount: 2, confidenceScore: 0.9),
        ],
      );
      final repository = SupabaseVoiceCorrectionRuleRepository(
        gateway: gateway,
      );

      final personal = await repository.fetchPersonalRules('user-1');
      final common = await repository.fetchTrustedCommonRules();

      expect(personal.map((rule) => rule.id), ['enabled']);
      expect(common.map((rule) => rule.id), ['trusted']);
    });
  });
}

Map<String, dynamic> _row({
  required String id,
  String userId = 'user-1',
  String stage = 'stt',
  String field = 'transcript',
  String fromText = '조사신청',
  String toText = '경조사 신청',
  String contextBefore = '',
  String contextAfter = '',
  int confidenceCount = 1,
  int rejectCount = 0,
  bool enabled = true,
  bool isSensitive = false,
}) {
  return <String, dynamic>{
    'id': id,
    'user_id': userId,
    'stage': stage,
    'field_name': field,
    'from_text': fromText,
    'to_text': toText,
    'context_before': contextBefore,
    'context_after': contextAfter,
    'confidence_count': confidenceCount,
    'reject_count': rejectCount,
    'enabled': enabled,
    'is_sensitive': isSensitive,
    'created_at': '2026-05-28T00:00:00Z',
    'updated_at': '2026-05-28T00:00:00Z',
  };
}

Map<String, dynamic> _commonRow({
  required String id,
  int supportCount = 5,
  int conflictCount = 0,
  double confidenceScore = 0.9,
}) {
  return <String, dynamic>{
    'id': id,
    'stage': 'stt',
    'field_name': 'transcript',
    'from_text': '조사신청',
    'to_text': '경조사 신청',
    'context_before': '',
    'context_after': '',
    'support_count': supportCount,
    'conflict_count': conflictCount,
    'confidence_score': confidenceScore,
    'enabled': true,
    'created_at': '2026-05-28T00:00:00Z',
    'updated_at': '2026-05-28T00:00:00Z',
  };
}

class _FakeVoiceCorrectionRuleGateway implements VoiceCorrectionRuleGateway {
  _FakeVoiceCorrectionRuleGateway({
    List<Map<String, dynamic>> personalRows = const [],
    List<Map<String, dynamic>> commonRows = const [],
  })  : _personalRows = personalRows.map(Map<String, dynamic>.from).toList(),
        _commonRows = commonRows.map(Map<String, dynamic>.from).toList();

  final List<Map<String, dynamic>> _personalRows;
  final List<Map<String, dynamic>> _commonRows;
  final List<Map<String, dynamic>> insertedRows = [];
  final List<Map<String, dynamic>> updatedRows = [];

  @override
  Future<List<Map<String, dynamic>>> fetchPersonalRules(String userId) async {
    return _personalRows
        .where((row) => row['user_id'] == userId && row['enabled'] == true)
        .map(Map<String, dynamic>.from)
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTrustedCommonRules() async {
    return _commonRows
        .where((row) =>
            row['enabled'] == true &&
            (row['support_count'] as int) >= 5 &&
            (row['conflict_count'] as int) == 0 &&
            (row['confidence_score'] as double) >= 0.85)
        .map(Map<String, dynamic>.from)
        .toList();
  }

  @override
  Future<Map<String, dynamic>?> findPersonalRule(
    Map<String, dynamic> match,
  ) async {
    return _personalRows.cast<Map<String, dynamic>?>().firstWhere(
          (row) =>
              row?['user_id'] == match['user_id'] &&
              row?['stage'] == match['stage'] &&
              row?['field_name'] == match['field_name'] &&
              row?['from_text'] == match['from_text'] &&
              row?['to_text'] == match['to_text'] &&
              row?['context_before'] == match['context_before'] &&
              row?['context_after'] == match['context_after'],
          orElse: () => null,
        );
  }

  @override
  Future<Map<String, dynamic>> insertPersonalRule(
    Map<String, dynamic> payload,
  ) async {
    final row = <String, dynamic>{
      ...payload,
      'id': 'new-${insertedRows.length + 1}',
      'created_at': '2026-05-28T00:00:00Z',
      'updated_at': '2026-05-28T00:00:00Z',
    };
    insertedRows.add(row);
    _personalRows.add(row);
    return row;
  }

  @override
  Future<Map<String, dynamic>> updatePersonalRule(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final index = _personalRows.indexWhere((row) => row['id'] == id);
    final row = <String, dynamic>{
      ..._personalRows[index],
      ...payload,
    };
    _personalRows[index] = row;
    updatedRows.add(row);
    return row;
  }

  @override
  Future<void> deletePersonalRule(String userId, String id) async {}

  @override
  Future<void> deleteAllPersonalRules(String userId) async {}

  @override
  Future<void> disablePersonalRule(String userId, String id) async {}
}
