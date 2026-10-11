// Isolated iOS native UI probe for the interactive feature-tour practice.
// This exercises only the tour's in-memory example flow and its local
// completion marker. It is not full onboarding/auth/accessibility coverage.
// No backend, event service, alarm, voice, or network path is invoked.
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/l10n/app_localizations.dart';
import 'package:planflow/screens/onboarding/feature_tour_screen.dart';
import 'package:planflow/services/feature_tour_service.dart';

const String _nativeTutorialPracticePass = 'NATIVE_TUTORIAL_PRACTICE_PASS';
const String _nativeTutorialPracticeSkipped =
    'NATIVE_TUTORIAL_PRACTICE_SKIPPED';
const String _completedKey = SharedPreferencesFeatureTourStore.completedKey;

/// Register alongside the HomeWidget storage probe. The iOS workflow host runs
/// both tests in the existing XCTest runner; this marker is separate from the
/// HomeWidget nullable-storage PASS scope.
void registerFeatureTourPracticeNativeProbe() {
  testWidgets(
    'native iOS feature-tour practice flow and local completion marker',
    (WidgetTester tester) async {
      if (!Platform.isIOS) {
        // ignore: avoid_print
        print(
          '$_nativeTutorialPracticeSkipped: dart:io.Platform.isIOS=false '
          '(host=${Platform.operatingSystem}); requires a real iOS XCTest host, '
          'never native green.',
        );
        markTestSkipped(
          '$_nativeTutorialPracticeSkipped: actual iOS platform required '
          '(got ${Platform.operatingSystem}).',
        );
        return;
      }

      // Use the real plugin SDK and production store. Preserve the user's
      // pre-test completion state even if an assertion or UI action fails.
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final Object? previousValue = prefs.get(_completedKey);
      addTearDown(() async {
        if (previousValue == null) {
          await prefs.remove(_completedKey);
        } else {
          await prefs.setBool(_completedKey, previousValue as bool);
        }
      });
      await prefs.remove(_completedKey);
      expect(prefs.get(_completedKey), isNull,
          reason: 'practice must start with no completion marker');

      final DateTime actualNow = DateTime.now();
      var callbackCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ko'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: FeatureTourScreen(
            store: const SharedPreferencesFeatureTourStore(),
            requireFinalConfirmation: true,
            nowProvider: () => actualNow,
            onCompleted: () => callbackCount += 1,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('feature-tour-step-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('feature-tour-skip-button')), findsNothing,
          reason: 'required practice must not offer Skip');
      expect(prefs.get(_completedKey), isNull,
          reason: 'opening the tour must not complete it');

      const String sampleTitle = 'Native practice sample';
      await tester.enterText(
        find.byKey(const ValueKey('feature-tour-title-field')),
        sampleTitle,
      );
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('feature-tour-title-field')),
            )
            .controller!
            .text,
        sampleTitle,
      );

      final String initialStamp = _visibleStamp(tester);
      final DateTime initialTime = _parseStampNear(initialStamp, actualNow);
      final Finder createButton =
          find.byKey(const ValueKey('feature-tour-create-button'));
      await tester.ensureVisible(createButton);
      await tester.tap(createButton);
      await tester.pumpAndSettle();
      expect(find.text('$sampleTitle · $initialStamp'), findsOneWidget,
          reason: 'sample creation must show the entered title');
      expect(prefs.get(_completedKey), isNull,
          reason: 'creating a practice sample must not write completion');

      await tester.tap(find.byKey(const ValueKey('feature-tour-next-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('feature-tour-step-1')), findsOneWidget);
      expect(find.text(initialStamp), findsOneWidget,
          reason: 'edit step starts from the sample time shown in the UI');

      final Finder addThirtyButton =
          find.byKey(const ValueKey('feature-tour-plus-30-button'));
      await tester.ensureVisible(addThirtyButton);
      await tester.tap(addThirtyButton);
      await tester.pumpAndSettle();
      final DateTime editedTime = initialTime.add(const Duration(minutes: 30));
      final String editedStamp = _formatStamp(editedTime);
      expect(find.text(editedStamp), findsOneWidget,
          reason: '+30 minutes must update the displayed sample time');
      final Finder confirmTimeButton =
          find.byKey(const ValueKey('feature-tour-confirm-time-button'));
      await tester.ensureVisible(confirmTimeButton);
      await tester.tap(confirmTimeButton);
      await tester.pumpAndSettle();
      expect(find.text(editedStamp), findsOneWidget,
          reason: 'time confirmation keeps the edited time');

      await tester.tap(find.byKey(const ValueKey('feature-tour-next-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('feature-tour-step-2')), findsOneWidget);
      final String departureStamp =
          _formatStamp(editedTime.subtract(const Duration(minutes: 30)));
      final String preparationStamp =
          _formatStamp(editedTime.subtract(const Duration(minutes: 45)));
      expect(find.text(departureStamp), findsOneWidget,
          reason: 'departure preview is 20 minutes travel + 10 minutes buffer');
      expect(find.text(preparationStamp), findsOneWidget,
          reason: 'preparation preview is 15 minutes before departure');
      expect(prefs.get(_completedKey), isNull,
          reason: 'previewing reminders must not write completion');

      await tester.tap(
        find.byKey(const ValueKey('feature-tour-restart-button')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('feature-tour-step-0')), findsOneWidget,
          reason: 'Restart returns to the first practice step');
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('feature-tour-title-field')),
            )
            .controller!
            .text,
        isEmpty,
        reason: 'Restart clears the in-memory sample draft',
      );
      expect(prefs.get(_completedKey), isNull,
          reason: 'Restart must not write the completion marker');

      expect(find.byKey(const ValueKey('feature-tour-skip-button')), findsNothing,
          reason: 'Restart must retain required-final-confirmation mode');

      // Repeat the existing practice actions after Restart, then complete only
      // via the actual final Finish control in required mode.
      await tester.enterText(
        find.byKey(const ValueKey('feature-tour-title-field')),
        sampleTitle,
      );
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final String restartedStamp = _visibleStamp(tester);
      final DateTime restartedTime = _parseStampNear(restartedStamp, actualNow);
      final Finder restartedCreate =
          find.byKey(const ValueKey('feature-tour-create-button'));
      await tester.ensureVisible(restartedCreate);
      await tester.tap(restartedCreate);
      await tester.pumpAndSettle();
      expect(find.text('$sampleTitle \u00B7 $restartedStamp'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('feature-tour-next-button')));
      await tester.pumpAndSettle();
      final Finder restartedPlusThirty =
          find.byKey(const ValueKey('feature-tour-plus-30-button'));
      await tester.ensureVisible(restartedPlusThirty);
      await tester.tap(restartedPlusThirty);
      await tester.pumpAndSettle();
      final DateTime restartedEditedTime =
          restartedTime.add(const Duration(minutes: 30));
      final String restartedEditedStamp = _formatStamp(restartedEditedTime);
      expect(find.text(restartedEditedStamp), findsOneWidget);
      final Finder restartedConfirm =
          find.byKey(const ValueKey('feature-tour-confirm-time-button'));
      await tester.ensureVisible(restartedConfirm);
      await tester.tap(restartedConfirm);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('feature-tour-next-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('feature-tour-step-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('feature-tour-skip-button')), findsNothing);
      expect(prefs.get(_completedKey), isNull,
          reason: 'required practice stays incomplete until Finish');
      expect(callbackCount, 0,
          reason: 'required practice callback waits until Finish');
      final Finder finishButton =
          find.byKey(const ValueKey('feature-tour-next-button'));
      await tester.ensureVisible(finishButton);
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      expect(prefs.getBool(_completedKey), isTrue,
          reason: 'required Finish persists the real completion marker');
      expect(callbackCount, 1,
          reason: 'required Finish invokes the callback exactly once');
      expect(tester.takeException(), isNull,
          reason: 'required practice should complete without UI exceptions');

      // Preserve Skip coverage as a fresh optional tour with isolated callback
      // state; it must remain an explicit, exactly-once completion path.
      await prefs.remove(_completedKey);
      expect(prefs.get(_completedKey), isNull);
      var optionalCallbackCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ko'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: FeatureTourScreen(
            key: const ValueKey('optional-feature-tour-skip-probe'),
            store: const SharedPreferencesFeatureTourStore(),
            requireFinalConfirmation: false,
            nowProvider: () => actualNow,
            onCompleted: () => optionalCallbackCount += 1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('feature-tour-skip-button')),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('feature-tour-skip-button')));
      await tester.pumpAndSettle();
      expect(prefs.getBool(_completedKey), isTrue,
          reason: 'optional explicit Skip persists the production marker');
      expect(optionalCallbackCount, 1,
          reason: 'optional Skip invokes its callback exactly once');
      expect(tester.takeException(), isNull,
          reason: 'optional Skip should complete without UI exceptions');

      // ignore: avoid_print
      print(
        '$_nativeTutorialPracticePass '
        'os=${Platform.operatingSystemVersion} '
        'created=true edit_plus_30=true preview_arithmetic=true '
        'restart_no_marker=true required_no_skip=true '
        'required_finish_marker=true required_callbacks=1 '
        'explicit_skip_marker=true optional_callbacks=1',
      );
    },
    // This is functional UI coverage, not an accessibility semantics test.
    semanticsEnabled: false,
  );
}

String _visibleStamp(WidgetTester tester) {
  final RegExp stampPattern = RegExp(r'^\d{2}/\d{2} \d{2}:\d{2}$');
  return tester
      .widgetList<Text>(find.byType(Text))
      .map((Text text) => text.data)
      .whereType<String>()
      .firstWhere(stampPattern.hasMatch);
}

DateTime _parseStampNear(String stamp, DateTime near) {
  final Match match =
      RegExp(r'^(\d{2})/(\d{2}) (\d{2}):(\d{2})$').firstMatch(stamp)!;
  final int month = int.parse(match[1]!);
  final int day = int.parse(match[2]!);
  final int hour = int.parse(match[3]!);
  final int minute = int.parse(match[4]!);
  DateTime parsed = DateTime(near.year, month, day, hour, minute);
  // The initial draft is the next full hour, so a date earlier than the
  // current instant denotes the next calendar year (e.g. Dec 31 -> Jan 1).
  if (parsed.isBefore(near)) {
    parsed = DateTime(near.year + 1, month, day, hour, minute);
  }
  return parsed;
}

String _formatStamp(DateTime time) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${twoDigits(time.month)}/${twoDigits(time.day)} '
      '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
}
