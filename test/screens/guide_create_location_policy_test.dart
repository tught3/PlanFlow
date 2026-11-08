import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_create_location_policy.dart';

void main() {
  test('unresolved guide coordinates are allowed only behind QA policy', () {
    expect(
        guideCreateLocationAllowed(
            location: 'Somewhere',
            latitude: null,
            longitude: null,
            allowUnresolvedCoordinates: true),
        isTrue);
    expect(
        guideCreateLocationAllowed(
            location: 'Somewhere',
            latitude: null,
            longitude: null,
            allowUnresolvedCoordinates: false),
        isFalse);
    expect(
        guideCreateLocationAllowed(
            location: ' ',
            latitude: null,
            longitude: null,
            allowUnresolvedCoordinates: true),
        isFalse,
        reason: 'nonempty place remains mandatory even in QA');
  });
}
