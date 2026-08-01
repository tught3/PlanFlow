import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/feature_tour_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('shows the feature tour until this installation completes it', () async {
    const store = SharedPreferencesFeatureTourStore();

    expect(await store.shouldShow(), isTrue);
    await store.markCompleted();
    expect(await store.shouldShow(), isFalse);
  });

  test('shows each contextual tip only once', () async {
    const store = SharedPreferencesFeatureTourStore();

    expect(await store.shouldShowTip('voice'), isTrue);
    await store.markTipShown('voice');
    expect(await store.shouldShowTip('voice'), isFalse);
    expect(await store.shouldShowTip('location'), isTrue);
  });
}
