import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/onboarding/feature_tour_screen.dart';
import 'package:planflow/services/feature_tour_service.dart';

class _MemoryFeatureTourStore extends FeatureTourStore {
  var completed = false;

  @override
  Future<bool> shouldShow() async => true;

  @override
  Future<void> markCompleted() async => completed = true;

  @override
  Future<bool> shouldShowTip(String tipId) async => true;

  @override
  Future<void> markTipShown(String tipId) async {}
}

class _FailingFeatureTourStore extends FeatureTourStore {
  @override
  Future<void> markCompleted() =>
      Future<void>.error(StateError('write failed'));

  @override
  Future<void> markTipShown(String tipId) async {}

  @override
  Future<bool> shouldShow() async => true;

  @override
  Future<bool> shouldShowTip(String tipId) async => false;
}

void main() {
  testWidgets('optional tour can be skipped and records completion',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: FeatureTourScreen(
          store: store,
          onCompleted: () => completed = true,
        ),
      ),
    );

    expect(find.text('말하면 일정이 정리돼요'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('feature-tour-skip-button')));
    await tester.pump();
    expect(store.completed, isTrue);
    expect(completed, isTrue);
  });

  testWidgets('optional tour still completes on system back', (tester) async {
    final store = _MemoryFeatureTourStore();
    await tester.pumpWidget(MaterialApp(home: FeatureTourScreen(store: store)));

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(store.completed, isTrue);
  });

  testWidgets('failed completion store does not trap optional tour',
      (tester) async {
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: FeatureTourScreen(
          store: _FailingFeatureTourStore(),
          onCompleted: () => completed = true,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('feature-tour-skip-button')));
    await tester.pump();
    expect(completed, isTrue);
  });

  testWidgets('required first-run tour waits for page-three confirmation',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    await tester.pumpWidget(
      MaterialApp(
        home: FeatureTourScreen(
          store: store,
          requireFinalConfirmation: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('말하면 일정이 정리돼요'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('feature-tour-skip-button')), findsNothing);
    expect(store.completed, isFalse);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('말하면 일정이 정리돼요'), findsOneWidget);
    expect(store.completed, isFalse);

    final nextButton = find.byKey(const ValueKey('feature-tour-next-button'));
    await tester.tap(nextButton);
    await tester.pumpAndSettle();
    expect(find.text('AI 대화로 일정도 고쳐요'), findsOneWidget);
    expect(store.completed, isFalse);

    await tester.tap(nextButton);
    await tester.pumpAndSettle();
    expect(find.text('출발과 브리핑을 챙겨드려요'), findsOneWidget);
    expect(find.text('시작하기'), findsOneWidget);
    expect(store.completed, isFalse);

    await tester.tap(nextButton);
    await tester.pumpAndSettle();
    expect(store.completed, isTrue);
    expect(find.byType(FeatureTourScreen), findsNothing);
  });

  testWidgets('optional tour keeps skip behavior for settings reruns',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    await tester.pumpWidget(
      MaterialApp(home: FeatureTourScreen(store: store)),
    );
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('feature-tour-skip-button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('feature-tour-skip-button')));
    await tester.pumpAndSettle();
    expect(store.completed, isTrue);
    expect(find.byType(FeatureTourScreen), findsNothing);
  });
}
