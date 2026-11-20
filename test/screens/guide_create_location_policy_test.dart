import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_create_location_policy.dart';

void main() {
  test('a named guide place can save while coordinates are pending', () {
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
        reason: 'a nonempty place remains mandatory');
  });
}
