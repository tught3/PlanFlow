// PlanFlowWidgetExtension bundle: the seven widgets that mirror the seven
// Android home-widget providers.
//
//   Home/Next schedule   <- PlanFlowHomeWidgetProvider            (kind PlanFlowWidget)
//   Monthly calendar     <- PlanFlowMonthlyWidgetProvider         (kind PlanFlowMonthlyWidget)
//   Vertical schedule    <- PlanFlowVerticalScheduleWidgetProvider(kind PlanFlowVerticalScheduleWidget)
//   Weekly grid          <- PlanFlowWeeklyWidgetProvider          (kind PlanFlowWeeklyWidget)
//   Weekly list          <- PlanFlowWeeklyListWidgetProvider      (kind PlanFlowWeeklyListWidget)
//   Mic voice launcher   <- PlanFlowMicWidgetProvider             (kind PlanFlowMicWidget)
//   Group calendar       <- PlanFlowGroupCalendarWidgetProvider   (kind PlanFlowGroupCalendarWidget)
//
// All widgets share PlanFlowTimelineProvider (15-minute refresh) and the
// widget_schedule_payload_v2 JSON (with v1 fallback) in Payload.swift.

import WidgetKit
import SwiftUI

struct PlanFlowWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "PlanFlowWidget", provider: PlanFlowTimelineProvider()) { entry in
      PlanFlowHomeWidgetView(entry: entry)
    }
    .configurationDisplayName("PlanFlow 다음 일정")
    .description("음성 입력으로 다음 일정을 빠르게 확인하세요")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

struct PlanFlowMonthlyWidget: Widget {
  var body: some WidgetConfiguration {
    if #available(iOSApplicationExtension 17.0, *) {
      StaticConfiguration(
        kind: "PlanFlowMonthlyWidget", provider: PlanFlowTimelineProvider()
      ) { entry in
        PlanFlowMonthlyWidgetView(entry: entry)
      }
      .configurationDisplayName("PlanFlow 월간 일정")
      .description("이번 달 일정 개수와 중요 일정을 한눈에 확인")
      .supportedFamilies([.systemMedium, .systemLarge])
      .contentMarginsDisabled()
    } else {
      StaticConfiguration(
        kind: "PlanFlowMonthlyWidget", provider: PlanFlowTimelineProvider()
      ) { entry in
        PlanFlowMonthlyWidgetView(entry: entry)
      }
      .configurationDisplayName("PlanFlow 월간 일정")
      .description("이번 달 일정 개수와 중요 일정을 한눈에 확인")
      .supportedFamilies([.systemMedium, .systemLarge])
    }
  }
}

struct PlanFlowVerticalScheduleWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: "PlanFlowVerticalScheduleWidget",
      provider: PlanFlowTimelineProvider()
    ) { entry in
      PlanFlowVerticalScheduleWidgetView(entry: entry)
    }
    .configurationDisplayName("PlanFlow 오늘 일정")
    .description("오늘 남은 일정을 타임라인으로 빠르게 확인")
    .supportedFamilies([.systemMedium, .systemLarge])
  }
}

struct PlanFlowWeeklyWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: "PlanFlowWeeklyWidget", provider: PlanFlowTimelineProvider()
    ) { entry in
      PlanFlowWeeklyWidgetView(entry: entry)
    }
    .configurationDisplayName("PlanFlow 주간 일정")
    .description("일주일간 일정을 요약해서 빠르게 확인")
    .supportedFamilies([.systemMedium, .systemLarge])
  }
}

struct PlanFlowWeeklyListWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: "PlanFlowWeeklyListWidget", provider: PlanFlowTimelineProvider()
    ) { entry in
      PlanFlowWeeklyListWidgetView(entry: entry)
    }
    .configurationDisplayName("PlanFlow 주간 일정 세로형")
    .description("이번 주 일정을 요일별 세로 목록으로 확인")
    .supportedFamilies([.systemLarge])
  }
}

struct PlanFlowMicWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: "PlanFlowMicWidget", provider: PlanFlowTimelineProvider()
    ) { _ in
      PlanFlowMicWidgetView()
    }
    .configurationDisplayName("PlanFlow 음성 입력")
    .description("아이콘을 탭해 음성 입력 화면을 바로 열기")
    .supportedFamilies([.systemSmall])
  }
}

struct PlanFlowGroupCalendarWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: "PlanFlowGroupCalendarWidget", provider: PlanFlowTimelineProvider()
    ) { entry in
      PlanFlowGroupCalendarWidgetView(entry: entry)
    }
    .configurationDisplayName("그룹 달력")
    .description("그룹 일정을 월간 달력으로 한눈에 확인")
    .supportedFamilies([.systemMedium, .systemLarge])
  }
}

@main
struct PlanFlowWidgetBundle: WidgetBundle {
  var body: some Widget {
    PlanFlowWidget()
    PlanFlowMonthlyWidget()
    PlanFlowVerticalScheduleWidget()
    PlanFlowWeeklyWidget()
    PlanFlowWeeklyListWidget()
    PlanFlowMicWidget()
    PlanFlowGroupCalendarWidget()
  }
}
