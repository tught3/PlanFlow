import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:planflow/core/env.dart';
import 'package:planflow/services/gpt_service.dart';
import 'package:planflow/services/voice_text_cleanup_service.dart';

const String _proxyEndpoint =
    'https://xqvvfnvmytjlblcngipn.supabase.co/functions/v1/openai-proxy';

void main() {
  group('GptService', () {
    test('cleans suspicious STT text with AI JSON when confidence is high',
        () async {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final messages = body['messages'] as List<dynamic>;
        expect(
          (messages.first as Map<String, dynamic>)['content'].toString(),
          contains('Korean STT cleanup assistant'),
        );

        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': jsonEncode(<String, dynamic>{
                    'cleaned_text': '내일 서울성남에서 아이스크림 전달일정 변경',
                    'changed': true,
                    'reason': '후보 일정과 맞는 장소명 조사 오류 보정',
                    'confidence': 0.91,
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

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
      );

      final result = await service.cleanupVoiceText(
        '내일 서울에서 성남에서 아이스크림 전달일정 변경',
        context: VoiceTextCleanupContext.edit,
      );

      expect(result.method, VoiceTextCleanupMethod.ai);
      expect(result.cleanedText, '내일 서울성남에서 아이스크림 전달일정 변경');
    });

    test('keeps local cleanup when AI confidence is low', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': jsonEncode(<String, dynamic>{
                    'cleaned_text': '내일 완전히 다른 일정',
                    'changed': true,
                    'reason': 'uncertain',
                    'confidence': 0.4,
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

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
      );

      final result = await service.cleanupVoiceText(
        '내일 서울에서 성남에서 미팅 변경',
        context: VoiceTextCleanupContext.edit,
      );

      expect(result.method, VoiceTextCleanupMethod.none);
      expect(result.cleanedText, '내일 서울에서 성남에서 미팅 변경');
    });

    test('returns fallback data when schedule JSON parsing fails', () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), _proxyEndpoint);
        expect(
          request.headers['authorization'],
          'Bearer ${AppEnv.supabaseAnonKey}',
        );
        expect(request.headers['apikey'], AppEnv.supabaseAnonKey);

        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], 'gpt-4o-mini');

        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': 'not valid json',
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

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
      );

      final result = await service.parseSchedule('meeting tomorrow at 3pm');

      expect(result['parse_failed'], isTrue);
      expect(result['raw_text'], 'meeting tomorrow at 3pm');
      expect(result['title'], 'meeting tomorrow at 3pm');
    });

    test(
        'fallback parsing strips date time noise and preserves explicit memo cues',
        () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': 'not valid json',
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

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => DateTime(2026, 5, 10, 12),
      );

      final result = await service.parseSchedule(
        '내일 오전 9시에 대전출발 메모에 주차장 B2 확인',
      );

      expect(result['parse_failed'], isTrue);
      expect(result['start_at'], '2026-05-11T09:00:00.000');
      expect(result['title'], '대전 출발');
      expect(result['location'], '대전');
      expect(result['memo'], '주차장 B2 확인');
    });

    test(
        'fallback parsing preserves later relative-day content after an earlier time cue',
        () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': 'not valid json',
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

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => DateTime(2026, 5, 18, 9),
      );

      final result = await service.parseSchedule(
        '오늘 오후 2시에 내일팀장님 동행방문하시는지 확인전화하기',
      );

      expect(result['parse_failed'], isTrue);
      expect(result['start_at'], '2026-05-18T14:00:00.000');
      expect(result['title'], startsWith('내일'));
      expect(result['title'], contains('동행방문'));
    });

    test('preserves person words in parsed title and people fields', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': jsonEncode(<String, dynamic>{
                    'title': '원주세브란스 방문',
                    'start_at': '2026-05-20T11:00:00.000',
                    'location': '원주세브란스',
                    'participants': <String>[],
                    'targets': <String>[],
                    'supplies': <String>[],
                    'is_critical': false,
                    'pre_actions': <Map<String, dynamic>>[],
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

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => DateTime(2026, 5, 19, 9),
      );

      final result = await service.parseSchedule(
        '내일 오전 11시 팀장님 원주세브란스방문',
      );

      expect(result['title'], '팀장님 원주세브란스 방문');
      expect(result['participants'], <String>['팀장님']);
      expect(result['targets'], isEmpty);
    });

    test('preserves name-like action target in parsed title and people fields',
        () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': jsonEncode(<String, dynamic>{
                    'title': '강릉아산병원 혼자 올건지 물어보기',
                    'start_at': '2026-05-20T15:00:00.000',
                    'location': '강릉아산병원',
                    'participants': <String>[],
                    'targets': <String>[],
                    'supplies': <String>[],
                    'is_critical': false,
                    'pre_actions': <Map<String, dynamic>>[],
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

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => DateTime(2026, 5, 19, 9),
      );

      final result = await service.parseSchedule(
        '내일 오후3시에 경탁이 전화해서 모래 강릉아산병원 혼자 올건지 물어보기',
      );

      expect(result['title'], contains('경탁이'));
      expect(result['title'], contains('모레'));
      expect(result['targets'], <String>['경탁이']);
      expect(result['participants'], isEmpty);
    });

    test('fallback parsing treats text after leading time cue as title content',
        () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': 'not valid json',
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

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => DateTime(2026, 5, 18, 9),
      );

      final result = await service.parseSchedule(
        '오늘 4시에 팀장님 내일 오시는지 확인전화하기',
      );

      expect(result['parse_failed'], isTrue);
      expect(result['start_at'], '2026-05-18T16:00:00.000');
      expect(result['title'], '팀장님 내일 오시는지 확인전화하기');
    });

    test('fallback parsing keeps monthly recurrence and removes location noise',
        () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': 'not valid json',
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

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => DateTime(2026, 5, 10, 12),
      );

      final result = await service.parseSchedule('우리회사에서 매월 월례 조회');

      expect(result['parse_failed'], isTrue);
      expect(result['title'], '월례 조회');
      expect(result['location'], '우리회사');
      expect(result['recurrence_rule'], 'FREQ=MONTHLY');
      expect(result['memo'], isNull);
    });

    test('infers a Korean relative start time when JSON omits start_at',
        () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': 'not valid json',
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

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
      );

      final result = await service.parseSchedule('내일 오전 11시 공임나라');
      final parsedStartAt = DateTime.parse(result['start_at'] as String);
      final now = DateTime.now();
      final tomorrow =
          DateTime(now.year, now.month, now.day).add(const Duration(days: 1));

      expect(parsedStartAt.year, tomorrow.year);
      expect(parsedStartAt.month, tomorrow.month);
      expect(parsedStartAt.day, tomorrow.day);
      expect(parsedStartAt.hour, 11);
      expect(parsedStartAt.minute, 0);
    });

    test('infers short relative minute offsets from Korean voice text',
        () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': 'not valid json',
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

      final now = DateTime(2026, 5, 6, 23, 0);
      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => now,
      );

      final result = await service.parseSchedule('3분 뒤에 누구한테 연락하기');
      final parsedStartAt = DateTime.parse(result['start_at'] as String);

      expect(parsedStartAt, now.add(const Duration(minutes: 3)));
    });

    test('infers relative hour offsets from Korean voice text', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': jsonEncode(<String, dynamic>{
                    'title': '원주로 출발',
                    'start_at': null,
                    'end_at': null,
                    'supplies': <String>[],
                    'is_critical': false,
                    'pre_actions': <Map<String, dynamic>>[],
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

      final now = DateTime(2026, 5, 7, 9, 30);
      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => now,
      );

      final result = await service.parseSchedule('1시간뒤 원주로 출발');
      final parsedStartAt = DateTime.parse(result['start_at'] as String);

      expect(parsedStartAt, now.add(const Duration(hours: 1)));
    });

    test('public local inference handles relative hour offsets', () {
      final now = DateTime(2026, 5, 7, 9, 30);
      final service = GptService(
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => now,
      );

      expect(
        service.inferStartAtFromRawText('1시간뒤 원주로 출발'),
        now.add(const Duration(hours: 1)),
      );
    });

    test('public local inference handles relative month offsets as date hints',
        () {
      final now = DateTime(2026, 5, 18, 14, 20);
      final service = GptService(
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => now,
      );

      expect(
        service.inferStartAtFromRawText('지금으로부터 3달뒤 부터 3개월마다 반복알람'),
        DateTime(2026, 8, 18, 9),
      );
    });

    test('public local inference handles natural Korean half-hour words', () {
      final now = DateTime(2026, 5, 7, 9, 30);
      final service = GptService(
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => now,
      );

      expect(
        service.inferStartAtFromRawText('내일 열두시반 병원'),
        DateTime(2026, 5, 8, 12, 30),
      );
      expect(
        service.inferStartAtFromRawText('내일 오후 두시 반 미팅'),
        DateTime(2026, 5, 8, 14, 30),
      );
      expect(
        service.inferStartAtFromRawText('내일 저녁 일곱시 삼십분 약속'),
        DateTime(2026, 5, 8, 19, 30),
      );
    });

    test('locally infers all-day, multi-day, category, and recurrence hints',
        () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': 'not valid json',
                },
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => DateTime(2026, 5, 1, 9),
      );

      final allDay = await service.parseSchedule('5월 10일 하루종일 휴가');
      expect(allDay['is_all_day'], isTrue);
      expect(allDay['is_multi_day'], isFalse);
      expect(allDay['category'], '개인');

      final multiDay = await service.parseSchedule('5월 1일부터 3일까지 제주 여행');
      expect(multiDay['is_multi_day'], isTrue);
      expect(multiDay['is_all_day'], isTrue);

      final health = await service.parseSchedule('병원 진료');
      expect(health['category'], '건강');

      final education = await service.parseSchedule('세미나 참석');
      expect(education['category'], '교육');

      final weekly = await service.parseSchedule('매주 화요일 팀 미팅');
      expect(weekly['recurrence_rule'], 'FREQ=WEEKLY;BYDAY=TU');
      expect(weekly['category'], '업무');

      final biWeekly = await service.parseSchedule('격주 금요일 영업 미팅');
      expect(biWeekly['recurrence_rule'], 'FREQ=WEEKLY;INTERVAL=2;BYDAY=FR');

      final monthly = await service.parseSchedule('매월 첫 번째 월요일 월간 보고');
      expect(monthly['recurrence_rule'], 'FREQ=MONTHLY;BYDAY=1MO');
    });

    test('local date range overrides incomplete GPT schedule fields', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': jsonEncode(<String, dynamic>{
                    'title': '부터 까지 원주집 임대',
                    'start_at': '2026-05-26T09:00:00.000',
                    'end_at': '2026-05-26T10:00:00.000',
                    'is_all_day': false,
                    'is_multi_day': false,
                    'category': '개인',
                    'supplies': <String>[],
                    'pre_actions': <Map<String, dynamic>>[],
                  }),
                },
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => DateTime(2026, 5, 23, 12),
      );

      final result = await service.parseSchedule('5월 26일부터 6월 1일까지 원주집 임대');

      expect(result['title'], '원주집 임대');
      expect(result['start_at'], DateTime(2026, 5, 26).toIso8601String());
      expect(
        result['end_at'],
        DateTime(2026, 6, 1, 23, 59, 59).toIso8601String(),
      );
      expect(result['is_all_day'], isTrue);
      expect(result['is_multi_day'], isTrue);
    });

    test('preserves person name in delivery title and separates hospital place',
        () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': jsonEncode(<String, dynamic>{
                    'title': '리바로 갖다주기',
                    'location': '원주기독 정형외과 김두섭',
                    'start_at': null,
                    'end_at': null,
                    'recurrence_rule': null,
                    'supplies': <String>[],
                    'is_critical': false,
                    'pre_actions': <Map<String, dynamic>>[],
                  }),
                },
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => DateTime(2026, 5, 18, 14, 20),
      );

      final result = await service.parseSchedule(
        '지금으로부터 3달뒤 부터 3개월마다 반복알람. 내용은 원주기독 정형외과 김두섭 리바로 갖다주기',
      );

      expect(result['title'], '김두섭 리바로 갖다주기');
      expect(result['location'], '원주기독 정형외과');
      expect(result['start_at'], '2026-08-18T09:00:00.000');
      expect(result['recurrence_rule'], 'FREQ=MONTHLY;INTERVAL=3');
      expect(result['memo'], isNull);
      expect(result['supplies'], <String>['리바로']);
    });

    test('explicit Korean time overrides a wrong model-provided current time',
        () async {
      final now = DateTime(2026, 5, 6, 23, 0);
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': jsonEncode(<String, dynamic>{
                    'title': '정장집 방문',
                    'start_at': now.toIso8601String(),
                    'end_at': null,
                    'supplies': <String>[],
                    'is_critical': false,
                    'pre_actions': <Map<String, dynamic>>[],
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

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
        now: () => now,
      );

      final result = await service.parseSchedule('내일 오전 10시에 정장집 방문');
      final parsedStartAt = DateTime.parse(result['start_at'] as String);

      expect(parsedStartAt, DateTime(2026, 5, 7, 10, 0));
    });

    test('uses the morning briefing prompt', () async {
      late Map<String, dynamic> body;

      final client = MockClient((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': 'Good morning.',
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

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
      );

      final briefing = await service.generateMorningBriefing('today schedule');

      expect(briefing, 'Good morning.');
      expect(body['model'], 'gpt-4o-mini');
      expect(
        (body['messages'] as List).first['content'] as String,
        contains('오늘 일정을 시간순으로, 실제 비서가 말하듯'),
      );
      expect(
        (body['messages'] as List).first['content'] as String,
        contains('중요한 일정입니다.'),
      );
    });

    test('uses the evening briefing prompt', () async {
      late Map<String, dynamic> body;

      final client = MockClient((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': 'Good evening.',
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

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
      );

      final briefing = await service.generateEveningBriefing('today schedule');

      expect(briefing, 'Good evening.');
      expect(body['model'], 'gpt-4o-mini');
      expect(
        (body['messages'] as List).first['content'] as String,
        contains('내일 일정을 시간순으로, 실제 비서가 말하듯'),
      );
      expect(
        (body['messages'] as List).first['content'] as String,
        contains('다음 일정은'),
      );
    });

    test('briefing generation exposes OpenAI failure reasons', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{'message': 'rate limited'},
          }),
          429,
          headers: <String, String>{
            'content-type': 'application/json',
          },
        );
      });

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
      );

      await expectLater(
        service.generateEveningBriefing('내일 일정 2개'),
        throwsA(
          isA<GptCompletionException>().having(
            (error) => error.reason,
            'reason',
            'http_429',
          ),
        ),
      );
    });

    test('schedule prompt blocks place-only medical and fasting inference',
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
                    'title': '병원',
                    'start_at': null,
                    'end_at': null,
                    'supplies': <String>[],
                    'is_critical': false,
                    'pre_actions': <Map<String, dynamic>>[],
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

      final service = GptService(
        client: client,
        endpoint: Uri.parse(_proxyEndpoint),
      );

      await service.parseSchedule('내일 오전 10시 병원');

      final prompt = (body['messages'] as List).first['content'] as String;
      expect(prompt, contains('Do not infer medical or fasting pre_actions'));
      expect(prompt, contains('"병원", "병원 방문", "병원 미팅", and "병문안"'));
      expect(prompt, contains('Input: "내일 오전 10시 병원" -> pre_actions: []'));
      expect(prompt, contains('"꽃이나 선물 챙기기"'));
      expect(
        prompt,
        contains('Input: "토요일 병원 병문안" -> include "꽃이나 선물 챙기기"'),
      );
      expect(prompt, contains('Input: "내일 법원" or "내일 학교"'));
    });
  });
}
