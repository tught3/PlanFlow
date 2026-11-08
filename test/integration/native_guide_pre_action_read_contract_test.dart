import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../integration_test/support/real_ui_guide_native_environment.dart';

// Pure contract tests only: synthetic fixtures, no network, no DB, no device.
//
// The fence under test is the ONE forwardable pre_actions read: the detail
// screen lookup of the event the current run created
// (SmartPreparationAlarmService.listForEvent). The real wire is
//
//   GET /rest/v1/pre_actions
//       ?select=*
//       &event_id=eq.<ledger createdId>
//       &user_id=eq.<verified owner uid>
//       &source=eq.external_preparation
//       &order=notify_at.asc.nullslast
//
// Everything else (other verbs, another event id, an empty id, `or`/`in`
// scopes, duplicated or extra scope parameters, an unverified or foreign
// owner uid) must be rejected.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const uid = '11111111-1111-4111-8111-111111111111';
  const otherUid = '22222222-2222-4222-8222-222222222222';
  const createdId = '3389cdce-c632-42e2-a510-87bccf57711c';
  const otherEventId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

  Uri detailUri({
    String select = '*',
    String eventId = createdId,
    String owner = uid,
    String source = 'external_preparation',
    String? order = 'notify_at.asc.nullslast',
  }) {
    final params = <String, String>{
      'select': select,
      'event_id': 'eq.$eventId',
      'user_id': 'eq.$owner',
      'source': 'eq.$source',
      if (order != null) 'order': order,
    };
    return Uri.parse('https://qa.example/rest/v1/pre_actions')
        .replace(queryParameters: params);
  }

  String? reason({
    String method = 'GET',
    Uri? uri,
    String? eventId = createdId,
    String owner = uid,
    bool verified = true,
  }) =>
      NativeGuideEnvironment.preActionReadReason(
        method: method,
        uri: uri ?? detailUri(),
        uid: owner,
        createdId: eventId,
        verifiedUid: verified,
      );

  group('pre_actions owned detail read is forwardable', () {
    test('accepts the exact repository wire (select=* + notify_at order)', () {
      expect(reason(), isNull);
    });

    test('accepts the same scope without the order parameter', () {
      expect(reason(uri: detailUri(order: null)), isNull);
    });

    test('accepts the narrower event_id projection', () {
      expect(reason(uri: detailUri(select: 'event_id')), isNull);
    });

    test('accepts the order without the nulls-last suffix', () {
      expect(reason(uri: detailUri(order: 'notify_at.asc')), isNull);
    });
  });

  group('pre_actions read rejects every unbound shape', () {
    test('rejects writes', () {
      expect(reason(method: 'POST'), isNotNull);
      expect(reason(method: 'PATCH'), isNotNull);
      expect(reason(method: 'DELETE'), isNotNull);
    });

    test('rejects an absent or empty created event id', () {
      expect(reason(eventId: null), isNotNull);
      expect(reason(eventId: ''), isNotNull);
    });

    test('rejects an unverified owner uid', () {
      expect(reason(verified: false), isNotNull);
    });

    test('rejects a foreign owner uid', () {
      expect(reason(uri: detailUri(owner: otherUid)), isNotNull);
    });

    test('rejects another event id', () {
      expect(reason(uri: detailUri(eventId: otherEventId)), isNotNull);
    });

    test('rejects or/in scopes', () {
      expect(
          reason(uri: detailUri().replace(queryParameters: {
            ...detailUri().queryParameters,
            'or': '(event_id.eq.$createdId)',
          })),
          isNotNull);
      expect(
          reason(uri: detailUri().replace(queryParameters: {
            ...detailUri().queryParameters,
            'event_id': 'in.($createdId)',
          })),
          isNotNull);
    });

    test('rejects a duplicated scope parameter', () {
      final uri = Uri.parse('https://qa.example/rest/v1/pre_actions'
          '?select=*&event_id=eq.$createdId&event_id=eq.$createdId'
          '&user_id=eq.$uid&source=eq.external_preparation');
      expect(reason(uri: uri), isNotNull);
    });

    test('rejects extra scope parameters', () {
      expect(
          reason(uri: detailUri().replace(queryParameters: {
            ...detailUri().queryParameters,
            'enabled': 'eq.true',
          })),
          isNotNull);
    });

    test('rejects a missing scope parameter', () {
      final params = Map<String, String>.from(detailUri().queryParameters)
        ..remove('user_id');
      expect(reason(uri: detailUri().replace(queryParameters: params)),
          isNotNull);
    });

    test('rejects a foreign source scope', () {
      expect(reason(uri: detailUri(source: 'manual')), isNotNull);
    });

    test('rejects an unknown projection', () {
      expect(reason(uri: detailUri(select: 'title,notify_at')), isNotNull);
    });

    test('rejects an unknown order', () {
      expect(reason(uri: detailUri(order: 'notify_at.desc')), isNotNull);
    });

    test('rejection reasons never embed a request value', () {
      final text = reason(uri: detailUri(owner: otherUid)) ?? '';
      expect(text.contains(otherUid), isFalse);
      expect(text.contains(createdId), isFalse);
    });
  });

  group('pre_actions home-screen batch read', () {
    // SmartPreparationAlarmService.listEventIdsWithSmartAlarms sends
    //   select=event_id&user_id=eq.<uid>&source=eq.external_preparation
    //   &event_id=in.(<id list>)
    Uri batchUri({
      String select = 'event_id',
      String owner = uid,
      String source = 'external_preparation',
      String scope = 'in.($createdId)',
    }) =>
        Uri.parse('https://qa.example/rest/v1/pre_actions')
            .replace(queryParameters: {
          'select': select,
          'user_id': 'eq.$owner',
          'source': 'eq.$source',
          'event_id': scope,
        });

    test('the batch read is never forwarded', () {
      expect(reason(uri: batchUri()), isNotNull);
    });

    test('the batch read is classified as optional background', () {
      expect(
          NativeGuideEnvironment.isOptionalBackgroundPreActionRead(
              method: 'GET', uri: batchUri(), uid: uid),
          isTrue);
    });

    test('a batch read with several owned ids stays optional background', () {
      expect(
          NativeGuideEnvironment.isOptionalBackgroundPreActionRead(
              method: 'GET',
              uri: batchUri(scope: 'in.($createdId,$otherEventId)'),
              uid: uid),
          isTrue);
    });

    test('a batch read for a foreign uid is not optional background', () {
      expect(
          NativeGuideEnvironment.isOptionalBackgroundPreActionRead(
              method: 'GET', uri: batchUri(owner: otherUid), uid: uid),
          isFalse);
    });

    test('a batch read with another source is not optional background', () {
      expect(
          NativeGuideEnvironment.isOptionalBackgroundPreActionRead(
              method: 'GET', uri: batchUri(source: 'manual'), uid: uid),
          isFalse);
    });

    test('a batch read with a non-uuid id list is not optional background',
        () {
      expect(
          NativeGuideEnvironment.isOptionalBackgroundPreActionRead(
              method: 'GET', uri: batchUri(scope: 'in.(not-a-uuid)'), uid: uid),
          isFalse);
    });

    test('a batch read with extra keys is not optional background', () {
      final uri = batchUri().replace(queryParameters: {
        ...batchUri().queryParameters,
        'enabled': 'eq.true',
      });
      expect(
          NativeGuideEnvironment.isOptionalBackgroundPreActionRead(
              method: 'GET', uri: uri, uid: uid),
          isFalse);
    });

    test('a write is never optional background', () {
      expect(
          NativeGuideEnvironment.isOptionalBackgroundPreActionRead(
              method: 'POST', uri: batchUri(), uid: uid),
          isFalse);
    });

    test('the owned detail read is not classified as optional background',
        () {
      expect(
          NativeGuideEnvironment.isOptionalBackgroundPreActionRead(
              method: 'GET', uri: detailUri(), uid: uid),
          isFalse);
    });
  });

  group('pre_actions read fence adds no host allowlist', () {
    test('the read scope decision is host agnostic', () {
      // The scope fence says nothing about hosts: the request still has to
      // pass the environment host gate (approved backend host, https:443,
      // no userinfo). An unknown host is never turned into an allowed host
      // by the pre_actions fence.
      final unknownHost = Uri.parse(
          'https://not-the-backend.example/rest/v1/pre_actions'
          '?select=*&event_id=eq.$createdId&user_id=eq.$uid'
          '&source=eq.external_preparation');
      expect(reason(uri: unknownHost), isNull);
      expect(
          NativeGuideEnvironment.isOptionalBackgroundRestGet(
              '/rest/v1/pre_actions', 'GET'),
          isFalse);
    });
  });

  Uri batchUri(String scope) =>
      Uri.parse('https://qa.example/rest/v1/pre_actions')
          .replace(queryParameters: {
        'select': 'event_id',
        'user_id': 'eq.$uid',
        'source': 'eq.external_preparation',
        'event_id': scope,
      });

  bool opt(String scope) =>
      NativeGuideEnvironment.isOptionalBackgroundPreActionRead(
          method: 'GET', uri: batchUri(scope), uid: uid);

  group('postgrest inFilter real wire (SupabaseClient + MockClient, 0 network)',
      () {
    // Proves the wire shape on the REAL serializer path: a SupabaseClient
    // built on a capturing MockClient issues exactly the chain
    // SmartPreparationAlarmService.listEventIdsWithSmartAlarms uses
    // (.select('event_id').eq('user_id', uid).eq('source', ...)
    // .inFilter('event_id', ids)) and the captured Uri must classify as
    // optional background (denied without forwarding, without latching).
    test('single quoted id wire is optional background', () async {
      final transport = _CapturingTransport();
      final client = SupabaseClient('https://qa.example', 'qa-anon-key',
          httpClient: transport);
      await client
          .from('pre_actions')
          .select('event_id')
          .eq('user_id', uid)
          .eq('source', 'external_preparation')
          .inFilter('event_id', [createdId]);
      expect(transport.uris, hasLength(1));
      final captured = transport.uris.single;
      expect(captured.path, '/rest/v1/pre_actions');
      expect(captured.queryParameters.keys.toSet(),
          {'select', 'user_id', 'source', 'event_id'});
      // postgrest 2.7.0 _cleanFilterArray quotes every non-numeric value.
      expect(captured.queryParameters['event_id'], 'in.("$createdId")');
      expect(captured.queryParameters['user_id'], 'eq.$uid');
      expect(captured.queryParameters['source'], 'eq.external_preparation');
      expect(
          NativeGuideEnvironment.isOptionalBackgroundPreActionRead(
              method: 'GET', uri: captured, uid: uid),
          isTrue);
      // The real wire is still never forwarded by the strict detail guard.
      expect(
          NativeGuideEnvironment.preActionReadReason(
              method: 'GET',
              uri: captured,
              uid: uid,
              createdId: createdId,
              verifiedUid: true),
          isNotNull);
    });

    test('multi quoted id wire is optional background', () async {
      final transport = _CapturingTransport();
      final client = SupabaseClient('https://qa.example', 'qa-anon-key',
          httpClient: transport);
      await client
          .from('pre_actions')
          .select('event_id')
          .eq('user_id', uid)
          .eq('source', 'external_preparation')
          .inFilter('event_id', [createdId, otherEventId]);
      final captured = transport.uris.single;
      expect(captured.queryParameters['event_id'],
          'in.("$createdId","$otherEventId")');
      expect(
          NativeGuideEnvironment.isOptionalBackgroundPreActionRead(
              method: 'GET', uri: captured, uid: uid),
          isTrue);
    });
  });

  group('optional batch classification stays fatal off the real shape', () {
    test('a quoted malformed id list is not optional background', () {
      expect(opt('in.("not-a-uuid")'), isFalse);
    });

    test('an embedded-quote token is not optional background', () {
      expect(opt('in.("abc"def")'), isFalse);
      expect(opt('in.("$createdId"extra)'), isFalse);
    });

    test('duplicate ids stay fatal (the real service never dedupes on wire)',
        () {
      expect(opt('in.("$createdId","$createdId")'), isFalse);
      expect(opt('in.($createdId,$createdId)'), isFalse);
    });

    test('an empty id list is not optional background', () {
      expect(opt('in.()'), isFalse);
    });

    test('an over-cap id list is not optional background', () {
      final ids = List.generate(
          51, (i) => 'aaaaaaaa-0000-4000-8000-${i.toString().padLeft(12, '0')}');
      expect(opt('in.(${ids.join(',')})'), isFalse);
      // At the cap itself the distinct owned uuid batch is the real shape.
      expect(opt('in.(${ids.take(50).join(',')})'), isTrue);
    });

    test('an or-scope is not optional background', () {
      expect(opt('or(event_id.eq.$createdId)'), isFalse);
    });

    test('mixed quoted and bare owned ids stay optional background', () {
      expect(opt('in.("$createdId",$otherEventId)'), isTrue);
    });

    test('a quoted-id read for a foreign uid is not optional background', () {
      expect(
          NativeGuideEnvironment.isOptionalBackgroundPreActionRead(
              method: 'GET', uri: batchUri('in.("$createdId")'), uid: otherUid),
          isFalse);
    });
  });

  group('bracket deny diagnostic split', () {
    final approved = Uri.parse('https://approved.example/rest/v1/groups');
    const approvedHost = 'approved.example';

    test('an already-failed run with a clean bracket is not a host mismatch',
        () {
      expect(
          NativeGuideEnvironment.bracketDenyReason(
              alreadyFailed: true, uri: approved, approvedHost: approvedHost),
          'already failed');
    });

    test('a real bracket mismatch stays host mismatch', () {
      expect(
          NativeGuideEnvironment.bracketDenyReason(
              alreadyFailed: false,
              uri: Uri.parse('https://other.example/rest/v1/groups'),
              approvedHost: approvedHost),
          'host mismatch');
      expect(
          NativeGuideEnvironment.bracketDenyReason(
              alreadyFailed: false,
              uri: Uri.parse('http://approved.example/rest/v1/groups'),
              approvedHost: approvedHost),
          'host mismatch');
      expect(
          NativeGuideEnvironment.bracketDenyReason(
              alreadyFailed: false,
              uri: Uri.parse('https://approved.example:8443/rest/v1/groups'),
              approvedHost: approvedHost),
          'host mismatch');
      expect(
          NativeGuideEnvironment.bracketDenyReason(
              alreadyFailed: false,
              uri: Uri.parse('https://user@approved.example/rest/v1/groups'),
              approvedHost: approvedHost),
          'host mismatch');
      expect(
          NativeGuideEnvironment.bracketDenyReason(
              alreadyFailed: true,
              uri: Uri.parse('https://other.example/rest/v1/groups'),
              approvedHost: approvedHost),
          'host mismatch');
    });
  });
}

class _CapturingTransport extends http.BaseClient {
  final List<Uri> uris = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    uris.add(request.url);
    return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('[]')), 200,
        request: request,
        headers: const {'content-type': 'application/json'});
  }
}
