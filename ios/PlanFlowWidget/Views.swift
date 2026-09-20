// Widget views mirroring the Android RemoteViews layouts
// (planflow_{home,monthly,vertical_schedule,weekly,weekly_list,mic,
// group_calendar}_widget.xml). Each view reproduces its Android counterpart's
// purpose, hierarchy, palette and deep links — they are not copies of one list.

import SwiftUI
import WidgetKit
import AppIntents

/// SwiftUI ships `Link` as a view, not a modifier; this keeps row-level tap
/// targets readable.
extension View {
  func link(destination: URL) -> some View {
    Link(destination: destination) { self }
  }
}


@available(iOSApplicationExtension 16.0, *)
struct PlanFlowMonthNavigationIntent: AppIntent {
  static var title: LocalizedStringResource = "PlanFlow 월 이동"
  static var description = IntentDescription("PlanFlow 월간 위젯의 표시 월을 바꿉니다.")
  static var openAppWhenRun = false

  @Parameter(title: "이동량")
  var delta: Int

  @Parameter(title: "오늘로")
  var resetToToday: Bool

  init() {}

  init(delta: Int, resetToToday: Bool = false) {
    self.delta = delta
    self.resetToToday = resetToToday
  }

  func perform() async throws -> some IntentResult {
    guard let defaults = PlanFlowWidgetConfig.defaults else {
      return .result()
    }
    let current = defaults.integer(forKey: PlanFlowWidgetConfig.monthOffsetKey)
    let next = resetToToday ? 0 : min(24, max(-24, current + delta))
    defaults.set(next, forKey: PlanFlowWidgetConfig.monthOffsetKey)
    WidgetCenter.shared.reloadTimelines(ofKind: "PlanFlowMonthlyWidget")
    return .result()
  }
}

// MARK: - Shared components

/// Android widget_voice_chip_background + PlanFlowWidgetVoiceChip style.
struct VoiceChip: View {
  var body: some View {
    Link(destination: PlanFlowWidgetConfig.voiceURL) {
      Text("입력")
        .font(.system(size: 11, weight: .bold))
        .foregroundColor(PlanFlowTheme.chipText)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 14)
            .fill(PlanFlowTheme.chipBackground)
        )
    }
  }
}

/// Bold colored event line: [time ]title with the Android semantic palette.
struct EventLine: View {
  let title: String
  let important: Bool
  let recurring: Bool
  let team: Bool
  let continuous: Bool
  var timePrefix: String? = nil
  var muted: Bool = false
  var lineLimit: Int = 1

  var body: some View {
    HStack(spacing: 2) {
      if let timePrefix = timePrefix, !timePrefix.isEmpty {
        Text(timePrefix)
          .foregroundColor(muted ? PlanFlowTheme.mutedText : PlanFlowTheme.eventText)
      }
      Text(displayTitle)
        .fontWeight(important ? .bold : .regular)
        .foregroundColor(color)
        .lineLimit(lineLimit)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .font(.system(size: 10))
  }

  private var displayTitle: String {
    recurring ? "↻ \(title)" : title
  }

  private var color: Color {
    muted
      ? PlanFlowTheme.mutedText
      : PlanFlowTheme.eventColor(
        important: important, team: team, recurring: recurring,
        continuous: continuous)
  }
}

extension WidgetScheduleEvent {
  var line: EventLine {
    EventLine(
      title: title,
      important: important,
      recurring: recurring,
      team: team,
      continuous: continuous
    )
  }
}

/// Single-day-of-week header (일 red ... 토 blue), mirrors
/// bindMonthWeekdayHeader.
struct WeekdayHeaderRow: View {
  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(["일", "월", "화", "수", "목", "금", "토"].enumerated()), id: \.offset) {
        index, label in
        Text(label)
          .font(.system(size: 9, weight: .semibold))
          .foregroundColor(
            index == 0
              ? PlanFlowTheme.holidayText
              : (index == 6 ? PlanFlowTheme.saturdayText : PlanFlowTheme.eventText)
          )
          .frame(maxWidth: .infinity)
      }
    }
  }
}

