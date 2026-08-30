// The target is wired in source control for unsigned builds. Apple Developer
// must still confirm the provisional App Group before signing or TestFlight.
import WidgetKit
import SwiftUI

private enum PlanFlowWidgetConfig {
  static let payloadKey = "widget_schedule_payload_v1"
  static let legacyTitleKey = "widget_schedule_title"

  static var appGroup: String? {
    Bundle.main.object(forInfoDictionaryKey: "PlanFlowAppGroup") as? String
  }

  static func dayURL(_ date: Date = Date()) -> URL {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return URL(string: "planflow://day/\(formatter.string(from: date))")!
  }
}

struct WidgetSchedulePayload: Decodable {
  let schemaVersion: Int
  let generatedAt: Date
  let events: [WidgetScheduleEvent]
  let dayCounts: [String: Int]
  let holidays: [String]
  let holidayDates: [String: String]?
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
  let displayColor: String
  let route: String
}

struct PlanFlowWidgetEntry: TimelineEntry {
  let date: Date
  let events: [WidgetScheduleEvent]
  let holidays: [String]
  let overflowCount: Int
  let isFallback: Bool
}

struct PlanFlowTimelineProvider: TimelineProvider {
  func placeholder(in context: Context) -> PlanFlowWidgetEntry {
    PlanFlowWidgetEntry(date: Date(), events: [], holidays: [], overflowCount: 0, isFallback: true)
  }

  func getSnapshot(in context: Context, completion: @escaping (PlanFlowWidgetEntry) -> Void) {
    completion(readEntry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<PlanFlowWidgetEntry>) -> Void) {
    let entry = readEntry()
    completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
  }

  private func readEntry() -> PlanFlowWidgetEntry {
    let now = Date()
    guard let group = PlanFlowWidgetConfig.appGroup,
          !group.contains("placeholder"),
          let defaults = UserDefaults(suiteName: group) else {
      return PlanFlowWidgetEntry(date: now, events: [], holidays: [], overflowCount: 0, isFallback: true)
    }
    if let raw = defaults.string(forKey: PlanFlowWidgetConfig.payloadKey),
       let data = raw.data(using: .utf8) {
      let decoder = JSONDecoder()
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
      guard let payload = try? decoder.decode(WidgetSchedulePayload.self, from: data),
            payload.schemaVersion == 1 else {
        return legacyEntry(defaults: defaults, now: now)
      }
      let dayEvents = eventsForDay(payload.events, now: now)
      return PlanFlowWidgetEntry(
        date: now,
        events: Array(dayEvents.prefix(6)),
        holidays: holidayLabels(payload: payload, now: now),
        overflowCount: max(0, dayEvents.count - 6),
        isFallback: false
      )
    }
    return legacyEntry(defaults: defaults, now: now)
  }

  private func eventsForDay(_ events: [WidgetScheduleEvent], now: Date) -> [WidgetScheduleEvent] {
    let calendar = Calendar.current
    return events.filter { calendar.isDate($0.start, inSameDayAs: now) }
  }

  private func holidayLabels(payload: WidgetSchedulePayload, now: Date) -> [String] {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    if let label = payload.holidayDates?[formatter.string(from: now)], !label.isEmpty {
      return [label]
    }
    // Older payloads only have an undifferentiated list. Keep a single label
    // rather than showing every holiday in the month on today's widget.
    return payload.holidayDates == nil ? Array(payload.holidays.prefix(1)) : []
  }

  private func legacyEntry(defaults: UserDefaults, now: Date) -> PlanFlowWidgetEntry {
    if let title = defaults.string(forKey: PlanFlowWidgetConfig.legacyTitleKey), !title.isEmpty {
      let legacy = WidgetScheduleEvent(
        id: "legacy",
        title: title,
        start: now,
        end: now,
        important: false,
        continuous: false,
        recurring: false,
        team: false,
        displayColor: "#435A70",
        route: PlanFlowWidgetConfig.dayURL(now).absoluteString
      )
      return PlanFlowWidgetEntry(date: now, events: [legacy], holidays: [], overflowCount: 0, isFallback: true)
    }
    return PlanFlowWidgetEntry(date: now, events: [], holidays: [], overflowCount: 0, isFallback: true)
  }
}

struct PlanFlowWidgetView: View {
  let entry: PlanFlowWidgetEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Link(destination: PlanFlowWidgetConfig.dayURL(entry.date)) {
        HStack {
          Text("PlanFlow").font(.headline)
          Spacer()
          Text(dayLabel(entry.date)).font(.caption).foregroundColor(.secondary)
        }
      }
      if !entry.holidays.isEmpty {
        Text(entry.holidays.joined(separator: " · "))
          .font(.caption2).foregroundColor(.red).lineLimit(1)
      }
      if entry.events.isEmpty {
        Text(entry.isFallback ? "일정을 불러오는 중" : "일정 없음")
          .font(.caption).foregroundColor(.secondary)
      } else {
        ForEach(Array(entry.events.enumerated()), id: \.element.id) { _, event in
          eventRow(event)
        }
        if entry.overflowCount > 0 {
          Text("+\(entry.overflowCount)개 더보기")
            .font(.caption2).foregroundColor(.secondary)
        }
      }
      Spacer(minLength: 0)
      if family == .systemLarge {
        Text("일정 탭에서 자세히 보기")
          .font(.caption2).foregroundColor(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func eventRow(_ event: WidgetScheduleEvent) -> some View {
    let destination = URL(string: event.route) ?? PlanFlowWidgetConfig.dayURL(entry.date)
    return Link(destination: destination) {
      HStack(spacing: 5) {
        if event.important { Text("!").fontWeight(.bold) }
        if event.continuous { Image(systemName: "arrow.left.and.right").font(.caption2) }
        Text(event.title)
          .font(family == .systemSmall ? .caption : .subheadline)
          .fontWeight(event.important ? .bold : .regular)
          .lineLimit(family == .systemSmall ? 1 : 2)
        Spacer(minLength: 0)
      }
      .foregroundColor(color(event.displayColor))
    }
  }

  private func dayLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.dateFormat = "M월 d일"
    return formatter.string(from: date)
  }

  private func color(_ value: String) -> Color {
    let raw = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard raw.count == 6, let number = UInt64(raw, radix: 16) else { return .primary }
    return Color(
      red: Double((number >> 16) & 0xFF) / 255,
      green: Double((number >> 8) & 0xFF) / 255,
      blue: Double(number & 0xFF) / 255
    )
  }
}

@main
struct PlanFlowWidgetBundle: WidgetBundle {
  var body: some Widget {
    PlanFlowWidget()
  }
}

struct PlanFlowWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "PlanFlowWidget", provider: PlanFlowTimelineProvider()) { entry in
      PlanFlowWidgetView(entry: entry)
    }
    .configurationDisplayName("PlanFlow 일정")
    .description("오늘 일정과 위젯 계약 데이터를 표시합니다.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}
