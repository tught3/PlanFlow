import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:planflow/screens/auth/login_screen.dart';

void main() {
  testWidgets('LoginScreen shows the Naver social login button',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: LoginScreen(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('이메일 로그인'), findsOneWidget);
    expect(find.text('간편 로그인'), findsOneWidget);
    expect(find.text('네이버로 계속하기'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('이메일 로그인')).dy,
      lessThan(tester.getTopLeft(find.text('간편 로그인')).dy),
    );
  });
}