func dayNumberColor(
  day: Date, inMonth: Bool, isHoliday: Bool, isToday: Bool
) -> Color {
  let weekday = Calendar.current.component(.weekday, from: day)
  if isToday { return .white }
  if isHoliday || weekday == 1 { return PlanFlowTheme.holidayText }
  if weekday == 7 { return PlanFlowTheme.saturdayText }
  return inMonth ? PlanFlowTheme.eventText : PlanFlowTheme.outOfMonthText
}

// MARK: - 1. Home / next schedule (planflow_home_widget.xml)

struct PlanFlowHomeWidgetView: View {
  let entry: PlanFlowWidgetEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Link(destination: PlanFlowWidgetConfig.calendarURL()) {
          Text("PlanFlow")
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(PlanFlowTheme.brandText)
        }
        Spacer()
        VoiceChip()
      }
      .padding(.bottom, 8)

      Link(destination: nextDestination) {
        VStack(alignment: .leading, spacing: 3) {
          badge
          if let next = next {
            Text(next.title)
              .font(.system(size: 17, weight: .bold))
              .foregroundColor(
                next.isCritical ? PlanFlowTheme.criticalText : PlanFlowTheme.strongText
              )
              .lineLimit(1)
            if let start = next.startAt {
              Text(PlanFlowFormat.relativeTime(start, now: entry.date))
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(PlanFlowTheme.eventText)
            }
            if let location = next.location, !location.isEmpty {
              Text(location)
                .font(.system(size: 11))
                .foregroundColor(PlanFlowTheme.mutedText)
                .lineLimit(1)
            }
            if let travel = next.travelMinutes, travel > 0, let start = next.startAt {
              Text("이동 \(travel)분")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(PlanFlowTheme.brandText)
              Text("출발: \(PlanFlowFormat.shortTime(start.addingTimeInterval(Double(-travel) * 60)))")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(PlanFlowTheme.brandText)
            }
            if let start = next.startAt,
               let countdown = PlanFlowFormat.countdown(start, now: entry.date) {
              Text(countdown)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(PlanFlowTheme.countdownText)
            }
          } else if entry.isFallback {
            Text("일정을 불러오는 중")
              .font(.system(size: 11))
              .foregroundColor(PlanFlowTheme.mutedText)
          } else {
            Text("예정된 일정이 없어요")
              .font(.system(size: 13, weight: .semibold))
              .foregroundColor(PlanFlowTheme.eventText)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
          RoundedRectangle(cornerRadius: 14)
            .fill(PlanFlowTheme.panelBackground)
        )
      }

      if family != .systemSmall {
        upcomingList
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .planFlowWidgetBackground()
  }

  private var next: PlanFlowWidgetStore.NextEventSnapshot? {
    PlanFlowWidgetStore.shared.nextEvent
      ?? entry.payload?.events.sorted { $0.start < $1.start }.first.map {
        PlanFlowWidgetStore.NextEventSnapshot(
          title: $0.title, eventId: $0.id, startAt: $0.start,
          location: nil, travelMinutes: nil, isCritical: $0.important,
          isRecurring: $0.recurring, isTeam: $0.team
        )
      }
  }

  private var nextDestination: URL {
    if let id = next?.eventId, let url = PlanFlowWidgetConfig.eventURL(id) {
      return url
    }
    return PlanFlowWidgetConfig.calendarURL()
  }

  @ViewBuilder
  private var badge: some View {
    let critical = next?.isCritical ?? false
    Text(critical ? "중요 일정" : "다음 일정")
      .font(.system(size: 10, weight: .bold))
      .foregroundColor(.white)
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(critical ? PlanFlowTheme.criticalText : PlanFlowTheme.todayCircle)
      )
  }

  /// event_list_1..3 rows, falling back to the payload events for today.
  @ViewBuilder
  private var upcomingList: some View {
    let store = PlanFlowWidgetStore.shared
    let prefEvents = (1...3).compactMap { store.listEvent(slot: $0) }
    VStack(alignment: .leading, spacing: 2) {
      if prefEvents.isEmpty {
        ForEach(Array(entry.events(on: entry.date).prefix(3).enumerated()), id: \.element.id) {
          _, event in
          event.line
        }
      } else {
        ForEach(Array(prefEvents.enumerated()), id: \.offset) { _, event in
          EventLine(
            title: event.title,
            important: false,
            recurring: false,
            team: false,
            continuous: false,
            timePrefix: event.startAt.map { PlanFlowFormat.shortTime($0) }
          )
        }
      }
    }
    .padding(.top, 6)
  }
}

