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

  // MARK: Widget URL marker
  //
  // The home_widget iOS plugin (0.9.3+) keys off a `homeWidget` query item
  // when deciding whether a URL it received came from a WidgetKit tap
  // (and therefore should be reported via HomeWidget.widgetClicked / show
  // up in initiallyLaunchedFromHomeWidget) or from a generic deep link
  // (in which case the URL falls through to the app_links universal-link
  // handler). Every URL that originates from inside the PlanFlowWidget
  // extension MUST carry that marker; otherwise every widget tap is
  // misrouted and the app never observes the widget click.
  //
  // Locked down by test/ios_widget_url_delivery_contract_test.dart.
  static let schemeName = "planflow"
  static let homeWidgetMarkerName = "homeWidget"
  static let homeWidgetMarkerValue = "1"

  static var appGroup: String? {
    Bundle.main.object(forInfoDictionaryKey: "PlanFlowAppGroup") as? String
  }

  static var defaults: UserDefaults? {
    guard let group = appGroup, !group.contains("placeholder") else { return nil }
    return UserDefaults(suiteName: group)
  }

  /// Single source of the home_widget iOS marker. Every WidgetKit URL helper
  /// below routes its `queryItems` through this so the marker is added
  /// exactly once, in a stable order, regardless of which builder produced
  /// the URL.
  static func widgetMarkerItem() -> URLQueryItem {
    URLQueryItem(name: homeWidgetMarkerName, value: homeWidgetMarkerValue)
  }

  /// Appends the home_widget iOS marker to an existing URL string (e.g. a
  /// Dart-supplied `event.route` of `planflow://schedule/<id>` that needs to
  /// round-trip through WidgetKit). Idempotent: if the marker is already
  /// present, the URL is returned unchanged. Returns nil if the input is
  /// not a valid URL.
  static func withWidgetMarker(_ raw: String) -> URL? {
    guard var components = URLComponents(string: raw) else { return nil }
    let existing = components.queryItems ?? []
    if existing.contains(where: { $0.name == homeWidgetMarkerName }) {
      return components.url
    }
    var appended = existing
    appended.append(widgetMarkerItem())
    components.queryItems = appended
    return components.url
  }

  static func dayURL(_ date: Date = Date()) -> URL {
    var components = URLComponents()
    components.scheme = schemeName
    components.host = "day"
    components.path = "/" + ymd(date)
    components.queryItems = [widgetMarkerItem()]
    return components.url ?? URL(
      string: "\(schemeName)://day/\(ymd(date))"
        + "?\(homeWidgetMarkerName)=\(homeWidgetMarkerValue)"
    )!
  }

  static func calendarURL(_ date: Date? = nil) -> URL {
    var components = URLComponents()
    components.scheme = schemeName
    components.host = "calendar"
    var items: [URLQueryItem] = [widgetMarkerItem()]
    var fallback = "\(schemeName)://calendar"
      + "?\(homeWidgetMarkerName)=\(homeWidgetMarkerValue)"
    if let date = date {
      items.append(URLQueryItem(name: "date", value: ymd(date)))
      fallback = "\(schemeName)://calendar"
        + "?date=\(ymd(date))&\(homeWidgetMarkerName)=\(homeWidgetMarkerValue)"
    }
    components.queryItems = items
    return components.url ?? URL(string: fallback)!
  }

  static let voiceURL: URL = {
    var components = URLComponents()
    components.scheme = schemeName
    components.host = "voice-launcher"
    components.queryItems = [widgetMarkerItem()]
    return components.url ?? URL(
      string: "\(schemeName)://voice-launcher"
        + "?\(homeWidgetMarkerName)=\(homeWidgetMarkerValue)"
    )!
  }()

  static func eventURL(_ id: String) -> URL? {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var components = URLComponents()
    components.scheme = schemeName
    components.host = "event"
    components.path = "/" + trimmed
    components.queryItems = [widgetMarkerItem()]
    // eventURL already returns URL?, so the unencodable-id edge case
    // (e.g. a stray "%" that defeats percent-encoding) is expressed as nil
    // instead of a force-unwrapped string fallback that would crash on the
    // same arbitrary id. Callers (Views.swift) already bind with `if let`.
    return components.url
  }

  /// Group calendar deep link (group picker tap → no id; day-cell tap →
  /// id + date). Mirrors the inline `URL(string:)` calls previously in
  /// `PlanFlowGroupCalendarWidgetView` so the `homeWidget` marker is added
  /// by the same helper every other WidgetKit URL uses.
  static func groupCalendarURL(groupId: String? = nil, date: String? = nil) -> URL {
    var components = URLComponents()
    components.scheme = schemeName
    components.host = "group-calendar"
    var items: [URLQueryItem] = [widgetMarkerItem()]
    if let groupId = groupId?.trimmingCharacters(in: .whitespacesAndNewlines),
       !groupId.isEmpty {
      items.append(URLQueryItem(name: "groupId", value: groupId))
    }
    if let date = date?.trimmingCharacters(in: .whitespacesAndNewlines),
       !date.isEmpty {
      items.append(URLQueryItem(name: "date", value: date))
    }
    components.queryItems = items
    return components.url ?? URL(
      string: "\(schemeName)://group-calendar"
        + "?\(homeWidgetMarkerName)=\(homeWidgetMarkerValue)"
    )!
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
