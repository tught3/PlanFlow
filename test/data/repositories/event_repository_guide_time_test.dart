import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  for (final rowCount in [0, 1, 2]) {
    test('guided time write checks the range and handles $rowCount rows',
        () async {
      final original = EventModel(
        id: 'saved-event',
        userId: 'qa-user',
        title: '일정',
        startAt: DateTime.utc(2026, 11, 15, 5),
        endAt: rowCount == 0 ? null : DateTime.utc(2026, 11, 15, 6),
      );
      final start = DateTime.utc(2026, 11, 15, 8);
      final end = DateTime.utc(2026, 11, 15, 9);
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://example.invalid',
        'fixture',
        httpClient: MockClient((request) async {
          requests.add(request);
          final row = {
            'id': original.id,
            'user_id': original.userId,
            'title': '다른 편집에서 변경된 제목',
            'memo': '다른 편집에서 변경된 메모',
            'start_at': start.toIso8601String(),
            'end_at': end.toIso8601String(),
          };
          return http.Response(
            jsonEncode(List.filled(rowCount, row)),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final expiry =
          DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
              1000;
      final payload = base64Url
          .encode(utf8.encode(jsonEncode({'exp': expiry})))
          .replaceAll('=', '');
      await client.auth.recoverSession(jsonEncode({
        'access_token': 'eyJhbGciOiJub25lIn0.$payload.fixture',
        'refresh_token': 'local-fixture',
        'token_type': 'bearer',
        'expires_in': 86400,
        'expires_at': expiry,
        'user': {
          'id': original.userId,
          'aud': 'authenticated',
          'role': 'authenticated',
          'app_metadata': {},
          'user_metadata': {},
          'created_at': '2026-01-01T00:00:00Z',
        },
      }));

      final update =
          SupabaseEventRepository(client: client).updateEventTimeIfUnchanged(
        original: original,
        startAt: start,
        endAt: end,
      );
      EventModel? saved;
      if (rowCount > 1) {
        await expectLater(update, throwsStateError);
      } else {
        saved = await update;
      }

      final request = requests.single;
      expect(request.method, 'PATCH');
      expect(request.url.path, '/rest/v1/events');
      expect(request.headers['accept'] ?? '',
          isNot(contains('application/vnd.pgrst.object+json')));
      expect(jsonDecode(request.body), {
        'start_at': start.toIso8601String(),
        'end_at': end.toIso8601String(),
      });
      final filters = request.url.queryParameters;
      expect(filters, containsPair('id', 'eq.saved-event'));
      expect(filters, containsPair('user_id', 'eq.qa-user'));
      expect(
          filters,
          containsPair(
              'start_at', 'eq.${original.startAt!.toIso8601String()}'));
      expect(
          filters,
          containsPair(
              'end_at',
              rowCount > 0
                  ? 'eq.${original.endAt!.toIso8601String()}'
                  : 'is.null'));
      expect(filters, containsPair('recurrence_rule', 'is.null'));
      expect(filters, containsPair('is_multi_day', 'eq.false'));
      if (rowCount == 1) {
        expect(saved?.startAt, start);
        expect(saved?.endAt, end);
        expect(saved?.title, '다른 편집에서 변경된 제목');
        expect(saved?.memo, '다른 편집에서 변경된 메모');
      } else if (rowCount == 0) {
        expect(saved, isNull);
      }
    });
  }

  test('guide eligibility reads require the full schema without fallback',
      () async {
    final requests = <http.Request>[];
    final row = {
      'id': 'saved-event',
      'user_id': 'qa-user',
      'title': '일정',
      'start_at':
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true).toIso8601String(),
    };
    final client = SupabaseClient(
      'https://example.invalid',
      'fixture',
      httpClient: MockClient((request) async {
        requests.add(request);
        final projection = request.url.queryParameters['select']!.split(',');
        final fullSchema = projection.contains('group_event_id');
        return http.Response(
          jsonEncode(fullSchema
              ? {
                  'code': '42703',
                  'message': 'column events.group_event_id does not exist',
                }
              : [row]),
          fullSchema ? 400 : 200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    addTearDown(client.dispose);
    final repository = SupabaseEventRepository(client: client);

    await expectLater(
      repository.fetchEvent('saved-event',
          userId: 'qa-user', requireGuideEligibility: true),
      throwsA(isA<PostgrestException>()),
    );
    final strictRequest = requests.single;
    expect(strictRequest.method, 'GET');
    expect(strictRequest.url.path, '/rest/v1/events');
    final strictQuery = strictRequest.url.queryParameters;
    expect(
        strictQuery['select']!.split(','),
        containsAll([
          'group_event_id',
          'parent_event_id',
          'recurrence_rule',
          'external_id',
          'source',
        ]));
    expect(strictQuery, containsPair('id', 'eq.saved-event'));
    expect(strictQuery, containsPair('user_id', 'eq.qa-user'));
    for (final field in [
      'group_event_id',
      'parent_event_id',
      'recurrence_rule',
      'external_id',
    ]) {
      expect(strictQuery, containsPair(field, 'is.null'));
    }
    expect(strictQuery['source'],
        allOf(startsWith('in.'), contains('manual'), contains('voice')));

    requests.clear();
    final normal =
        await repository.fetchEvent('saved-event', userId: 'qa-user');
    expect(normal?.id, 'saved-event');
    expect(requests, hasLength(2));
    final first = requests.first.url.queryParameters;
    final fallback = requests.last.url.queryParameters;
    expect(first['select']!.split(','), contains('group_event_id'));
    expect(fallback['select']!.split(','), isNot(contains('group_event_id')));
    expect(first, isNot(contains('source')));
    expect(fallback, containsPair('user_id', 'eq.qa-user'));
  });
}
