// Phase 2 source scaffold. UNWIRED_XCODE_TARGET: add a WidgetKit extension
// and App Group entitlement on macOS before this file is compiled.
import WidgetKit
import SwiftUI

private enum PlanFlowWidgetConfig {
  // Replace only in the signed Xcode target; never commit an account-specific ID.
  static let appGroup = "group.com.planflow.app.placeholder"
  static let canonicalURL = URL(string: "planflow://day/today")!
}

private struct WidgetSchedulePayload: Decodable {
  let schemaVersion: Int
  let events: [WidgetScheduleEvent]
}

private struct WidgetScheduleEvent: Decodable {
  let title: String
}

struct PlanFlowWidgetEntry: TimelineEntry {
  let date: Date
  let title: String
}

struct PlanFlowTimelineProvider: TimelineProvider {
  func placeholder(in context: Context) -> PlanFlowWidgetEntry {
    PlanFlowWidgetEntry(date: Date(), title: "일정을 불러오는 중")
  }

  func getSnapshot(in context: Context, completion: @escaping (PlanFlowWidgetEntry) -> Void) {
    completion(PlanFlowWidgetEntry(date: Date(), title: "오늘 일정"))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<PlanFlowWidgetEntry>) -> Void) {
    let defaults = UserDefaults(suiteName: PlanFlowWidgetConfig.appGroup)
    let canonicalTitle = defaults?.string(forKey: "widget_schedule_payload_v1")
      .flatMap { value -> String? in
        guard let data = value.data(using: .utf8),
              let payload = try? JSONDecoder().decode(WidgetSchedulePayload.self, from: data),
              payload.schemaVersion >= 1 else { return nil }
        return payload.events.first?.title
      }
    let title = canonicalTitle ?? defaults?.string(forKey: "widget_schedule_title") ?? "일정 없음"
    let entry = PlanFlowWidgetEntry(date: Date(), title: title)
    completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
  }
}

struct PlanFlowWidgetView: View {
  let entry: PlanFlowWidgetEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    Link(destination: PlanFlowWidgetConfig.canonicalURL) {
      VStack(alignment: .leading, spacing: 6) {
        Text("PlanFlow").font(.headline)
        Text(entry.title).font(family == .systemSmall ? .caption : .body)
          .lineLimit(family == .systemSmall ? 2 : 4)
        if family == .systemLarge { Text("일정 탭에서 자세히 보기").font(.caption2) }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }
}

@main
struct PlanFlowWidget: Widget {
  let kind = "PlanFlowWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: PlanFlowTimelineProvider()) { entry in
      PlanFlowWidgetView(entry: entry)
    }
    .configurationDisplayName("PlanFlow 일정")
    .description("오늘 일정과 위젯 계약 데이터를 표시합니다.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}
