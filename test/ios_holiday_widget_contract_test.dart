// Source contract for the iOS monthly widget holiday fallback branch.
//
// This test scans the WidgetKit Swift sources for the structural rules the
// production fix relies on. It is intentionally a static-only check because
// no Flutter test host can compile SwiftUI or render a WidgetKit timeline:
//
//   * `flutter test` only links the Flutter Dart runtime. xcodebuild /
//     WidgetKit need a real Xcode toolchain that is not present in this
//     environment.
//   * The Apple runtime simulators and physical iOS devices required to
//     exercise `PlanFlowMonthlyWidgetView` are also unavailable here.
//
// The Android and Dart layers run their own KASI/canonical tests
// (`test/services/korean_holidays_test.dart`,
// `test/services/synced_public_holiday_visibility_test.dart`,
// `test/screens/calendar_screen_test.dart`) and the existing
// `test/ios_release_contract_test.dart` covers the cross-target wiring.
// This file pins the *source* contract that ties them together: the Swift
// fallback path must treat any holiday present in the canonical holiday
// date map as a red day off, must render the day number in the same red,
// and must never paint the Android "종일" prefix on a canonical holiday
// label rendered by `monthEventTitle`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current;
  File swiftFile(String path) =>
      File('${root.path}${Platform.pathSeparator}$path');

  String readSource(String relativePath) {
    final file = swiftFile(relativePath);
    expect(file.existsSync(), isTrue,
        reason: 'Expected Swift source at $relativePath to exist');
    return file.readAsStringSync().replaceAll('\r\n', '\n');
  }

  test(
      'monthly widget fallback marks holidays red via holidayDates lookup and uses MonthlyCellModel',
      () {
    final views = readSource('ios/PlanFlowWidget/Views.swift');

    // The fallback path (non-canonical payload, e.g. rawEvents-only timeline)
    // must derive isDayOff from the canonical holiday date map: the day is a
    // day off exactly when its ymd key is present in holidayDates. This is
    // the contract that keeps the fallback in sync with the app calendar.
    final fallbackStart =
        views.indexOf('let holidays = entry.payload?.holidayDates');
    expect(fallbackStart, isNonNegative,
        reason:
            'Expected the holidayDates fallback branch in monthCells to be present');
    final fallbackEnd = views.indexOf('\n  }', fallbackStart);
    expect(fallbackEnd, greaterThan(fallbackStart));
    final fallback = views.substring(fallbackStart, fallbackEnd);
    expect(fallback, contains('MonthlyCellModel('));
    expect(fallback,
        contains('holidayName: holidays?[PlanFlowWidgetConfig.ymd(day)]'));
    expect(fallback,
        contains('isDayOff: holidays?[PlanFlowWidgetConfig.ymd(day)] != nil'));

    // The day number must be painted via the typed dayNumberColor helper so
    // the SwiftUI branch cannot drift away from the red color the app uses.
    expect(views, contains('MonthlyCellModel'));
    expect(
      views,
      contains('isHoliday: cell.holidayName != nil || cell.isDayOff'),
    );
    expect(views, contains('dayNumberColor('));
    expect(
      views,
      contains(
          'func dayNumberColor(\n  day: Date, inMonth: Bool, isHoliday: Bool, isToday: Bool'),
    );
    expect(views, contains('isHoliday || weekday == 1'));
    expect(views, contains('return PlanFlowTheme.holidayText'));
  });

  test(
      'monthly widget paints the canonical holiday name red and never prefixes 종일',
      () {
    final views = readSource('ios/PlanFlowWidget/Views.swift');

    // The holiday label is rendered as plain Text(holiday) without any
    // "종일" or all-day marker. The color must switch to PlanFlowTheme.holidayText
    // when the day is a KASI day off so the cell matches the app calendar.
    final holidayLabelStart =
        views.indexOf('if let holiday = cell.holidayName');
    expect(holidayLabelStart, isNonNegative,
        reason:
            'Expected the canonical holiday label branch in monthCell to be present');
    final holidayLabelEnd = views.indexOf('\n      }', holidayLabelStart);
    expect(holidayLabelEnd, greaterThan(holidayLabelStart));
    final holidayLabel = views.substring(holidayLabelStart, holidayLabelEnd);
    expect(holidayLabel, contains('Text(holiday)'));
    expect(
        holidayLabel,
        contains(
            'cell.isDayOff ? PlanFlowTheme.holidayText : PlanFlowTheme.mutedText'));

    // monthEventTitle must not inject a "종일" all-day marker. The Android
    // renderer reserves that prefix for ordinary all-day user events; the
    // iOS widget inherits the same semantics.
    final monthEventTitleStart = views.indexOf('func monthEventTitle(');
    expect(monthEventTitleStart, isNonNegative,
        reason: 'Expected monthEventTitle helper to be defined');
    final monthEventTitleEnd = views.indexOf('\n  }', monthEventTitleStart);
    expect(monthEventTitleEnd, greaterThan(monthEventTitleStart));
    final monthEventTitle =
        views.substring(monthEventTitleStart, monthEventTitleEnd);
    expect(monthEventTitle, isNot(contains('종일')));
    expect(monthEventTitle, isNot(contains('isAllDay')));
    expect(monthEventTitle, contains('event.title'));

    // The whole file is the unit of contract here; double-check the wider
    // file does not contain the forbidden prefix either, so a future edit
    // cannot silently reintroduce it in a different helper.
    expect(views, isNot(contains('종일')),
        reason:
            'iOS widget must not use the Korean 종일 all-day prefix; that label is owned by the app calendar renderer.');
  });

  test(
      'holidayDates payload field is published so the fallback has a typed source',
      () {
    // The payload contract is defined in Payload.swift, but the fallback
    // branch in Views.swift reads `entry.payload?.holidayDates`. Walk the
    // whole widget target to confirm both ends agree on the typed field.
    final widgetDir = Directory('${root.path}${Platform.pathSeparator}ios'
        '${Platform.pathSeparator}PlanFlowWidget');
    final source = widgetDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.swift'))
        .map((file) => file.readAsStringSync().replaceAll('\r\n', '\n'))
        .join('\n');
    expect(source, contains('holidayDates'),
        reason:
            'holidayDates must be declared on the payload model and read by the monthly view');
    expect(source, contains('[String: String]'),
        reason:
            'holidayDates must be typed as a String -> String map so the ymd lookup is type-safe');
  });
}
