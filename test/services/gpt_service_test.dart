import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:planflow/services/gpt_service.dart';

void main() {
  group('GptService', () {
    test('returns fallback data when schedule JSON parsing fails', () async {
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://api.openai.com/v1/chat/completions',
        );

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
        apiKey: 'test-key',
      );

      final result = await service.parseSchedule('meeting tomorrow at 3pm');

      expect(result['parse_failed'], isTrue);
      expect(result['raw_text'], 'meeting tomorrow at 3pm');
      expect(result['title'], 'meeting tomorrow at 3pm');
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
        apiKey: 'test-key',
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
        apiKey: 'test-key',
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
        apiKey: 'test-key',
        now: () => now,
      );

      final result = await service.parseSchedule('1시간뒤 원주로 출발');
      final parsedStartAt = DateTime.parse(result['start_at'] as String);

      expect(parsedStartAt, now.add(const Duration(hours: 1)));
    });

    test('public local inference handles relative hour offsets', () {
      final now = DateTime(2026, 5, 7, 9, 30);
      final service = GptService(
        apiKey: 'test-key',
        now: () => now,
      );

      expect(
        service.inferStartAtFromRawText('1시간뒤 원주로 출발'),
        now.add(const Duration(hours: 1)),
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
        apiKey: 'test-key',
        now: () => DateTime(2026, 5, 1, 9),
      );

      final allDay = await service.parseSchedule('5월 10일 하루종일 휴가');
      expect(allDay['is_all_day'], isTrue);
      expect(allDay['is_multi_day'], isFalse);
      expect(allDay['category'], '개인');

      final multiDay = await service.parseSchedule('5월 1일부터 3일까지 제주 여행');
      expect(multiDay['is_multi_day'], isTrue);
      expect(multiDay['is_all_day'], isFalse);

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
        apiKey: 'test-key',
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
        apiKey: 'test-key',
      );

      final briefing = await service.generateMorningBriefing('today schedule');

      expect(briefing, 'Good morning.');
      expect(body['model'], 'gpt-4o-mini');
      expect(
        (body['messages'] as List).first['content'] as String,
        contains('오늘 일정을 시간순'),
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
        apiKey: 'test-key',
      );

      final briefing = await service.generateEveningBriefing('today schedule');

      expect(briefing, 'Good evening.');
      expect(body['model'], 'gpt-4o-mini');
      expect(
        (body['messages'] as List).first['content'] as String,
        contains('내일 일정을 시간순'),
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
        apiKey: 'test-key',
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
        apiKey: 'test-key',
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
