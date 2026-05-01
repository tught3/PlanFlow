import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/repositories/early_bird_email_repository.dart';
import 'package:planflow/screens/home/widgets/early_bird_signup_card.dart';

void main() {
  testWidgets('EarlyBirdSignupCard saves a valid email', (tester) async {
    final repository = _FakeEarlyBirdEmailRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EarlyBirdSignupCard(repository: repository),
        ),
      ),
    );

    await tester.enterText(find.byType(TextFormField), ' USER@Example.COM ');
    await tester.tap(find.text('신청하기'));
    await tester.pumpAndSettle();

    expect(repository.savedEmails.single, ' USER@Example.COM ');
    expect(find.text('신청이 완료되었습니다. 출시 소식을 보내드릴게요.'), findsOneWidget);
  });

  testWidgets('EarlyBirdSignupCard shows validation for invalid email',
      (tester) async {
    final repository = _FakeEarlyBirdEmailRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EarlyBirdSignupCard(repository: repository),
        ),
      ),
    );

    await tester.enterText(find.byType(TextFormField), 'invalid-email');
    await tester.tap(find.text('신청하기'));
    await tester.pump();

    expect(find.text('올바른 이메일을 입력해 주세요.'), findsOneWidget);
    expect(repository.savedEmails, isEmpty);
  });
}

class _FakeEarlyBirdEmailRepository extends EarlyBirdEmailRepository {
  final List<String> savedEmails = <String>[];

  @override
  Future<EarlyBirdSignupResult> saveEmail(String email) async {
    savedEmails.add(email);
    return EarlyBirdSignupResult(
      email: email.trim().toLowerCase(),
      status: EarlyBirdSignupStatus.submitted,
    );
  }
}
