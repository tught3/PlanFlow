// One timeline entry + provider shared by all seven PlanFlow widgets.
// Payloads are plain JSON snapshots from UserDefaults, so reading is cheap and
// the 15-minute refresh policy matches the Android widget update cadence.

import WidgetKit
import SwiftUI

struct PlanFlowWidgetEntry: TimelineEntry {
  let date: Date
  let payload: WidgetSchedulePayload?
  let isFallback: Bool

  /// Events intersecting the given day, Android rawWidgetEventsForDay order.
  func events(on day: Date) -> [WidgetScheduleEvent] {
    guard let payload = payload else { return [] }
    let calendar = Calendar.current
    return payload.events
      .filter { calendar.isDate($0.start, inSameDayAs: day) }
      .sorted {
        $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start
      }
  }

  /// Holiday label for today (holidayDates first, legacy single-label list
  /// as the v1 fallback).
  func holidayLabels(on day: Date) -> [String] {
    guard let payload = payload else { return [] }
    if let holidayDates = payload.holidayDates {
      let label = holidayDates[PlanFlowWidgetConfig.ymd(day)] ?? ""
      return label.isEmpty ? [] : [label]
    }
    return Array(payload.holidays.prefix(1))
  }
}

struct PlanFlowTimelineProvider: TimelineProvider {
  func placeholder(in context: Context) -> PlanFlowWidgetEntry {
    PlanFlowWidgetEntry(date: Date(), payload: nil, isFallback: true)
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping (PlanFlowWidgetEntry) -> Void
  ) {
    completion(readEntry())
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<PlanFlowWidgetEntry>) -> Void
  ) {
    let entry = readEntry()
    completion(
      Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900)))
    )
  }

  private func readEntry() -> PlanFlowWidgetEntry {
    let now = Date()
    if let payload = PlanFlowWidgetStore.shared.loadPayload() {
      return PlanFlowWidgetEntry(
        date: now,
        payload: payload,
        isFallback: false
      )
    }
    return PlanFlowWidgetEntry(date: now, payload: nil, isFallback: true)
  }
}

// MARK: - Legacy SharedPreferences fallbacks (next_event_* / event_list_*)

extension PlanFlowWidgetStore {
  struct NextEventSnapshot {
    let title: String
    let eventId: String?
    let startAt: Date?
    let location: String?
    let travelMinutes: Int?
    let isCritical: Bool
    let isRecurring: Bool
    let isTeam: Bool
  }

  var nextEvent: NextEventSnapshot? {
    guard let title = string("next_event_title"), !title.isEmpty else {
      return nil
    }
    return NextEventSnapshot(
      title: title,
      eventId: string("next_event_id"),
      startAt: date("next_event_start_at"),
      location: string("next_event_location"),
      travelMinutes: int("next_event_travel_buffer_minutes"),
      isCritical: bool("next_event_is_critical"),
      isRecurring: bool("next_event_is_recurring"),
      isTeam: bool("next_event_is_team")
    )
  }

  func listEvent(slot: Int) -> (title: String, eventId: String?, startAt: Date?)? {
    guard let title = string("event_list_\(slot)_title"), !title.isEmpty else {
      return nil
    }
    return (title, string("event_list_\(slot)_id"), date("event_list_\(slot)_time"))
  }
}

// MARK: - v1 fallback projections (no month/week keys in the payload)

enum PlanFlowProjection {
  private static let weekdayStartOffsetSunday = { (date: Date) -> Int in
    // Android grids start on Sunday; %7 maps Mon=1..Sat=6 -> 1..6, Sun=7 -> 0.
    let weekday = Calendar.current.component(.weekday, from: date)
    return weekday % 7
  }

  /// 42 cells (6 weeks x 7 days, Sunday start) for the month containing
  /// `monthStart`. Mirrors Android buildCurrentMonthFallbackCells.
  static func monthGridDays(monthStart: Date) -> [Date] {
    let calendar = Calendar.current
    guard let firstOfMonth = calendar.date(
      from: calendar.dateComponents([.year, .month], from: monthStart)
    ) else {
      return []
    }
    let startOffset = weekdayStartOffsetSunday(firstOfMonth)
    guard let firstCell = calendar.date(
      byAdding: .day, value: -startOffset, to: firstOfMonth
    ) else {
      return []
    }
    return (0..<42).compactMap {
      calendar.date(byAdding: .day, value: $0, to: firstCell)
    }
  }

  static func isSameMonth(_ day: Date, _ monthStart: Date) -> Bool {
    let calendar = Calendar.current
    return calendar.component(.year, from: day)
      == calendar.component(.year, from: monthStart)
      && calendar.component(.month, from: day)
        == calendar.component(.month, from: monthStart)
  }

  /// Monday-start week containing `day` (Android baseWeekStart).
  static func weekStart(for day: Date) -> Date {
    let calendar = Calendar.current
    let weekday = calendar.component(.weekday, from: day)
    let daysFromMonday = (weekday + 5) % 7
    return calendar.date(byAdding: .day, value: -daysFromMonday, to: day) ?? day
  }

  /// Fallback month title "yyyy.MM".
  static func monthTitle(_ monthStart: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy.MM"
    return formatter.string(from: monthStart)
  }
}
