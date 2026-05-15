import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:planflow/services/voice_command_analysis_service.dart';
import 'package:planflow/services/voice_text_cleanup_service.dart';

const String _proxyEndpoint =
    'https://xqvvfnvmytjlblcngipn.supabase.co/functions/v1/openai-proxy';

void main() {
  group('VoiceCommandAnalysisService', () {
    test('uses cache for repeated normalized text and keeps budget low',
        () async {
      var requestCount = 0;
      late Map<String, dynamic> body;

      final client = MockClient((request) async {
        requestCount += 1;
        body = jsonDecode(request.body) as Map<String, dynamic>;

        final messages = body['messages'] as List<dynamic>;
        final systemPrompt =
            (messages.first as Map<String, dynamic>)['content'].toString();
        expect(systemPrompt, contains('normalized_text'));
        expect(systemPrompt, contains('intent'));
        expect(systemPrompt, contains('target_event_hint'));

        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': jsonEncode(<String, dynamic>{
                    'normalized_text': '내일 오전 10시 프로젝트 회의',
                    'intent': 'add',
                    'confidence': 0.91,
                    'uncertain_fields': <String>['location'],
                    'schedule_fields': <String, dynamic>{
                      'title': '프로젝트 회의',
                      'start_at': '2026-05-08T10:00:00.000',
                      'category': '업무',
                      'supplies': <String>[],
                      'pre_actions': <Map<String, dynamic>>[],
                    },
                    'requested_changes': <String>[],
                  }),
                },
              },
            ],
          }),
          200,
          headers: <String, String>{
            'content-type': 'application/json',
          },
        );
      });

      final service = VoiceCommandAnalysisService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => DateTime(2026, 5, 7, 9, 0),
      );
      final budget = VoiceAnalysisRequestBudget(maxAiRequests: 2);

      final first = await service.analyze(
        '내일 오전 10시 프로젝트 회의',
        stage: VoiceCommandAnalysisStage.complete,
        budget: budget,
      );
      final second = await service.analyze(
        '내일 오전 10시 프로젝트 회의!',
        stage: VoiceCommandAnalysisStage.complete,
        budget: budget,
      );

      expect(requestCount, 1);
      expect(body['model'], 'gpt-4o-mini');
      expect(first.method, VoiceCommandAnalysisMethod.ai);
      expect(first.intent, VoiceCommandIntent.add);
      expect(first.normalizedText, '내일 오전 10시 프로젝트 회의');
      expect(first.scheduleFields['title'], '프로젝트 회의');
      expect(first.toParsedScheduleMap()['parse_failed'], isFalse);
      expect(second.method, VoiceCommandAnalysisMethod.cache);
      expect(second.normalizedText, '내일 오전 10시 프로젝트 회의');
      expect(budget.usedAiRequests, 1);
    });

    test('normalizes monthly recurrence, location, and explicit memo cues',
        () async {
      late Map<String, dynamic> body;

      final client = MockClient((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;

        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': jsonEncode(<String, dynamic>{
                    'normalized_text': '우리회사에서 매월 월례 조회 메모에 주차장 B2 확인',
                    'intent': 'add',
                    'confidence': 0.93,
                    'uncertain_fields': <String>['start_at'],
                    'schedule_fields': <String, dynamic>{
                      'title': '우리회사에서 매월 월례 조회',
                      'location': null,
                      'memo': null,
                      'recurrence_rule': null,
                      'supplies': <String>[],
                      'pre_actions': <Map<String, dynamic>>[],
                    },
                    'requested_changes': <String>[],
                  }),
                },
              },
            ],
          }),
          200,
          headers: <String, String>{
            'content-type': 'application/json',
          },
        );
      });

      final service = VoiceCommandAnalysisService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => DateTime(2026, 5, 7, 9, 0),
      );

      final result = await service.analyze(
        '우리회사에서 매월 월례 조회 메모에 주차장 B2 확인',
        stage: VoiceCommandAnalysisStage.complete,
        budget: VoiceAnalysisRequestBudget(maxAiRequests: 2),
      );

      final parsed = result.toParsedScheduleMap();
      expect(body['model'], 'gpt-4o-mini');
      expect(result.method, VoiceCommandAnalysisMethod.ai);
      expect(result.scheduleFields['title'], '월례 조회');
      expect(result.scheduleFields['location'], '우리회사');
      expect(result.scheduleFields['memo'], '주차장 B2 확인');
      expect(result.scheduleFields['recurrence_rule'], 'FREQ=MONTHLY');
      expect(parsed['title'], '월례 조회');
      expect(parsed['location'], '우리회사');
      expect(parsed['memo'], '주차장 B2 확인');
      expect(parsed['recurrence_rule'], 'FREQ=MONTHLY');
    });

    test('falls back to local analysis when the budget is exhausted', () async {
      var requestCount = 0;

      final client = MockClient((request) async {
        requestCount += 1;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': jsonEncode(<String, dynamic>{
                    'normalized_text': '내일 오전 10시 프로젝트 회의',
                    'intent': 'add',
                    'confidence': 0.9,
                    'uncertain_fields': <String>[],
                    'schedule_fields': <String, dynamic>{
                      'title': '프로젝트 회의',
                      'start_at': '2026-05-08T10:00:00.000',
                      'category': '업무',
                      'supplies': <String>[],
                      'pre_actions': <Map<String, dynamic>>[],
                    },
                    'requested_changes': <String>[],
                  }),
                },
              },
            ],
          }),
          200,
          headers: <String, String>{
            'content-type': 'application/json',
          },
        );
      });

      final service = VoiceCommandAnalysisService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => DateTime(2026, 5, 7, 9, 0),
      );
      final budget = VoiceAnalysisRequestBudget(maxAiRequests: 1);

      final first = await service.analyze(
        '내일 오전 10시 프로젝트 회의',
        stage: VoiceCommandAnalysisStage.complete,
        budget: budget,
      );
      final second = await service.analyze(
        '내일 오후 2시 고객 미팅',
        stage: VoiceCommandAnalysisStage.complete,
        budget: budget,
      );

      expect(requestCount, 1);
      expect(first.method, VoiceCommandAnalysisMethod.ai);
      expect(second.method, VoiceCommandAnalysisMethod.local);
      expect(second.normalizedText, '내일 오후 2시 고객 미팅');
      expect(budget.remainingAiRequests, 0);
    });

    test('parses the AI contract for edit-style draft analysis', () async {
      late Map<String, dynamic> body;

      final client = MockClient((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        final messages = body['messages'] as List<dynamic>;
        final systemPrompt =
            (messages.first as Map<String, dynamic>)['content'].toString();
        expect(systemPrompt, contains('normalized_text'));
        expect(systemPrompt, contains('schedule_fields'));
        expect(systemPrompt, contains('target_event_hint'));
        expect(systemPrompt, contains('requested_changes'));

        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': jsonEncode(<String, dynamic>{
                    'normalized_text': '내일 오전 10시 프로젝트 회의 장소 바꿔줘',
                    'intent': 'edit',
                    'confidence': 0.84,
                    'uncertain_fields': <String>['location'],
                    'schedule_fields': <String, dynamic>{
                      'title': '프로젝트 회의',
                      'start_at': '2026-05-08T10:00:00.000',
                      'location': '회의실 B',
                      'category': '업무',
                      'supplies': <String>[],
                      'pre_actions': <Map<String, dynamic>>[],
                    },
                    'target_event_hint': <String, dynamic>{
                      'title': '프로젝트 회의',
                      'location': '회의실 A',
                      'score': 2,
                    },
                    'requested_changes': <String>['location'],
                  }),
                },
              },
            ],
          }),
          200,
          headers: <String, String>{
            'content-type': 'application/json',
          },
        );
      });

      final service = VoiceCommandAnalysisService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => DateTime(2026, 5, 7, 9, 0),
      );

      final result = await service.analyze(
        '내일 오전 10시 프로젝트 회의 장소 바꿔줘',
        stage: VoiceCommandAnalysisStage.complete,
        context: VoiceTextCleanupContext.edit,
        candidates: <VoiceTextCleanupCandidate>[
          const VoiceTextCleanupCandidate(
            title: '프로젝트 회의',
            location: '회의실 A',
          ),
        ],
      );

      final parsed = result.toParsedScheduleMap();
      expect(body['model'], 'gpt-4o-mini');
      expect(result.intent, VoiceCommandIntent.edit);
      expect(result.normalizedText, '내일 오전 10시 프로젝트 회의 장소 바꿔줘');
      expect(result.uncertainFields, contains('location'));
      expect(result.requestedChanges, contains('location'));
      expect(result.targetEventHint?['title'], '프로젝트 회의');
      expect(parsed['voice_intent'], 'edit');
      expect(parsed['requested_changes'], contains('location'));
      expect(parsed['target_event_hint'], isNotNull);
    });

    test('treats 이동 as an edit intent and requested change cue locally',
        () async {
      final service = VoiceCommandAnalysisService(
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => DateTime(2026, 5, 7, 9, 0),
        maxAiRequests: 0,
      );

      final result = await service.analyze(
        '내일 팀장님 동행방문 다음 주 수요일로 이동',
        stage: VoiceCommandAnalysisStage.complete,
        context: VoiceTextCleanupContext.edit,
      );

      expect(result.method, VoiceCommandAnalysisMethod.local);
      expect(result.intent, VoiceCommandIntent.edit);
      expect(result.requestedChanges, contains('start_at'));
      expect(result.normalizedText, contains('이동'));
    });

    test('detects meaningful text changes without punctuation-only churn', () {
      final service = VoiceCommandAnalysisService(
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => DateTime(2026, 5, 7, 9, 0),
      );

      expect(
        service.hasMeaningfulChange(
          '내일 오전 10시 프로젝트 회의',
          '내일 오전 10시 프로젝트 회의!',
        ),
        isFalse,
      );
      expect(
        service.hasMeaningfulChange(
          '내일 오전 10시 프로젝트 회의',
          '내일 오후 2시 고객 미팅',
        ),
        isTrue,
      );
      expect(
        service.shouldRequestAi(
          '회의',
          stage: VoiceCommandAnalysisStage.partial,
        ),
        isFalse,
      );
    });

    test('treats 확인하기로 저장 as add but 일정 확인해줘 as query locally', () async {
      final service = VoiceCommandAnalysisService(
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => DateTime(2026, 5, 7, 9, 0),
        maxAiRequests: 0,
      );

      final saveResult = await service.analyze(
        '내일 오전 원주 세브란스 병원 약재과 방문해서 제 2 세덱스 통과됐는지 확인하기로 저장',
        stage: VoiceCommandAnalysisStage.complete,
      );
      expect(saveResult.method, VoiceCommandAnalysisMethod.local);
      expect(saveResult.intent, VoiceCommandIntent.add);

      final queryResult = await service.analyze(
        '오늘 일정 확인해줘',
        stage: VoiceCommandAnalysisStage.complete,
      );
      expect(queryResult.method, VoiceCommandAnalysisMethod.local);
      expect(queryResult.intent, VoiceCommandIntent.query);

      final savedQueryResult = await service.analyze(
        '저장된 일정 보여줘',
        stage: VoiceCommandAnalysisStage.complete,
      );
      expect(savedQueryResult.method, VoiceCommandAnalysisMethod.local);
      expect(savedQueryResult.intent, VoiceCommandIntent.query);

      final ambiguousLookupResult = await service.analyze(
        '일정 조회',
        stage: VoiceCommandAnalysisStage.complete,
      );
      expect(ambiguousLookupResult.method, VoiceCommandAnalysisMethod.local);
      expect(ambiguousLookupResult.intent, VoiceCommandIntent.choose);
    });
  });
}
