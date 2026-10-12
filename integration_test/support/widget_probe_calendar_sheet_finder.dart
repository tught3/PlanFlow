import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Finds a day-agenda event title only within the visible calendar sheet.
Finder findWidgetProbeCalendarDaySheetEventTitle(String title) {
  return find.descendant(
    of: find
        .byKey(const ValueKey<String>('calendar-day-events-draggable-sheet')),
    matching: find.text(title),
    skipOffstage: true,
  );
}
