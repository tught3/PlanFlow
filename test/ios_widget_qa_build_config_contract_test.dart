import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

const _flag = 'WIDGET_PROBE_VALID_QA_CONFIG';
const _call = 'bash scripts/ios/e2e_xctest_flow.sh';
const _step = 'Run native null-storage probe through bounded XCTest stages';

// Offset-preserving lexical masking, not an AST. URI/string contents are
// never mistaken for comments. Nested Dart block comments are supported.
String _lex(String input, {bool strings = false, bool yaml = false}) {
  final s = input.replaceAll('\r\n', '\n');
  final out = s.split('');
  void blank(int a, int b) {
    for (var k = a; k < b; k++) {
      if (s[k] != '\n') out[k] = ' ';
    }
  }

  var i = 0;
  while (i < s.length) {
    if (s[i] == '"' || s[i] == "'") {
      final q = s[i];
      final start = i++;
      final triple = !yaml && s.startsWith(q * 3, start);
      if (triple) i = start + 3;
      while (i < s.length) {
        if (s[i] == '\\') {
          i += 2;
          continue;
        }
        if (s.startsWith(triple ? q * 3 : q, i)) {
          i += triple ? 3 : 1;
          break;
        }
        i++;
      }
      if (strings) blank(start, i.clamp(0, s.length));
    } else if ((yaml && s[i] == '#') || (!yaml && s.startsWith('//', i))) {
      final start = i;
      while (i < s.length && s[i] != '\n') {
        i++;
      }
      blank(start, i);
    } else if (!yaml && s.startsWith('/*', i)) {
      final start = i;
      i += 2;
      var depth = 1;
      while (i < s.length && depth > 0) {
        if (s.startsWith('/*', i)) {
          depth++;
          i += 2;
        } else if (s.startsWith('*/', i)) {
          depth--;
          i += 2;
        } else {
          i++;
        }
      }
      blank(start, i);
    } else {
      i++;
    }
  }
  return out.join();
}

String _block(String s, int start, [String left = '{', String right = '}']) {
  if (start < 0) return '';
  var depth = 0;
  for (var i = start; i < s.length; i++) {
    if (s[i] == left) depth++;
    if (s[i] == right) {
      depth--;
      if (depth == 0) return s.substring(start + 1, i);
    }
  }
  return '';
}