// MARK: - 2. Monthly calendar (planflow_monthly_widget.xml)

struct MonthlyCellModel {
  let date: Date
  let day: Int
  let inMonth: Bool
  let holidayName: String?
  let isDayOff: Bool
  let overflowCount: Int
  let events: [WidgetScheduleEvent]

  var isToday: Bool { Calendar.current.isDateInToday(date) }
}

struct PlanFlowMonthlyWidgetView: View {
  let entry: PlanFlowWidgetEntry

  var body: some View {
    let cells = monthCells
    VStack(alignment: .leading, spacing: 2) {
      monthHeader
      WeekdayHeaderRow()
      // 6 rows x 7 columns; on small heights later rows clip, matching the
      // Android rowCount budget.
      // 남은 세로 공간을 6주가 균등하게 나눠 쓰게 한다. 기존에는 각
      // 주 행이 내용 높이만큼만 차지하고 아래에 Spacer가 붙어 날짜가 위쪽에
      // 몰렸다. 위젯 높이에 맞춰 6행이 유연하게 늘어나도록 각 행/셀을 모두
      // maxHeight까지 확장한다.
      VStack(spacing: 1) {
        ForEach(0..<6, id: \.self) { row in
          HStack(spacing: 1) {
            ForEach(0..<7, id: \.self) { column in
              let index = row * 7 + column
              if index < cells.count {
                monthCell(cells[index])
                  .frame(maxHeight: .infinity, alignment: .topLeading)
              } else {
                Color.clear
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
              }
            }
          }
          .frame(maxHeight: .infinity)
        }
      }
      .frame(maxHeight: .infinity)
    }
    .padding(.horizontal, 8)
    .padding(.top, 2)
    .padding(.bottom, 6)
    .planFlowWidgetBackground()
  }

  private var monthOffset: Int {
    let raw = PlanFlowWidgetConfig.defaults?.integer(
      forKey: PlanFlowWidgetConfig.monthOffsetKey
    ) ?? 0
    return min(24, max(-24, raw))
  }

  private var monthStart: Date {
    let calendar = Calendar.current
    let now = Date()
    let currentStart = calendar.date(
      from: DateComponents(
        year: calendar.component(.year, from: now),
        month: calendar.component(.month, from: now),
        day: 1
      )
    ) ?? now
    return calendar.date(byAdding: .month, value: monthOffset, to: currentStart)
      ?? currentStart
  }

  private var monthTitle: String {
    PlanFlowProjection.monthTitle(monthStart)
  }

