import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/l10n/app_localizations.dart';
import 'package:planflow/services/ios_app_store_update_service.dart';
import 'package:planflow/widgets/ios_app_store_update_prompt.dart';

void main() {
  final update = IosAppStoreUpdate(
    version: '1.2.0',
    storeUri: Uri.parse('https://apps.apple.com/kr/app/planflow/id123456789'),
  );

  Future<void> pumpPrompt(
    WidgetTester tester, {
    required Future<bool> Function(Uri) openStore,
    required void Function(BuildContext, String) showFailure,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showIosAppStoreUpdatePrompt(
                context: context,
                update: update,
                openStore: openStore,
                showFailure: showFailure,
              ),
              child: const Text('show prompt'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('show prompt'));
    await tester.pumpAndSettle();
  }

  testWidgets('Later dismisses the prompt without opening App Store',
      (tester) async {
    final openedUris = <Uri>[];
    final failures = <String>[];
    await pumpPrompt(
      tester,
      openStore: (uri) async {
        openedUris.add(uri);
        return true;
      },
      showFailure: (_, message) => failures.add(message),
    );

    expect(find.text('Update available'), findsOneWidget);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();

    expect(find.text('Update available'), findsNothing);
    expect(openedUris, isEmpty);
    expect(failures, isEmpty);
  });

  testWidgets('Update opens the exact App Store URI provided by Apple',
      (tester) async {
    final openedUris = <Uri>[];
    await pumpPrompt(
      tester,
      openStore: (uri) async {
        openedUris.add(uri);
        return true;
      },
      showFailure: (_, __) {},
    );

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    expect(openedUris, <Uri>[update.storeUri]);
    expect(find.text('Update available'), findsNothing);
  });

  testWidgets('failed App Store launch is surfaced after the prompt closes',
      (tester) async {
    final failures = <String>[];
    var promptWasDismissedWhenFailureSurfaced = false;
    await pumpPrompt(
      tester,
      openStore: (_) async => false,
      showFailure: (context, message) {
        failures.add(message);
        promptWasDismissedWhenFailureSurfaced =
            ModalRoute.of(context)?.isCurrent ?? false;
      },
    );

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    expect(find.text('Update available'), findsNothing);
    expect(failures, <String>[
      'Could not open the App Store. Please try again later.',
    ]);
    expect(promptWasDismissedWhenFailureSurfaced, isTrue);
  });
}
