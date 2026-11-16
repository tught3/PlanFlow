import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _userId = 'user-1';
const _overriddenKey = 'overridden_occurrence_date';
const _deletedKey = 'deleted_occurrence_dates';
const _overridden = '2026-11-11T00:00:00Z';
const _deleted = '2026-11-18T00:00:00Z';
const _weekly = 'FREQ=WEEKLY;BYDAY=TU';

Map<String, dynamic> _row({
  String id = 'event-1',
  Map<String, dynamic> extra = const {},
}) =>
    {
      'id': id,
      'user_id': _userId,
      'title': '회의',
      'start_at': '2026-11-10T00:00:00Z',
      ...extra,
    };

List<String> _columns(http.Request request) =>
    request.url.queryParameters['select']!.split(',');

Map<String, dynamic> _body(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

http.Response _json(http.Request request, Object data, {int status = 200}) =>
    http.Response(
      jsonEncode(data),
      status,
      request: request,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _missingColumn(http.Request request, String column) => _json(
      request,
      {'code': '42703', 'message': 'column events.$column does not exist'},
      status: 400,
    );

Future<EventRepository> _repository(
  Future<http.Response> Function(http.Request) respond,
) async {
  final client = SupabaseClient(
    'https://planflow-events.test.invalid',
    'local-test-key',
    httpClient: MockClient(respond),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  final expiry = DateTime.now().add(const Duration(days: 1));
  final seconds = expiry.millisecondsSinceEpoch ~/ 1000;
  final claims = base64Url
      .encode(utf8.encode(jsonEncode({'exp': seconds})))
      .replaceAll('=', '');
  await client.auth.recoverSession(jsonEncode({
    'access_token': 'eyJhbGciOiJub25lIn0.$claims.test',
    'refresh_token': 'local-fixture',
    'token_type': 'bearer',
    'expires_in': 86400,
    'expires_at': seconds,
    'user': {
      'id': _userId,
      'aud': 'authenticated',
      'app_metadata': {},
      'user_metadata': {},
      'created_at': '2026-01-01T00:00:00Z',
    },
  }));
  return EventRepository.supabase(client: client);
}

void _expectOccurrences(Map<String, dynamic> payload) {
  expect(payload[_overriddenKey], isA<String>());
  expect(payload[_deletedKey], isA<List<dynamic>>());
  expect(
    DateTime.parse(payload[_overriddenKey] as String).toUtc(),
    DateTime.parse(_overridden),
  );
  final dates = payload[_deletedKey] as List<dynamic>;
  expect(
    dates.map((value) => DateTime.parse(value as String).toUtc()),
    [DateTime.parse(_deleted)],
  );
}

void main() {
  group('collectEventPages', () {
    for (final finalPageLength in [0, 37]) {
      test('stops on a page with $finalPageLength rows', () async {
        final ranges = <(int, int)>[];
        final lengths = finalPageLength == 0 ? [1000, 0] : [1000, 1000, 37];
        final events = await collectEventPages((from, to) async {
          final length = lengths[ranges.length];
          ranges.add((from, to));
          return List.generate(length, (index) => from + index);
        });

        expect(events,
            hasLength(lengths.fold<int>(0, (sum, length) => sum + length)));
        expect(ranges, [
          for (var i = 0; i < lengths.length; i++) (i * 1000, i * 1000 + 999),
        ]);
      });
    }

    test('stops at 50 full pages and logs the safety limit once', () async {
      final messages = <String>[];
      final savedDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => messages.add(message!);
      addTearDown(() => debugPrint = savedDebugPrint);

      var requests = 0;
      final events = await collectEventPages((from, to) async {
        expect((from, to), (requests * 1000, requests * 1000 + 999));
        requests++;
        return List.filled(1000, null);
      });

      expect(events, hasLength(50000));
      expect(requests, 50);
      expect(messages, hasLength(1));
      expect(messages.single, contains('50-page safety limit'));
    });
  });

  for (final capacity in [1000, 173]) {
    test('fetchExternalIdsBySource reads beyond server cap $capacity',
        () async {
      final rows = [
        for (var i = 0; i <= 1000; i++)
          {
            'id': 'row-${i.toString().padLeft(4, '0')}',
            'external_id': 'external-${i == 1 ? 0 : i}',
          },
      ];
      final cursors = <String?>[];
      final repository = await _repository((request) async {
        final query = request.url.queryParameters;
        expect(query['user_id'], 'eq.$_userId');
        expect(query['source'], 'eq.naver_caldav');
        expect(query['external_id'], 'not.is.null');
        final cursor = query['id']?.substring(3);
        cursors.add(cursor);
        return _json(
            request,
            rows
                .where(
                    (row) => cursor == null || row['id']!.compareTo(cursor) > 0)
                .take(capacity)
                .toList());
      });
      final ids =
          await repository.fetchExternalIdsBySource(source: ' naver_caldav ');
      expect(ids, hasLength(1000));
      expect(ids, containsAll(['external-0', 'external-1000']));
      expect(cursors, [
        null,
        for (var i = capacity; i < rows.length; i += capacity)
          rows[i - 1]['id'],
        rows.last['id']
      ]);
    });
  }

  test('selects both occurrence columns and retains them after a read/edit',
      () async {
    final row = _row(extra: {
      _overriddenKey: _overridden,
      _deletedKey: [_deleted],
    });
    _expectOccurrences(EventModel.fromJson(row).toUpdateJson());

    final requests = <http.Request>[];
    final repository = await _repository((request) async {
      requests.add(request);
      if (request.method == 'GET') {
        final selected = _columns(request);
        return _json(request, [
          {
            for (final key in row.keys)
              if (selected.contains(key)) key: row[key]
          },
        ]);
      }
      return _json(request, {...row, ..._body(request)});
    });

    final loaded = (await repository.listEvents()).single;
    expect(
        _columns(requests.first), containsAll([_overriddenKey, _deletedKey]));
    await repository.updateEvent(loaded.copyWith(title: '회의 변경'));
    _expectOccurrences(_body(requests.last));
  });

  test('missing occurrence column retains recurrence and omits both write keys',
      () async {
    final requests = <http.Request>[];
    final row = _row(extra: {'recurrence_rule': _weekly});
    final repository = await _repository((request) async {
      requests.add(request);
      final selected = _columns(request);
      if (selected.contains(_overriddenKey)) {
        return _missingColumn(request, _overriddenKey);
      }
      if (request.method == 'PATCH') {
        return _json(request, {...row, ..._body(request)});
      }
      return _json(request, [
        {
          for (final key in row.keys)
            if (selected.contains(key)) key: row[key]
        },
      ]);
    });

    final loaded = (await repository.listEvents()).single;
    expect(requests, hasLength(2));
    expect(
        _columns(requests.first), containsAll([_overriddenKey, _deletedKey]));
    expect(_columns(requests[1]), contains('recurrence_rule'));
    expect(_columns(requests[1]), isNot(contains(_deletedKey)));
    expect(loaded.recurrenceRule, _weekly);
    await repository.updateEvent(loaded.copyWith(
      overriddenOccurrenceDate: DateTime.parse(_overridden),
      deletedOccurrenceDates: [DateTime.parse(_deleted)],
    ));
    expect(requests, hasLength(3));
    expect(_body(requests.last), isNot(contains(_overriddenKey)));
    expect(_body(requests.last), isNot(contains(_deletedKey)));
    expect(_body(requests.last)['recurrence_rule'], _weekly);
  });

  test('legacy write fallback strips both occurrence keys after three stages',
      () async {
    final requests = <http.Request>[];
    final repository = await _repository((request) async {
      requests.add(request);
      final selected = _columns(request);
      if (selected.contains(_overriddenKey)) {
        return _missingColumn(request, _overriddenKey);
      }
      if (selected.contains('recurrence_rule')) {
        return _missingColumn(request, 'recurrence_rule');
      }
      return _json(request, {..._row(), ..._body(request)});
    });

    await repository.upsertEvent(EventModel.fromJson(_row(extra: {
      _overriddenKey: _overridden,
      _deletedKey: [_deleted],
    })));
    expect(requests, hasLength(3));
    expect(_body(requests.first), contains(_overriddenKey));
    expect(_body(requests.first), contains(_deletedKey));
    for (final request in requests.skip(1)) {
      expect(_body(request), isNot(contains(_overriddenKey)));
      expect(_body(request), isNot(contains(_deletedKey)));
    }
    expect(_body(requests.last), isNot(contains('recurrence_rule')));
  });

  test('external upsert clears incoming nulls and keeps local occurrence data',
      () async {
    final row = _row(extra: {
      'group_event_id': 'g1',
      'use_strong_alarm': true,
      'external_id': 'ext-1',
      'external_calendar_id': 'cal-1',
      'source': 'naver_caldav',
      'end_at': '2026-11-10T01:00:00Z',
      'memo': 'old memo',
      'location': 'old location',
      'location_lat': 37.5,
      'location_lng': 127.0,
      'recurrence_rule': _weekly,
      'parent_event_id': 'old-parent',
      _overriddenKey: _overridden,
      _deletedKey: [_deleted],
    });
    Map<String, dynamic>? written;
    final repository = await _repository((request) async {
      if (request.method == 'GET') return _json(request, [row]);
      final body = written = _body(request);
      return _json(request, {...row, ...body});
    });
    final result = await repository.upsertEventBySourceExternalId(
      EventModel(
        id: 'incoming-id',
        userId: _userId,
        title: '새 회의',
        startAt: DateTime.utc(2026, 11, 10),
        source: 'naver_caldav',
        externalId: 'ext-1',
      ),
    );

    expect(result.title, '새 회의');
    expect(result.groupEventId, 'g1');
    expect(result.useStrongAlarm, isTrue);
    for (final key in [
      'end_at',
      'memo',
      'location',
      'location_lat',
      'location_lng',
      'recurrence_rule',
      'parent_event_id',
      'external_calendar_id',
    ]) {
      expect(written, containsPair(key, null));
    }
    _expectOccurrences(written!);
    expect(result.deletedOccurrenceDates!.single.toUtc(),
        DateTime.parse(_deleted));
    expect(
        result.overriddenOccurrenceDate!.toUtc(), DateTime.parse(_overridden));
  });

  group('external upsert coordinates', () {
    const newLocation = 'different station';
    final stored = _row(extra: {
      'source': 'naver_caldav',
      'external_id': 'external-1',
      'location': 'old station',
      'location_lat': 37.4979,
      'location_lng': 127.0276,
    });

    for (final scenario in [
      (
        name: 'clears the saved pair when the location changes',
        lat: null,
        lng: null,
      ),
      (
        name: 'replaces the saved pair with new coordinates',
        lat: 37.55,
        lng: 126.97,
      ),
    ]) {
      test(scenario.name, () async {
        final writes = <http.Request>[];
        final repository = await _repository((request) async {
          if (request.method == 'GET') return _json(request, [stored]);
          writes.add(request);
          return _json(request, {...stored, ..._body(request)});
        });

        final result = await repository.upsertEventBySourceExternalId(
          EventModel(
            id: '',
            userId: _userId,
            title: '회의',
            startAt: DateTime.parse(stored['start_at'] as String),
            source: 'naver_caldav',
            externalId: 'external-1',
            location: newLocation,
            locationLat: scenario.lat,
            locationLng: scenario.lng,
          ),
        );

        final write = writes.single;
        expect(write.method, 'PATCH');
        expect(write.url.queryParameters['id'], 'eq.event-1');
        final payload = _body(write);
        expect(payload, containsPair('location', newLocation));
        expect(payload, containsPair('location_lat', scenario.lat));
        expect(payload, containsPair('location_lng', scenario.lng));
        expect(result.location, newLocation);
        expect(result.locationLat, scenario.lat);
        expect(result.locationLng, scenario.lng);
      });
    }
  });

  group('metadata attachment', () {
    final currentRow = _row(extra: {
      'supplies': ['노트북'],
      'memo': 'local memo',
      'recurrence_rule': _weekly,
      'category': '업무',
      'source': 'manual',
      'external_etag': 'stored-etag',
      'external_updated_at': '2026-11-09T00:00:00Z',
      'last_synced_at': '2026-11-09T00:00:00Z',
    });
    final incoming = EventModel.fromJson(_row(extra: {
      'source': 'naver_caldav',
      'external_id': ' x ',
      'external_calendar_id': ' c ',
    }));

    for (final adoptSource in [true, false]) {
      test('updates only metadata (adoptIncomingSource=$adoptSource)',
          () async {
        final requests = <http.Request>[];
        final repository = await _repository((request) async {
          requests.add(request);
          return _json(request, {...currentRow, ..._body(request)});
        });
        final existing =
            EventModel.fromJson(currentRow).copyWith(memo: 'stale memo');
        final attach = repository.attachExternalSyncMetadataIfCompatible;
        final result = adoptSource
            ? await attach(existing: existing, incoming: incoming)
            : await attach(
                existing: existing,
                incoming: incoming,
                adoptIncomingSource: false,
              );

        expect(requests, hasLength(1));
        final request = requests.single;
        expect(request.method, 'PATCH');
        expect(request.url.queryParameters['id'], 'eq.event-1');
        expect(request.url.queryParameters['user_id'], 'eq.$_userId');
        final payload = _body(request);
        expect(
            payload.keys,
            unorderedEquals([
              'external_id',
              'external_calendar_id',
              if (adoptSource) 'last_synced_at',
              if (adoptSource) 'source',
            ]));
        expect(payload['external_id'], 'x');
        expect(payload['external_calendar_id'], 'c');
        expect(result!.memo, 'local memo');
        expect(result.supplies, ['노트북']);
        expect(result.recurrenceRule, _weekly);
        expect(result.category, '업무');
        expect(result.source, adoptSource ? 'naver_caldav' : 'manual');
        expect(result.externalEtag, 'stored-etag');
      });
    }

    test('reflected PlanFlow metadata does not adopt the incoming revision',
        () async {
      Map<String, dynamic>? write;
      final repository = await _repository((request) async {
        final payload = write = _body(request);
        return _json(request, {...currentRow, ...payload});
      });
      final existing = EventModel.fromJson(currentRow);
      final result = await repository.attachExternalSyncMetadataIfCompatible(
        existing: existing,
        incoming: incoming.copyWith(
          externalEtag: 'remote-new-revision',
          externalUpdatedAt: DateTime.utc(2026, 11, 12),
        ),
        adoptIncomingSource: false,
      );
      expect(write, isNot(contains('external_etag')));
      expect(write, isNot(contains('external_updated_at')));
      expect(write, isNot(contains('last_synced_at')));
      expect(result!.externalEtag, existing.externalEtag);
      expect(result.externalUpdatedAt, existing.externalUpdatedAt);
    });

    test('metadata attachment keeps legacy writes limited to supported keys',
        () async {
      final requests = <http.Request>[];
      final repository = await _repository((request) async {
        requests.add(request);
        final payload = _body(request);
        if (_columns(request).contains(_overriddenKey)) {
          return _missingColumn(request, _overriddenKey);
        }
        if (payload.containsKey('external_calendar_id')) {
          return _json(
            request,
            {
              'code': 'PGRST204',
              'message': "Could not find the 'external_calendar_id' column "
                  "of 'events' in the schema cache",
            },
            status: 400,
          );
        }
        return _json(request, {...currentRow, ...payload});
      });

      final result = await repository.attachExternalSyncMetadataIfCompatible(
        existing: EventModel.fromJson(currentRow),
        incoming: incoming.copyWith(
          externalEtag: 'new-etag',
          externalUpdatedAt: DateTime.utc(2026, 11, 12),
        ),
      );

      expect(requests, hasLength(3));
      expect(requests.every((request) => request.method == 'PATCH'), isTrue);
      expect(_columns(requests[1]), isNot(contains(_overriddenKey)));
      expect(_columns(requests.last), isNot(contains('external_calendar_id')));
      expect(
          _body(requests.last), {'external_id': 'x', 'source': 'naver_caldav'});
      expect(result!.externalId, 'x');
      expect(result.source, 'naver_caldav');
      expect(result.memo, 'local memo');
    });

    test('does not write if the existing link is for another calendar',
        () async {
      var calls = 0;
      final repository = await _repository((request) async {
        calls++;
        return _json(request, currentRow);
      });
      final existing = EventModel.fromJson(currentRow)
          .copyWith(externalId: 'old-link', externalCalendarId: 'other-cal');
      expect(
        await repository.attachExternalSyncMetadataIfCompatible(
          existing: existing,
          incoming: incoming,
        ),
        isNull,
      );
      expect(calls, 0);
    });
  });

  test('listEvents orders by ascending start and id with nulls last', () async {
    final requests = <http.Request>[];
    final repository = await _repository((request) async {
      requests.add(request);
      return _json(request, []);
    });

    expect(await repository.listEvents(), isEmpty);
    expect(
      requests.single.url.queryParameters['order'],
      'start_at.asc.nullslast,id.asc.nullslast',
    );
  });

  for (final scenario in [
    (rows: 2037, legacy: false, pages: 3),
    (rows: 1000, legacy: false, pages: 2),
    (rows: 2037, legacy: true, pages: 3),
  ]) {
    test('pages through ${scenario.rows} rows (legacy=${scenario.legacy})',
        () async {
      final ranges = <(int, int)>[];
      final repository = await _repository((request) async {
        if (scenario.legacy && _columns(request).contains('recurrence_rule')) {
          return _missingColumn(request, 'recurrence_rule');
        }
        final query = request.url.queryParameters;
        final offset = int.tryParse(query['offset'] ?? '') ?? 0;
        final size = int.tryParse(query['limit'] ?? '') ?? 1000;
        expect(
            query['order']!.split(',').map((entry) => entry.split('.').first),
            ['start_at', 'id']);
        ranges.add((offset, offset + size - 1));
        final remaining = (scenario.rows - offset).clamp(0, size);
        return _json(
          request,
          List.generate(remaining, (i) => _row(id: 'event-${offset + i}')),
        );
      });
      final events = await repository.listEvents();
      expect(events, hasLength(scenario.rows));
      expect(events.last.id, 'event-${scenario.rows - 1}');
      expect(ranges, [
        for (var i = 0; i < scenario.pages; i++) (i * 1000, i * 1000 + 999),
      ]);
    });
  }
}
