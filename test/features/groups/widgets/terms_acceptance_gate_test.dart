import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/features/groups/widgets/terms_acceptance_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> _prefs(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

Widget _host(SharedPreferences prefs, ValueChanged<bool> onResult) {
  return MaterialApp(
    home: Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () async {
            final accepted = await showTermsAcceptanceGate(
              context,
              preferences: prefs,
            );
            onResult(accepted);
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('동의하면 기록이 저장되고 true를 반환한다', (tester) async {
    final prefs = await _prefs({});
    bool? result;
    await tester.pumpWidget(_host(prefs, (v) => result = v));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('terms-gate-accept')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('terms-gate-accept')));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(prefs.getString(termsAcceptedUrlKey), termsOfServiceUrl);
    expect(prefs.getString(termsAcceptedAtKey), isNotNull);
  });

  testWidgets('"나중에"는 false를 반환하고 기록하지 않는다', (tester) async {
    final prefs = await _prefs({});
    bool? result;
    await tester.pumpWidget(_host(prefs, (v) => result = v));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('terms-gate-later')));
    await tester.pumpAndSettle();

    expect(result, isFalse);
    expect(prefs.getString(termsAcceptedUrlKey), isNull);
  });

  testWidgets('이미 동의한 사용자에게는 시트를 표시하지 않는다', (tester) async {
    final prefs = await _prefs({
      termsAcceptedUrlKey: termsOfServiceUrl,
      termsAcceptedAtKey: '2026-01-01T00:00:00.000',
    });
    bool? result;
    await tester.pumpWidget(_host(prefs, (v) => result = v));
    await tester.tap(find.text('open'));
    await tester.pump();

    expect(result, isTrue);
    expect(find.byKey(const ValueKey('terms-gate-accept')), findsNothing);
  });
}
