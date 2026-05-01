import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/early_bird_email_model.dart';

void main() {
  test('EarlyBirdEmailModel normalizes and serializes email payloads', () {
    final model = EarlyBirdEmailModel(
      email: ' USER@Example.COM ',
      createdAt: DateTime.parse('2026-05-01T00:00:00Z'),
    );

    final json = model.toJson();
    final restored = EarlyBirdEmailModel.fromJson(json);

    expect(json['email'], 'user@example.com');
    expect(restored.email, 'user@example.com');
    expect(restored.createdAt, DateTime.parse('2026-05-01T00:00:00Z'));
  });

  test('EarlyBirdEmailModel validates email shape', () {
    expect(EarlyBirdEmailModel.isValidEmail('pro@planflow.app'), isTrue);
    expect(EarlyBirdEmailModel.isValidEmail('not-an-email'), isFalse);
    expect(EarlyBirdEmailModel.isValidEmail('missing-domain@'), isFalse);
  });
}