  @ViewBuilder
  private var monthHeader: some View {
    HStack(spacing: 5) {
      if #available(iOSApplicationExtension 17.0, *) {
        Button(intent: PlanFlowMonthNavigationIntent(delta: 0, resetToToday: true)) {
          Text("오늘")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
              Capsule().fill(PlanFlowTheme.chipBackground)
            )
        }
        .buttonStyle(.plain)
      } else {
        Link(destination: PlanFlowWidgetConfig.calendarURL(Date())) {
          Text("오늘")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
              Capsule().fill(PlanFlowTheme.chipBackground)
            )
        }
      }

      Spacer(minLength: 1)

      if #available(iOSApplicationExtension 17.0, *) {
        Button(intent: PlanFlowMonthNavigationIntent(delta: -1)) {
          Image(systemName: "chevron.left")
            .font(.system(size: 10, weight: .bold))
            .frame(width: 24, height: 22)
            .background(Circle().fill(PlanFlowTheme.chipBackground))
        }
        .buttonStyle(.plain)
      } else {
        Image(systemName: "chevron.left")
          .font(.system(size: 10, weight: .bold))
      }

      Text(monthTitle)
        .font(.system(size: 13, weight: .bold))
        .foregroundColor(PlanFlowTheme.strongText)
        .lineLimit(1)

      if #available(iOSApplicationExtension 17.0, *) {
        Button(intent: PlanFlowMonthNavigationIntent(delta: 1)) {
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .frame(width: 24, height: 22)
            .background(Circle().fill(PlanFlowTheme.chipBackground))
        }
        .buttonStyle(.plain)
      } else {
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .bold))
      }

      Spacer(minLength: 1)
      VoiceChip()
    }
    .foregroundColor(PlanFlowTheme.brandText)
    .frame(height: 27)
  }

  /// v2 month cells, else the Android rawEvents fallback layout (multi-day
  /// rows first, then singles, holiday row reserved).
  private var monthCells: [MonthlyCellModel] {
    if monthOffset == 0,
       let month = entry.payload?.month,
       month.year == Calendar.current.component(.year, from: monthStart),
       month.month == Calendar.current.component(.month, from: monthStart) {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = .current
      formatter.dateFormat = "yyyy-MM-dd"
      return month.cells.map { cell in
        MonthlyCellModel(
          date: formatter.date(from: cell.date) ?? Date(),
          day: cell.day,
          inMonth: cell.inMonth,
          holidayName: cell.holidayName,
          isDayOff: cell.isDayOff,
          overflowCount: cell.overflowCount,
          events: cell.events
        )
      }
    }
    let holidays = entry.payload?.holidayDates
    return PlanFlowProjection.monthGridDays(monthStart: monthStart).map { day in
      let dayEvents = entry.events(on: day)
      return MonthlyCellModel(
        date: day,
        day: Calendar.current.component(.day, from: day),
        inMonth: PlanFlowProjection.isSameMonth(day, monthStart),
        holidayName: holidays?[PlanFlowWidgetConfig.ymd(day)],
        isDayOff: false,
        overflowCount: max(0, dayEvents.count - 4),
        events: Array(dayEvents.prefix(4))
      )
    }
  }

  private func monthEventTitle(_ event: WidgetScheduleEvent) -> String {
    var markers: [String] = []
    if event.important && event.usesStrongAlarm {
      markers.append("🔔")
    }
    if event.recurring {
      markers.append("↻")
    }
    return markers.isEmpty ? event.title : "\(markers.joined(separator: " ")) \(event.title)"
  }

  private func monthCell(_ cell: MonthlyCellModel) -> some View {
    let visible = cell.holidayName == nil
      ? Array(cell.events.prefix(4))
      : Array(cell.events.prefix(3))
    let hiddenOverflow = cell.holidayName == nil
      ? cell.overflowCount
      : max(cell.overflowCount, cell.events.count - 3)
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        Spacer(minLength: 0)
        Text("\(cell.day)")
          .font(.system(size: 9, weight: cell.isToday ? .bold : .regular))
          .foregroundColor(
            dayNumberColor(
              day: cell.date, inMonth: cell.inMonth,
              isHoliday: cell.holidayName != nil || cell.isDayOff,
              isToday: cell.isToday
            )
          )
          .frame(width: 13, height: 13)
          .background(
            Circle().fill(
              cell.isToday ? PlanFlowTheme.todayCircle : Color.clear
            )
          )
        Spacer(minLength: 0)
      }
      if let holiday = cell.holidayName {
        Text(holiday)
          .font(.system(size: 6.5))
          .foregroundColor(cell.isDayOff ? PlanFlowTheme.holidayText : PlanFlowTheme.mutedText)
          .lineLimit(1)
      }
      ForEach(Array(visible.enumerated()), id: \.offset) { _, event in
        if event.showsTitleInMonth {
          Text(monthEventTitle(event))
            .font(.system(size: 6.5, weight: event.important ? .bold : .regular))
            .foregroundColor(
              cell.inMonth ? PlanFlowTheme.eventColor(event) : PlanFlowTheme.mutedText
            )
            .lineLimit(1)
        } else {
          RoundedRectangle(cornerRadius: 1)
            .fill(
              (cell.inMonth ? PlanFlowTheme.eventColor(event) : PlanFlowTheme.mutedText)
                .opacity(0.35)
            )
            .frame(height: 4)
        }
      }
      if let overflow = PlanFlowFormat.overflow(hiddenOverflow) {
        Text(overflow)
          .font(.system(size: 6.5))
          .foregroundColor(PlanFlowTheme.mutedText)
      }
    }
    .padding(.vertical, 1)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 2)
        .fill(cell.isToday ? PlanFlowTheme.panelBackground : Color.clear)
    )
    .link(destination: PlanFlowWidgetConfig.calendarURL(cell.date))
  }
}

