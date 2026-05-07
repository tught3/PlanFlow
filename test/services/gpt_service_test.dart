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
        contains('성공적인 하루'),
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
        contains('내일을 위한 전략적 제언'),
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
      expect(prompt, contains('Input: "내일 법원" or "내일 학교"'));
    });
  });
}
