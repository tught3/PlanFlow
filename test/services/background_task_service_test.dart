import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/app_feedback_service.dart';
import 'package:planflow/services/background_task_service.dart';

void main() {
  testWidgets('background task failure can notify the user', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: AppFeedbackService.scaffoldMessengerKey,
        home: const Scaffold(body: Text('home')),
      ),
    );

    await BackgroundTaskService.run(
      () async => throw StateError('boom'),
      owner: 'TestOwner',
      label: 'test_failure',
      failureMessage: '후속 작업 실패 안내',
    );
    await tester.pump();

    expect(find.text('후속 작업 실패 안내'), findsOneWidget);
  });
}