// MARK: - 3. Vertical schedule (planflow_vertical_schedule_widget.xml)

struct PlanFlowVerticalScheduleWidgetView: View {
  let entry: PlanFlowWidgetEntry

  private let maxVisible = 5

  var body: some View {
    let dayEvents = entry.events(on: entry.date)
    let visible = Array(dayEvents.prefix(maxVisible))
    let overflow = max(0, dayEvents.count - maxVisible)
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("오늘 일정")
          .font(.system(size: 14, weight: .bold))
          .foregroundColor(PlanFlowTheme.strongText)
        Spacer()
        VoiceChip()
      }
      .padding(.bottom, 6)
      // ponytail: Android has ‹/› day-offset broadcast buttons; WidgetKit on
      // the iOS 15 deployment target has no equivalent, so this widget shows
      // today only and deep links into the app calendar for other days.
      if visible.isEmpty {
        Text(entry.isFallback ? "일정을 불러오는 중" : "오늘 일정이 없습니다")
          .font(.system(size: 11))
          .foregroundColor(PlanFlowTheme.mutedText)
      } else {
        ForEach(Array(visible.enumerated()), id: \.element.id) { _, event in
          Link(
            destination:
              URL(string: event.route) ?? PlanFlowWidgetConfig.calendarURL()
          ) {
            event.line
          }
        }
        if let overflowLabel = PlanFlowFormat.overflow(overflow) {
          Text(overflowLabel)
            .font(.system(size: 10))
            .foregroundColor(PlanFlowTheme.mutedText)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .link(destination: PlanFlowWidgetConfig.calendarURL(entry.date))
    .planFlowWidgetBackground()
  }
}

// MARK: - 4. Weekly grid (planflow_weekly_widget.xml)

struct PlanFlowWeeklyWidgetView: View {
  let entry: PlanFlowWidgetEntry

