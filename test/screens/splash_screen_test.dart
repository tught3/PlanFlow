import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/screens/splash/splash_screen.dart';
import 'package:planflow/widgets/planflow_logo.dart';

void main() {
  testWidgets('SplashScreen shows the PlanFlow logo', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SplashScreen()));

    expect(find.byType(PlanFlowLogo), findsOneWidget);
    expect(find.text(AppConstants.appName), findsNothing);
  });
}
