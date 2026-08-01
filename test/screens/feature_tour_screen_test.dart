import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/onboarding/feature_tour_screen.dart';
import 'package:planflow/services/feature_tour_service.dart';

void main() {
  testWidgets('feature tour can be skipped and records completion',
      (tester) async {
    final store = _FakeFeatureTourStore();
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

  testWidgets('feature tour finishes after the third page', (tester) async {
    final store = _FakeFeatureTourStore();
    await tester.pumpWidget(MaterialApp(home: FeatureTourScreen(store: store)));

    for (var index = 0; index < 3; index++) {
      await tester.tap(find.byKey(const ValueKey('feature-tour-next-button')));
      await tester.pumpAndSettle();
    }

    expect(store.completed, isTrue);
  });

  testWidgets('back completes the tour before leaving', (tester) async {
    final store = _FakeFeatureTourStore();
    await tester.pumpWidget(MaterialApp(home: FeatureTourScreen(store: store)));

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(store.completed, isTrue);
  });

  testWidgets('a failed completion store does not trap the user',
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

class _FakeFeatureTourStore extends FeatureTourStore {
  bool completed = false;

  @override
  Future<void> markCompleted() async => completed = true;

  @override
  Future<void> markTipShown(String tipId) async {}

  @override
  Future<bool> shouldShow() async => !completed;

  @override
  Future<bool> shouldShowTip(String tipId) async => false;
}