  var body: some View {
    VStack(spacing: 2) {
      HStack {
        Text("주간 일정")
          .font(.system(size: 14, weight: .bold))
          .foregroundColor(PlanFlowTheme.strongText)
        Spacer()
        VoiceChip()
      }
      HStack(spacing: 2) {
        ForEach(Array(weekDays.enumerated()), id: \.offset) { _, day in
          weekColumn(day)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(6)
    .planFlowWidgetBackground()
  }

  var weekDays: [WidgetWeekDayPayload] {
    if let days = entry.payload?.week?.days, days.count == 7 {
      return days
    }
    let weekStart = PlanFlowProjection.weekStart(for: entry.date)
    let calendar = Calendar.current
    return (0..<7).map { offset in
      let day = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
      let dayEvents = entry.events(on: day)
      return WidgetWeekDayPayload(
        date: PlanFlowWidgetConfig.ymd(day),
        label: PlanFlowFormat.weekday(day),
        events: Array(dayEvents.prefix(2)),
        overflowCount: max(0, dayEvents.count - 2)
      )
    }
  }

  private func weekColumn(_ day: WidgetWeekDayPayload) -> some View {
    let date = isoDate(day.date)
    let weekday = date.map { Calendar.current.component(.weekday, from: $0) } ?? 2
    let isToday = date.map { Calendar.current.isDateInToday($0) } ?? false
    return VStack(spacing: 1) {
      Text(day.label)
        .font(.system(size: 8, weight: .semibold))
        .foregroundColor(
          weekday == 1
            ? PlanFlowTheme.holidayText
            : (weekday == 7 ? PlanFlowTheme.saturdayText : PlanFlowTheme.eventText)
        )
      Text(day.date.suffix(5).replacingOccurrences(of: "-", with: "/"))
        .font(.system(size: 8, weight: isToday ? .bold : .regular))
        .foregroundColor(
          isToday ? PlanFlowTheme.todayCircle : PlanFlowTheme.eventText
        )
      if day.events.isEmpty {
        Text("일정 없음")
          .font(.system(size: 7))
          .foregroundColor(PlanFlowTheme.mutedText)
      } else {
        ForEach(Array(day.events.prefix(2).enumerated()), id: \.offset) { _, event in
          Text((event.recurring ? "↻ " : "") + event.title)
            .font(.system(size: 7, weight: event.important ? .bold : .regular))
            .foregroundColor(PlanFlowTheme.eventColor(event))
            .lineLimit(1)
        }
      }
      if let overflow = PlanFlowFormat.overflow(day.overflowCount) {
        Text(overflow)
          .font(.system(size: 7))
          .foregroundColor(PlanFlowTheme.mutedText)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 3)
    .background(
      RoundedRectangle(cornerRadius: 4)
        .fill(isToday ? PlanFlowTheme.panelBackground : Color.clear)
    )
    .link(destination: date.map { PlanFlowWidgetConfig.calendarURL($0) } ?? PlanFlowWidgetConfig.calendarURL())
  }

  private func isoDate(_ raw: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: raw)
  }
}

// MARK: - 5. Weekly list (planflow_weekly_list_widget.xml)

struct PlanFlowWeeklyListWidgetView: View {
  let entry: PlanFlowWidgetEntry

  var body: some View {
    VStack(spacing: 2) {
      HStack {
        Text("주간 일정")
          .font(.system(size: 14, weight: .bold))
          .foregroundColor(PlanFlowTheme.strongText)
        Spacer()
        VoiceChip()
      }
      ForEach(Array(weekDays.enumerated()), id: \.offset) { _, day in
        weekRow(day)
      }
      Spacer(minLength: 0)
    }
    .padding(8)
    .planFlowWidgetBackground()
  }

  private var weekDays: [WidgetWeekDayPayload] {
    PlanFlowWeeklyWidgetView(entry: entry).weekDays
  }

  private func weekRow(_ day: WidgetWeekDayPayload) -> some View {
    let date = isoDate(day.date)
    return HStack(alignment: .top, spacing: 4) {
      Text(date.map { PlanFlowFormat.monthDayWeekday($0) } ?? day.label)
        .font(.system(size: 8, weight: .semibold))
        .foregroundColor(PlanFlowTheme.brandText)
        .frame(width: 44, alignment: .leading)
      if day.events.isEmpty {
        Text("일정 없음")
          .font(.system(size: 7.5))
          .foregroundColor(PlanFlowTheme.mutedText)
      } else {
        // Android: 3 event rows; the 4th slot is always taken by "+N건".
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(day.events.prefix(3).enumerated()), id: \.offset) { _, event in
            Text((event.recurring ? "↻ " : "") + event.title)
              .font(.system(size: 7.5, weight: event.important ? .bold : .regular))
              .foregroundColor(PlanFlowTheme.eventColor(event))
              .lineLimit(1)
          }
          if let overflow = PlanFlowFormat.overflow(day.overflowCount) {
            Text(overflow)
              .font(.system(size: 7.5))
              .foregroundColor(PlanFlowTheme.mutedText)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .link(
      destination: date.map { PlanFlowWidgetConfig.calendarURL($0) }
        ?? PlanFlowWidgetConfig.calendarURL()
    )
  }

  private func isoDate(_ raw: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: raw)
  }
}

// MARK: - 6. Mic / voice launcher (planflow_mic_widget.xml)

struct PlanFlowMicWidgetView: View {
  var body: some View {
    VStack(spacing: 2) {
      ZStack {
        Circle()
          .fill(PlanFlowTheme.panelBackground)
        Circle()
          .stroke(PlanFlowTheme.brandText, lineWidth: 2)
        Image(systemName: "mic.fill")
          .font(.system(size: 18))
          .foregroundColor(PlanFlowTheme.brandText)
      }
      .frame(width: 42, height: 42)
      Text("음성 시작")
        .font(.system(size: 11, weight: .bold))
        .foregroundColor(PlanFlowTheme.brandText)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .widgetURL(PlanFlowWidgetConfig.voiceURL)
    .planFlowWidgetBackground()
  }
}

// MARK: - 7. Group calendar (planflow_group_calendar_widget.xml)

struct PlanFlowGroupCalendarWidgetView: View {
  let entry: PlanFlowWidgetEntry

  var body: some View {
    if let group = PlanFlowWidgetStore.shared.loadGroupCalendar() {
      calendarBody(group)
    } else {
      Link(destination: URL(string: "planflow://group-calendar")!) {
        Text("탭하여 그룹 선택")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(PlanFlowTheme.eventText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .planFlowWidgetBackground()
    }
  }

  private func calendarBody(_ group: PlanFlowWidgetStore.GroupCalendarData) -> some View {
    let days = PlanFlowProjection.monthGridDays(monthStart: entry.date)
    return VStack(spacing: 2) {
      Link(
        destination: URL(
          string: "planflow://group-calendar?groupId=\(group.groupId)"
        )!
      ) {
        HStack {
          Text(group.groupName)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(PlanFlowTheme.strongText)
            .lineLimit(1)
          Spacer()
          Text(monthTitle)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(PlanFlowTheme.eventText)
        }
      }
      WeekdayHeaderRow()
      VStack(spacing: 1) {
        ForEach(0..<6, id: \.self) { row in
          HStack(spacing: 1) {
            ForEach(0..<7, id: \.self) { column in
              let index = row * 7 + column
              if index < days.count {
                groupCell(group, day: days[index])
              } else {
                Color.clear.frame(maxWidth: .infinity)
              }
            }
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(8)
    .planFlowWidgetBackground()
  }

  private var monthTitle: String {
    if let title = PlanFlowWidgetStore.shared.string("gw_month_title") {
      return title
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy년 M월"
    return formatter.string(from: entry.date)
  }

  private func groupCell(
    _ group: PlanFlowWidgetStore.GroupCalendarData, day: Date
  ) -> some View {
    let key = PlanFlowWidgetConfig.ymd(day)
    let members = group.occurrencesByDay[key] ?? []
    // Android MAX_VISIBLE_MEMBERS_PER_CELL = 4, but the last line is
    // replaced by "+N명"; show up to 3 names + the overflow line.
    let visible = Array(members.prefix(3))
    let hidden = max(0, members.count - visible.count)
    return VStack(alignment: .leading, spacing: 0) {
      Text("\(Calendar.current.component(.day, from: day))")
        .font(.system(size: 9, weight: Calendar.current.isDateInToday(day) ? .bold : .regular))
        .foregroundColor(
          dayNumberColor(
            day: day,
            inMonth: PlanFlowProjection.isSameMonth(day, entry.date),
            isHoliday: false,
            isToday: Calendar.current.isDateInToday(day)
          )
        )
      ForEach(Array(visible.enumerated()), id: \.offset) { _, member in
        Text("\(member.0) \(member.1)개")
          .font(.system(size: 6.5))
          .foregroundColor(PlanFlowTheme.teamText)
          .lineLimit(1)
      }
      if hidden > 0 {
        Text("+\(hidden)명")
          .font(.system(size: 6.5))
          .foregroundColor(PlanFlowTheme.teamText)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 2)
        .fill(
          Calendar.current.isDateInToday(day)
            ? PlanFlowTheme.panelBackground : Color.clear
        )
    )
    .link(
      destination: URL(
        string:
          "planflow://group-calendar?groupId=\(group.groupId)&date=\(key)"
      )!
    )
  }
}
