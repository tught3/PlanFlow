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

  testWidgets(
    'themed FilledButton infinity minSize keeps actions on a single row across viewports, locales, and text scales',
    (tester) async {
      const viewports = <Size>[
        Size(320, 568),
        Size(390, 844),
      ];
      const locales = <Locale>[
        Locale('en'),
        Locale('ko'),
      ];
      const textScales = <double>[1.0, 1.5];

      for (final viewport in viewports) {
        for (final locale in locales) {
          for (final textScale in textScales) {
            tester.view.devicePixelRatio = 1.0;
            await tester.binding.setSurfaceSize(viewport);
            addTearDown(() async {
              await tester.binding.setSurfaceSize(null);
              tester.view.resetDevicePixelRatio();
            });
            tester.platformDispatcher.textScaleFactorTestValue = textScale;
            addTearDown(
              () => tester.platformDispatcher.clearTextScaleFactorTestValue(),
            );

            final l10n = await AppLocalizations.delegate.load(locale);

            await tester.pumpWidget(
              MaterialApp(
                locale: locale,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: ThemeData(
                  filledButtonTheme: FilledButtonThemeData(
                    style: ButtonStyle(
                      minimumSize: WidgetStateProperty.all<Size>(
                        const Size(double.infinity, 48),
                      ),
                    ),
                  ),
                ),
                home: Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showIosAppStoreUpdatePrompt(
                        context: context,
                        update: update,
                        openStore: (_) async => true,
                        showFailure: (_, __) {},
                      ),
                      child: const Text('show prompt'),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('show prompt'));
            await tester.pumpAndSettle();

            // No layout / render exceptions should be reported.
            expect(
              tester.takeException(),
              isNull,
              reason: 'layout exception for $locale @ x$textScale',
            );

            final laterFinder = find.text(l10n.appUpdateLater);
            final updateFinder = find.text(l10n.appUpdateNow);
            expect(
              laterFinder,
              findsOneWidget,
              reason: 'later label missing for $locale @ x$textScale',
            );
            expect(
              updateFinder,
              findsOneWidget,
              reason: 'update label missing for $locale @ x$textScale',
            );

            final laterRect = tester.getRect(laterFinder);
            final updateRect = tester.getRect(updateFinder);

            // Both buttons must share the same vertical center within
            // one logical pixel - i.e. they live on a single row.
            expect(
              laterRect.center.dy,
              closeTo(updateRect.center.dy, 1.0),
              reason: 'vertical centers differ for $locale @ x$textScale',
            );

            // They must not horizontally overlap.
            expect(
              laterRect.overlaps(updateRect),
              isFalse,
              reason: 'buttons overlap for $locale @ x$textScale',
            );

            // Tapping the update button (the narrower one under the
            // themed infinity minSize) still navigates and dismisses
            // the dialog.
            await tester.tap(updateFinder);
            await tester.pumpAndSettle();
            expect(
              find.text(l10n.appUpdateAvailableTitle),
              findsNothing,
              reason:
                  'dialog still visible after update tap for $locale @ x$textScale',
            );
          }
        }
      }
    },
  );
}