// Errors expose labels only, never configuration or key values.
List<String> _validate(String script, String workflow, String fixture) {
  final errors = <String>[];
  void require(bool ok, String label) {
    if (!ok) errors.add(label);
  }

  final sh = script
      .replaceAll('\r\n', '\n')
      .replaceAll(RegExp(r'^\s*#.*$', multiLine: true), '');
  final build = RegExp(r"run_bounded APP_BUILD bash -c '([\s\S]*?)\n\s*'")
          .firstMatch(sh)
          ?.group(1) ??
      '';
  final branches = RegExp(
    r'if \[ "\$WIDGET_PROBE_VALID_QA_CONFIG" = "1" \]; then\s*([\s\S]*?)\belse\b([\s\S]*?)\bfi\b',
  ).firstMatch(build);
  require(branches != null, 'shell-actual-if-else');
  require(
      RegExp(r'WIDGET_PROBE_VALID_QA_CONFIG="\$\{WIDGET_PROBE_VALID_QA_CONFIG:-0\}"\s*\\\s*run_bounded APP_BUILD')
          .hasMatch(sh),
      'shell-default-off-bound-to-build');
  bool defines(String branch, String host, String key) {
    final normalized = branch
        .replaceAll(RegExp(r'\\\s*\n'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return normalized ==
        'flutter build ios --config-only --simulator "\$E2E_FLOW_FILE" '
            '--dart-define=E2E_MODE=1 --dart-define=SUPABASE_URL=$host '
            '--dart-define=SUPABASE_ANON_KEY=$key';
  }

  require(
      defines(branches?.group(1) ?? '', 'https://widget-qa.invalid',
          'widget-qa-dummy-key'),
      'shell-enabled-build');
  require(
      defines(branches?.group(2) ?? '', 'https://your-project.supabase.co',
          'your-supabase-anon-key'),
      'shell-ordinary-build');
  require(RegExp(r'flutter build ios').allMatches(build).length == 2,
      'shell-no-extra-build');

  final y = _lex(workflow, yaml: true);
  final steps =
      RegExp(r'^      - name: (.*)$', multiLine: true).allMatches(y).toList();
  final selected = steps.where((m) => m.group(1) == _step).toList();
  var step = '';
  if (selected.length == 1) {
    final n = steps.indexOf(selected.single);
    step = y.substring(selected.single.start,
        n + 1 < steps.length ? steps[n + 1].start : y.length);
  }
  final run =
      RegExp(r'^        run: \|\n((?:          .*\n|\n)*)', multiLine: true)
              .firstMatch(step)
              ?.group(1) ??
          '';
  require(
      selected.length == 1 &&
          RegExp(r'^        id: run_probe$', multiLine: true).hasMatch(step),
      'yaml-native-step-identity');
  require(
      RegExp(r'^          WIDGET_PROBE_VALID_QA_CONFIG=1 bash scripts/ios/e2e_xctest_flow\.sh \\$',
                      multiLine: true)
                  .allMatches(run)
                  .length ==
              1 &&
          RegExp(_flag).allMatches(y).length == 1,
      'yaml-inline-only-single-opt-in');
  require(RegExp(RegExp.escape(_call)).allMatches(run).length == 1,
      'yaml-single-native-call');

  final text = _lex(fixture);
  final code = _lex(fixture, strings: true);
  final start = code.indexOf('(WidgetTester tester) async {');
  final opening = start < 0 ? -1 : code.indexOf('{', start);
  final body = _block(code, opening);
  final bodyText =
      opening < 0 ? '' : text.substring(opening + 1, opening + 1 + body.length);
  require(body.isNotEmpty, 'fixture-test-body');
  final guard = RegExp(r'if\s*\(\s*!AppEnv\.hasValidSupabaseConfig\s*\)\s*\{')
      .firstMatch(body);
  final firstUse =
      RegExp(r'\b(?:_ensurePlaceholderSupabase|AuthProvider|SupabaseClient|Supabase\.initialize)\s*\(')
              .firstMatch(body)
              ?.start ??
          -1;
  // Frozen source uses if/throw, equivalent to a hard boolean expectation.
  require(
      guard != null &&
          RegExp(r'\bthrow\s+StateError\s*\(')
              .hasMatch(_block(body, guard.end - 1)) &&
          firstUse > guard.start,
      'fixture-config-before-first-sdk-provider');
  final ios = RegExp(r'if\s*\(\s*!Platform\.isIOS\s*\)\s*\{').firstMatch(body);
  final iosBody = ios == null ? '' : _block(body, ios.end - 1);
  require(
      ios != null &&
          ios.start < (guard?.start ?? -1) &&
          RegExp(r'\bmarkTestSkipped\s*\(').hasMatch(iosBody) &&
          RegExp(r'\breturn\s*;').hasMatch(iosBody),
      'fixture-ios-fail-closed-skip');
  final send = RegExp(
          r'Future<http\.StreamedResponse>\s+send\(http\.BaseRequest request\) async\s*\{')
      .firstMatch(code);
  final sendBody = send == null ? '' : _block(code, send.end - 1);
  require(
      RegExp(r'attempts\+\+;').hasMatch(sendBody) &&
          RegExp(r'throw\s+StateError\s*\(').hasMatch(sendBody) &&
          !RegExp(r'\breturn\b|\bsuper\.send\s*\(').hasMatch(sendBody),
      'fixture-no-network-send');
  final counters = RegExp(r'expect\(\s*blockingClient\.attempts,\s*0,')
      .allMatches(body)
      .toList();
  final passes = RegExp(r'\bprint\s*\(').allMatches(body).where((m) {
    final args = _block(body, m.end - 1, '(', ')');
    return bodyText
        .substring(m.end, m.end + args.length)
        .trimLeft()
        .startsWith("'\$_probePassMarker ");
  }).toList();
  final voice =
      RegExp(r'expect\(\s*stubStt\.listenCalls,\s*1,').firstMatch(body);
  final sheet = RegExp(r'expect\(\s*sheetRepo\.listCalls,').firstMatch(body);
  require(
      counters.length == 1 &&
          passes.length == 1 &&
          voice != null &&
          sheet != null &&
          counters.single.start > voice.start &&
          counters.single.start > sheet.start &&
          counters.single.start < passes.single.start,
      'fixture-final-counter-before-pass');
  return errors;
}

void main() {
  final script = File('scripts/ios/e2e_xctest_flow.sh')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final yaml = File('.github/workflows/ios-widget-null-probe.yml')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final fixture =
      File('integration_test/widget_launch_routing_native_probe.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
  test('baseline structural contract', () {
    expect(_validate(script, yaml, fixture), isEmpty);
  });
  void reject(String label, {String? sh, String? workflow, String? dart}) {
    test('reject $label', () {
      expect(
        (sh != null && sh != script) ||
            (workflow != null && workflow != yaml) ||
            (dart != null && dart != fixture),
        isTrue,
        reason: 'mutation-$label',
      );
      expect(_validate(sh ?? script, workflow ?? yaml, dart ?? fixture),
          isNotEmpty,
          reason: label);
    });
  }

  final inline = '$_flag=1 $_call';
  for (final scope in <String>['root', 'job', 'other-step', 'native-step']) {
    final mutated = switch (scope) {
      'root' => yaml.replaceFirst('env:', 'env:\n  $_flag: 1'),
      'job' => yaml.replaceFirst(
          '  preflight:', '  preflight:\n    env:\n      $_flag: 1'),
      'other-step' => yaml.replaceFirst('      - uses:',
          '      - name: Other\n        env:\n          $_flag: 1\n      - uses:'),
      _ => yaml.replaceFirst('        id: run_probe',
          '        env:\n          $_flag: 1\n        id: run_probe'),
    };
    reject('yaml-$scope-env-with-inline', workflow: mutated);
  }
  reject('yaml-duplicate-inline',
      workflow: yaml.replaceFirst(inline, '$inline\n          $inline'));
  reject('yaml-misplaced-inline',
      workflow:
          '${yaml.replaceFirst(inline, _call)}\n      - name: Other\n        run: |\n          $inline \\\n');
  reject('yaml-comment-inline',
      workflow: yaml.replaceFirst(inline, '# $inline'));
  reject('shell-comment-if',
      sh: script.replaceFirst(
          'if [ "\$$_flag" = "1" ]; then', '# if [ "\$$_flag" = "1" ]; then'));
  reject('shell-default-on', sh: script.replaceFirst('$_flag:-0', '$_flag:-1'));
  reject('shell-no-else',
      sh: script.replaceFirst('      else\n        flutter build',
          '      # else\n        flutter build'));
  reject('shell-comment-defines',
      sh: script.replaceFirst(
          '--dart-define=SUPABASE_URL=https://widget-qa.invalid',
          '# --dart-define=SUPABASE_URL=https://widget-qa.invalid'));
  final clean = _lex(fixture);
  final guardAt = clean.indexOf('if (!AppEnv.hasValidSupabaseConfig) {');
  final guardEnd = guardAt + clean.substring(guardAt).indexOf('      }') + 7;
  final guard = fixture.substring(guardAt, guardEnd);
  final removed = fixture.replaceFirst(guard, '');
  reject('fixture-removed-guard', dart: removed);
  reject('fixture-comment-guard',
      dart: fixture.replaceFirst(guard, '/*$guard*/'));
  for (final anchor in <String>[
    'await _ensurePlaceholderSupabase();',
    'final AuthProvider qaAuth = AuthProvider(authService: authClient);'
  ]) {
    reject('fixture-after-${anchor.startsWith('await') ? 'sdk' : 'provider'}',
        dart: removed.replaceFirst(anchor, '$anchor\n$guard'));
  }
  reject('fixture-string-decoy',
      dart: removed.replaceFirst('final DateTime now',
          "final decoy = 'if (!AppEnv.hasValidSupabaseConfig) { throw StateError(); }';\nfinal DateTime now"));
  reject('fixture-comment-ios',
      dart: fixture.replaceFirst(
          'if (!Platform.isIOS)', 'if (false /* !Platform.isIOS */)'));
  reject('fixture-comment-network-throw',
      dart: fixture.replaceFirst("throw StateError(\n      'QA HTTP",
          "/* throw StateError */ StateError(\n      'QA HTTP"));
  final counterAt =
      clean.indexOf('      expect(\n        blockingClient.attempts,');
  final counterEnd = clean.indexOf('      );', counterAt) + 8;
  final counter = fixture.substring(counterAt, counterEnd);
  reject('fixture-comment-counter',
      dart: fixture.replaceFirst(counter, '/*$counter*/'));
  final withoutCounter = fixture.replaceFirst(counter, '');
  final passAt = withoutCounter.indexOf("'\$_probePassMarker ");
  final passEnd = withoutCounter.indexOf('      );', passAt) + 8;
  reject('fixture-counter-after-pass',
      dart: withoutCounter.replaceRange(passEnd, passEnd, '\n$counter'));
}
