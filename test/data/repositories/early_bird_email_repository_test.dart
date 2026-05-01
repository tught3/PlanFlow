import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/repositories/early_bird_email_repository.dart';

void main() {
  test('saveEmail submits normalized email through the RPC gateway', () async {
    final gateway = _FakeEarlyBirdEmailGateway();
    final repository = SupabaseEarlyBirdEmailRepository(gateway: gateway);

    final result = await repository.saveEmail(' USER@Example.COM ');

    expect(result.email, 'user@example.com');
    expect(result.status, EarlyBirdSignupStatus.submitted);
    expect(gateway.submittedEmails.single, 'user@example.com');
  });

  test('saveEmail rejects invalid emails before insert', () async {
    final gateway = _FakeEarlyBirdEmailGateway();
    final repository = SupabaseEarlyBirdEmailRepository(gateway: gateway);

    expect(
      () => repository.saveEmail('invalid-email'),
      throwsA(isA<ArgumentError>()),
    );
    expect(gateway.submittedEmails, isEmpty);
  });
}

class _FakeEarlyBirdEmailGateway implements EarlyBirdEmailGateway {
  final List<String> submittedEmails = <String>[];

  @override
  Future<void> submitEmail(String email) async {
    submittedEmails.add(email);
  }
}
