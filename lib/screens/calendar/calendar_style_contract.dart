import 'package:flutter/material.dart';

/// Versioned style contract shared by the in-app calendar and native widgets.
///
/// The widget payload stores these values so a widget refresh always carries
/// the same semantic palette as the calendar tab. Keep names stable when
/// adding a new widget renderer; bump [calendarStyleContractVersion] only when
/// the payload shape changes.
const int calendarStyleContractVersion = 1;

const Color calendarCriticalEventMarkerColor = Color(0xFF8051B2);
const Color calendarCriticalEventTextColor = Color(0xFF633B8E);
const Color calendarCriticalEventBackgroundColor = Color(0xFFE2D2F3);
const Color calendarNormalEventTextColor = Color(0xFF435A70);
const Color calendarNormalEventBackgroundColor = Color(0xFFDCE8F2);
const Color calendarMultiDayEventBackgroundColor = Color(0xFFDCE8C9);
const Color calendarMultiDayEventTextColor = Color(0xFF4B6336);
const Color calendarMultiDayEventBorderColor = Color(0xFF78935B);
const Color calendarCriticalMultiDayAccentColor = Color(0xFF8051B2);
const Color calendarGroupEventColor = Color(0xFF7B560B);
const Color calendarGroupEventBackgroundColor = Color(0xFFF4DEAA);
const Color calendarRecurringEventColor = Color(0xFF126E68);
const Color calendarRecurringEventBackgroundColor = Color(0xFFD2ECE8);
const Color calendarHolidayColor = Color(0xFFC62828);
const Color calendarSaturdayColor = Color(0xFF1E64B7);

/// Typography values used for event rows in both renderers.
const double calendarEventFontSize = 8.3;
const double calendarDateFontSize = 13;
// Detailed day sheets keep their larger holiday heading typography.
const double calendarHolidayFontSize = 13;
// Monthly holiday labels are intentionally only 0.5sp larger than a normal
// event, and this value is shared with the Android widget contract.
const double calendarMonthlyHolidayFontSize = calendarEventFontSize + 0.5;
const double calendarGroupMemberFontSize = 10;
const double calendarRecurringMarkerFontSize = 7.8;
const double calendarStrongAlarmMarkerFontSize = 5.8;

int _argb(Color color) => color.toARGB32();

Map<String, Object> calendarStyleContractPayload() => <String, Object>{
      'calendar_style_contract_version': calendarStyleContractVersion,
      'calendar_style_critical_text': _argb(calendarCriticalEventTextColor),
      'calendar_style_critical_marker': _argb(calendarCriticalEventMarkerColor),
      'calendar_style_critical_background':
          _argb(calendarCriticalEventBackgroundColor),
      'calendar_style_normal_text': _argb(calendarNormalEventTextColor),
      'calendar_style_normal_background':
          _argb(calendarNormalEventBackgroundColor),
      'calendar_style_multiday_text': _argb(calendarMultiDayEventTextColor),
      'calendar_style_multiday_background':
          _argb(calendarMultiDayEventBackgroundColor),
      'calendar_style_multiday_border': _argb(calendarMultiDayEventBorderColor),
      'calendar_style_team_text': _argb(calendarGroupEventColor),
      'calendar_style_team_background':
          _argb(calendarGroupEventBackgroundColor),
      'calendar_style_recurring_text': _argb(calendarRecurringEventColor),
      'calendar_style_recurring_background':
          _argb(calendarRecurringEventBackgroundColor),
      'calendar_style_holiday_text': _argb(calendarHolidayColor),
      'calendar_style_saturday_text': _argb(calendarSaturdayColor),
      // Store typography as tenths of an sp because Android SharedPreferences
      // has no portable Dart double representation through home_widget.
      'calendar_style_event_font_sp10': 83,
      'calendar_style_date_font_sp10': 130,
      'calendar_style_holiday_font_sp10': 88,
      'calendar_style_group_member_font_sp10': 100,
      'calendar_style_recurring_marker_sp10': 78,
      'calendar_style_strong_alarm_marker_sp10': 58,
    };
