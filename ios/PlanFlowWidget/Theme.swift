// Visual theme shared by all PlanFlow widgets.
//
// The baseline is the Android widget palette (android drawables
// widget_background / widget_panel_background / widget_voice_chip_background
// and the calendar_style_* contract defaults). iOS adds intentional light/dark
// variants via dynamic colors instead of the accidental black container.

import SwiftUI
import UIKit

enum PlanFlowTheme {
  static func color(_ hexLight: String, dark darkHex: String) -> Color {
    Color(uiColor: UIColor { trait in
      trait.userInterfaceStyle == .dark
        ? UIColor(PlanFlowTheme.rgba(darkHex))
        : UIColor(PlanFlowTheme.rgba(hexLight))
    })
  }

  private static func rgba(_ hex: String) -> UIColor {
    let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard raw.count == 6, let number = UInt64(raw, radix: 16) else {
      return UIColor(white: 0.5, alpha: 1)
    }
    return UIColor(
      red: CGFloat((number >> 16) & 0xFF) / 255,
      green: CGFloat((number >> 8) & 0xFF) / 255,
      blue: CGFloat(number & 0xFF) / 255,
      alpha: 1
    )
  }

  // Event semantic colors (calendar_style_* defaults).
  static let eventText = color("#435A70", dark: "#C6D6E5")
  static let mutedText = color("#8FA4B7", dark: "#8FA4B7")
  static let criticalText = color("#633B8E", dark: "#CDB0F2")
  static let teamText = color("#7B560B", dark: "#F0CE83")
  static let recurringText = color("#126E68", dark: "#8CD8CF")
  static let multiDayText = color("#4B6336", dark: "#C2D9A6")
  static let holidayText = color("#C62828", dark: "#F08A8A")
  static let saturdayText = color("#1E64B7", dark: "#8CC0F5")

  // Chrome (widget_background / panel / chip).
  static let background = color("#FFFFFF", dark: "#1A222D")
  static let panelBackground = color("#EDF5FF", dark: "#22303F")
  static let chipBackground = color("#D7ECFF", dark: "#2C4257")
  static let chipText = color("#1F4168", dark: "#BBD7F2")
  static let brandText = color("#1F4168", dark: "#BBD7F2")
  static let strongText = color("#142A44", dark: "#DEEAF6")
  static let border = color("#D8E9F7", dark: "#33465A")
  static let todayCircle = color("#3E7BC0", dark: "#3E7BC0")
  static let countdownText = color("#D94444", dark: "#F08A8A")
  static let outOfMonthText = color("#9AADC0", dark: "#5F7488")

  static func eventColor(
    important: Bool,
    team: Bool,
    recurring: Bool,
    continuous: Bool
  ) -> Color {
    if important { return criticalText }
    if team { return teamText }
    if recurring { return recurringText }
    if continuous { return multiDayText }
    return eventText
  }

  static func eventColor(_ event: WidgetScheduleEvent) -> Color {
    eventColor(
      important: event.important,
      team: event.team,
      recurring: event.recurring,
      continuous: event.continuous
    )
  }
}

extension View {
  /// iOS 17+ requires containerBackground; older runtimes fall back to a
  /// plain background. This is what fixes the accidental black container.
  @ViewBuilder func planFlowWidgetBackground() -> some View {
    if #available(iOSApplicationExtension 17.0, *) {
      containerBackground(for: .widget) {
        PlanFlowTheme.background
      }
    } else {
      background(PlanFlowTheme.background)
    }
  }
}

// MARK: - Date formatting helpers

enum PlanFlowFormat {
  static func dayMonth(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.timeZone = .current
    formatter.dateFormat = "M월 d일"
    return formatter.string(from: date)
  }

  static func monthDay(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.timeZone = .current
    formatter.dateFormat = "M/d"
    return formatter.string(from: date)
  }

  static func monthDayWeekday(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.timeZone = .current
    formatter.dateFormat = "M/d(E)"
    return formatter.string(from: date)
  }

  static func weekday(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.timeZone = .current
    formatter.dateFormat = "E"
    return formatter.string(from: date)
  }

  static func shortTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.timeZone = .current
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }

  /// Mirrors Android BasePlanFlowWidgetProvider.formatTime: 내일/모레 접두사,
  /// 그 외에는 M/d HH:mm.
  static func relativeTime(_ date: Date, now: Date) -> String {
    let calendar = Calendar.current
    let time = shortTime(date)
    if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now) ?? now) {
      return "내일 \(time)"
    }
    if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: 2, to: now) ?? now) {
      return "모레 \(time)"
    }
    return "\(monthDay(date)) \(time)"
  }

  /// Mirrors Android formatCountdown.
  static func countdown(_ date: Date, now: Date) -> String? {
    let minutes = Int(date.timeIntervalSince(now) / 60)
    if minutes <= 0 { return nil }
    if minutes < 60 { return "\(minutes)분 후" }
    if minutes < 1440 { return "\(minutes / 60)시간 후" }
    if minutes < 2880 { return "내일" }
    if minutes < 4320 { return "모레" }
    return "D-\(minutes / 1440)일"
  }

  static func overflow(_ count: Int) -> String? {
    count > 0 ? "+\(count)건" : nil
  }
}
