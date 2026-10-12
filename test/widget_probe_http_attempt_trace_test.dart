import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/widget_probe_http_attempt_trace.dart';

void main() {
  test('query credentials and fragment not retained; body has no input', () {
    final trace = WidgetProbeHttpAttemptTrace();
    trace.record(
        method: 'POST',
        uri: Uri.parse(
            'https://dummy.invalid/auth/v1/token?fixture_query=synthetic_query_marker#fixture_fragment_marker'));
    final receipt = trace.records.single;
    expect(receipt.pathClass, '/auth/v1/token');
    expect(receipt.hostClass, 'qa-invalid');
    expect(receipt.toString(), isNot(contains('synthetic_query_marker')));
    expect(receipt.toString(), isNot(contains('fixture_fragment_marker')));
    expect(receipt.toString(), isNot(contains('dummy.invalid')));
  });
  test('known static resource is classified only at exact path', () {
    final trace = WidgetProbeHttpAttemptTrace();
    trace.record(
        method: 'GET',
        uri: Uri.parse('https://dummy.invalid/rest/v1/group_events'));
    expect(trace.records.single.pathClass, '/rest/v1/group_events');
    final withSuffix = WidgetProbeHttpAttemptTrace();
    withSuffix.record(
        method: 'GET',
        uri: Uri.parse(
            'https://dummy.invalid/rest/v1/group_events/550e8400-e29b-41d4-a716-446655440000'));
    expect(withSuffix.records.single.pathClass, 'other-redacted');
    expect(withSuffix.records.single.toString(), isNot(contains('550e8400')));
  });
  test('known group resources use fixed descriptors only', () {
    const expected = <String, String>{
      '/rest/v1/group_event_comments': '/rest/v1/group_event_comments',
      '/rest/v1/groups': '/rest/v1/groups',
      '/rest/v1/group_members': '/rest/v1/group_members',
    };
    for (final entry in expected.entries) {
      final trace = WidgetProbeHttpAttemptTrace();
      trace.record(
          method: 'GET', uri: Uri.parse('https://dummy.invalid${entry.key}'));
      expect(trace.records.single.pathClass, entry.value);
    }
  });
  test('unknown and dynamic resource paths stay redacted', () {
    for (final path in [
      '/unknown/private',
      '/rest/v1/550e8400',
      '/rest/v1/UPPER',
      '/rest/v1/private_user_name',
      '/rest/v1/arbitrary_unknown',
      '/rest/v1/group_events/extra',
      '/rest/v1/rpc/dynamic_function',
      '/rest/v1/%2Fgroup_events',
      '/auth/v1/token/extra',
      '/auth/v1/tokenized',
      '/auth/v1/private'
    ]) {
      final trace = WidgetProbeHttpAttemptTrace();
      trace.record(method: 'GET', uri: Uri.parse('https://dummy.invalid$path'));
      expect(trace.records.single.pathClass, 'other-redacted');
    }
  });
  test('method rejects lowercase payload and oversized values', () {
    final trace = WidgetProbeHttpAttemptTrace();
    for (final method in [
      'get',
      'GET secret',
      'TRACE',
      'CONNECT',
      'A' * 17,
      ''
    ]) {
      trace.record(method: method, uri: Uri.parse('https://dummy.invalid/'));
    }
    expect(trace.records.every((record) => record.method == 'other-redacted'),
        isTrue);
  });
  test('ordered legs and immutable snapshots measure deltas', () {
    final trace = WidgetProbeHttpAttemptTrace();
    final before = trace.snapshot();
    for (final leg in WidgetProbeHttpLeg.values) {
      trace.leg = leg;
      trace.record(method: 'GET', uri: Uri.parse('https://dummy.invalid/'));
    }
    expect(trace.snapshot().deltaFrom(before), 6);
    expect(before.total, 0);
    expect(
        trace.records.map((record) => record.leg), WidgetProbeHttpLeg.values);
    expect(trace.records.map((record) => record.ordinal), [1, 2, 3, 4, 5, 6]);
    expect(() => trace.records.clear(), throwsUnsupportedError);
  });
  test('receipt cap never resets or conceals unbounded total', () {
    final trace = WidgetProbeHttpAttemptTrace();
    for (var i = 0; i < 21; i++) {
      trace.record(method: 'GET', uri: Uri.parse('https://dummy.invalid/'));
    }
    expect(trace.total, 21);
    expect(trace.records.length, 20);
    expect(trace.records.last.ordinal, 20);
    final before = trace.snapshot();
    trace.record(method: 'GET', uri: Uri.parse('https://dummy.invalid/'));
    expect(trace.snapshot().deltaFrom(before), 1);
    expect(trace.total, isNot(0));
  });
}
