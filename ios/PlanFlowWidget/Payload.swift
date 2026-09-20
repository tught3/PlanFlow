// Shared payload reader for all PlanFlow widgets.
//
// widget_schedule_payload_v2 = widget_schedule_payload_v1 + month/week
// projections (see lib/services/widget_schedule_contract.dart). The decoder
// accepts schemaVersion >= 1 so a v1 payload still renders the original
// single-widget behaviour; v2-only keys are optional and decoded as nil.

import WidgetKit
import SwiftUI

enum PlanFlowWidgetConfig {
  static let payloadV2Key = "widget_schedule_payload_v2"
  static let payloadV1Key = "widget_schedule_payload_v1"
  static let legacyTitleKey = "widget_schedule_title"
  static let monthOffsetKey = "planflow_ios_month_widget_offset"

  static var appGroup: String? {
    Bundle.main.object(forInfoDictionaryKey: "PlanFlowAppGroup") as? String
  }

  static var defaults: UserDefaults? {
    guard let group = appGroup, !group.contains("placeholder") else { return nil }
    return UserDefaults(suiteName: group)
  }

  static func dayURL(_ date: Date = Date()) -> URL {
    URL(string: "planflow://day/\(ymd(date))")!
  }

  static func calendarURL(_ date: Date? = nil) -> URL {
    guard let date = date else {
      return URL(string: "planflow://calendar")!
    }
    return URL(string: "planflow://calendar?date=\(ymd(date))")!
  }

  static let voiceURL = URL(string: "planflow://voice-launcher")!

  static func eventURL(_ id: String) -> URL? {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return URL(string: "planflow://event/\(trimmed)")
  }

  static func ymd(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }
}

struct WidgetSchedulePayload: Decodable {
  let schemaVersion: Int
  let generatedAt: Date
  let events: [WidgetScheduleEvent]
  let dayCounts: [String: Int]
  let holidays: [String]
  let holidayDates: [String: String]?
  let month: WidgetMonthPayload?
  let week: WidgetWeekPayload?
}

struct WidgetScheduleEvent: Decodable {
  let id: String
  let title: String
  let start: Date
  let end: Date
  let important: Bool
  let continuous: Bool
  let recurring: Bool
  let team: Bool
  let strongAlarm: Bool?
  let displayColor: String

  var usesStrongAlarm: Bool { strongAlarm ?? false }
  let route: String
  let segment: String?
  let showTitle: Bool?

  var showsTitleInMonth: Bool { showTitle ?? (segment == nil || segment == "single" || segment == "start") }
}

struct WidgetMonthPayload: Decodable {
  let title: String
  let year: Int
  let month: Int
  let cells: [WidgetMonthCellPayload]
}

struct WidgetMonthCellPayload: Decodable {
  let date: String
  let day: Int
  let inMonth: Bool
  let holidayName: String?
  let isDayOff: Bool
  let overflowCount: Int
  let events: [WidgetScheduleEvent]
}

struct WidgetWeekPayload: Decodable {
  let title: String
  let days: [WidgetWeekDayPayload]
}

struct WidgetWeekDayPayload: Decodable {
  let date: String
  let label: String
  let events: [WidgetScheduleEvent]
  let overflowCount: Int
}

/// Reads the shared schedule + group-calendar contracts written by Dart via
/// the home_widget plugin (App Group UserDefaults). No second schedule source:
/// everything here mirrors Android renderer keys or the versioned JSON.
final class PlanFlowWidgetStore {
  static let shared = PlanFlowWidgetStore()

  private let decoder: JSONDecoder

  private init() {
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: value) {
        return date
      }
      formatter.formatOptions = [.withInternetDateTime]
      guard let date = formatter.date(from: value) else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Invalid ISO-8601 widget date"
        )
      }
      return date
    }
  }

  func loadPayload() -> WidgetSchedulePayload? {
    guard let defaults = PlanFlowWidgetConfig.defaults else { return nil }
    for key in [PlanFlowWidgetConfig.payloadV2Key, PlanFlowWidgetConfig.payloadV1Key] {
      guard let raw = defaults.string(forKey: key),
            let data = raw.data(using: .utf8),
            let payload = try? decoder.decode(WidgetSchedulePayload.self, from: data),
            payload.schemaVersion >= 1 else {
        continue
      }
      return payload
    }
    return nil
  }

  func string(_ key: String) -> String? {
    PlanFlowWidgetConfig.defaults?.string(forKey: key)
  }

  func int(_ key: String) -> Int? {
    guard let defaults = PlanFlowWidgetConfig.defaults else { return nil }
    // Dart may persist numbers as Int, Double or String depending on the
    // plugin path; mirror the Android readInt defensive decode.
    if let number = defaults.object(forKey: key) as? NSNumber {
      return number.intValue
    }
    if let raw = defaults.string(forKey: key) {
      return Int(raw)
    }
    return nil
  }

  func bool(_ key: String) -> Bool {
    PlanFlowWidgetConfig.defaults?.bool(forKey: key) ?? false
  }

  func date(_ key: String) -> Date? {
    guard let raw = string(key), !raw.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: raw) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: raw)
  }

  // MARK: Group calendar (gw_* contract, PlanFlowGroupCalendarWidgetProvider)

  struct GroupCalendarData {
    let groupId: String
    let groupName: String
    /// date (yyyy-MM-dd) -> [(displayName, count)] sorted by count desc.
    let occurrencesByDay: [String: [(String, Int)]]
  }

  func loadGroupCalendar() -> GroupCalendarData? {
    guard let groupsRaw = string("gw_groups_json"),
          let data = groupsRaw.data(using: .utf8),
          let groups = try? JSONDecoder().decode([[String: String]].self, from: data),
          let first = groups.first,
          let groupId = first["id"], !groupId.isEmpty else {
      return nil
    }
    let groupName = string("gw_\(groupId)_name") ?? "그룹 달력"
    var occurrencesByDay: [String: [String: Int]] = [:]
    if let raw = string("gw_\(groupId)_occurrences_json"),
       let data = raw.data(using: .utf8),
       let items = try? JSONDecoder().decode([[String: String]].self, from: data) {
      for item in items {
        guard let day = item["d"], !day.isEmpty,
              let name = item["n"], !name.isEmpty else { continue }
        occurrencesByDay[day, default: [:]][name, default: 0] += 1
      }
    }
    let summary = occurrencesByDay.mapValues { dayMap in
      dayMap.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
    return GroupCalendarData(
      groupId: groupId,
      groupName: groupName,
      occurrencesByDay: summary
    )
  }
}
