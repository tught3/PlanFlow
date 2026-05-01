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
        contains('morning briefing'),
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
        contains('evening briefing'),
      );
    });
  });
}
