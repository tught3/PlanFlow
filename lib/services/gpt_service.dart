import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/env.dart';

class GptService {
  GptService({
    http.Client? client,
    Uri? endpoint,
    String? apiKey,
  })  : _client = client,
        _endpoint =
            endpoint ?? Uri.parse('https://api.openai.com/v1/chat/completions'),
        _apiKey = apiKey ?? AppEnv.openAiApiKey;

  final http.Client? _client;
  final Uri _endpoint;
  final String _apiKey;

  static const String _model = 'gpt-4o-mini';
  static const Map<String, dynamic> _responseFormat = <String, dynamic>{
    'type': 'json_object',
  };

  Future<Map<String, dynamic>> parseSchedule(String rawText) async {
    final content = await _requestCompletion(
      systemPrompt: _scheduleSystemPrompt,
      userPrompt: rawText,
      responseFormat: _responseFormat,
    );

    final parsed = _decodeJsonMap(content);
    if (parsed == null) {
      return _fallbackSchedule(
        rawText: rawText,
        rawResponse: content,
      );
    }

    return _normalizeSchedule(parsed, rawText);
  }

  Future<String> generateMorningBriefing(String rawText) {
    return generateBriefing(rawText: rawText, isMorning: true);
  }

  Future<String> generateEveningBriefing(String rawText) {
    return generateBriefing(rawText: rawText, isMorning: false);
  }

  Future<String> generateBriefing({
    required String rawText,
    required bool isMorning,
  }) async {
    final content = await _requestCompletion(
      systemPrompt: isMorning ? _morningBriefingPrompt : _eveningBriefingPrompt,
      userPrompt: rawText,
    );

    final briefing = content?.trim();
    if (briefing == null || briefing.isEmpty) {
      return isMorning
          ? 'Unable to load the morning briefing.'
          : 'Unable to load the evening briefing.';
    }

    return briefing;
  }

  Future<String?> _requestCompletion({
    required String systemPrompt,
    required String userPrompt,
    Map<String, dynamic>? responseFormat,
  }) async {
    if (_apiKey.isEmpty) {
      return null;
    }

    final client = _client ?? http.Client();
    try {
      final response = await client.post(
        _endpoint,
        headers: <String, String>{
          'Authorization': 'Bearer $_apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(<String, dynamic>{
          'model': _model,
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

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
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

  Map<String, dynamic> _normalizeSchedule(
    Map<String, dynamic> parsed,
    String rawText,
  ) {
    final normalized = Map<String, dynamic>.from(parsed);
    normalized['parse_failed'] = false;
    normalized.putIfAbsent('raw_text', () => rawText);
    normalized['supplies'] = _normalizeSupplies(normalized['supplies']);
    return normalized;
  }

  Map<String, dynamic> _fallbackSchedule({
    required String rawText,
    String? rawResponse,
  }) {
    return <String, dynamic>{
      'parse_failed': true,
      'raw_text': rawText,
      if (rawResponse != null && rawResponse.isNotEmpty)
        'raw_response': rawResponse,
      'title': rawText.trim(),
      'date': null,
      'start_at': null,
      'end_at': null,
      'location': null,
      'memo': null,
      'supplies': <String>[],
      'is_critical': false,
    };
  }

  List<String> _normalizeSupplies(Object? supplies) {
    if (supplies is List) {
      return supplies
          .whereType<String>()
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }

    if (supplies is String) {
      return supplies
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }

    return <String>[];
  }
}

const String _scheduleSystemPrompt = '''
You are a Korean schedule parser.
Return only a valid JSON object.
Use these keys:
title, date, start_at, end_at, location, memo, supplies, is_critical.
Date should use YYYY-MM-DD when possible.
Time should use HH:mm when possible.
supplies must be an array of strings.
is_critical must be a boolean.
If a field is not known, use null or an empty array.
''';

const String _morningBriefingPrompt = '''
You are writing a short morning briefing in Korean.
Use a warm, concise tone with 2 to 4 sentences.
Summarize the day, highlight urgent items first, and avoid markdown.
''';

const String _eveningBriefingPrompt = '''
You are writing a short evening briefing in Korean.
Use a calm, concise tone with 2 to 4 sentences.
Summarize completed work, mention anything left for tomorrow, and avoid markdown.
''';
