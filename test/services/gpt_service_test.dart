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
  });
}
