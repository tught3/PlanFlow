package com.planflow.app

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

private const val DEFAULT_TEXT_COLOR = 0xFF203A57.toInt()
private const val MUTED_TEXT_COLOR = 0xFF8FA4B7.toInt()
private const val CRITICAL_TEXT_COLOR = 0xFFD94444.toInt()
private const val PLANFLOW_SCHEME = "planflow"
private const val PLANFLOW_CALENDAR_HOST = "calendar"
private const val PLANFLOW_EVENT_HOST = "event"
private const val PLANFLOW_VOICE_LAUNCHER_HOST = "voice-launcher"
private val PLANFLOW_DATE_FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd")

abstract class BasePlanFlowWidgetProvider(
    private val layoutId: Int,
) : HomeWidgetProvider() {
    private val planFlowZone: ZoneId = ZoneId.of("Asia/Seoul")

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, layoutId)
            render(context, views, widgetData)
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    protected abstract fun render(
        context: Context,
        views: RemoteViews,
        widgetData: SharedPreferences,
    )

    protected fun bindOpenApp(context: Context, views: RemoteViews, id: Int) {
        val openAppIntent = HomeWidgetLaunchIntent.getActivity(
            context,
            MainActivity::class.java,
        )
        views.setOnClickPendingIntent(id, openAppIntent)
    }

    protected fun bindVoice(context: Context, views: RemoteViews, id: Int) {
        bindDeepLink(
            context,
            views,
            id,
            Uri.Builder().scheme(PLANFLOW_SCHEME).authority(PLANFLOW_VOICE_LAUNCHER_HOST).build(),
        )
    }

    protected fun bindOpenApp(context: Context, views: RemoteViews, id: Int, route: Uri) {
        bindDeepLink(context, views, id, route)
    }

    protected fun bindDeepLink(
        context: Context,
        views: RemoteViews,
        id: Int,
        route: Uri?,
    ) {
        if (id == 0) {
            return
        }
        if (route == null) {
            return
        }
        val intent = HomeWidgetLaunchIntent.getActivity(
            context,
            MainActivity::class.java,
            route,
        )
        views.setOnClickPendingIntent(id, intent)
    }

    protected fun bindEventLinkIfAvailable(
        context: Context,
        views: RemoteViews,
        id: Int,
        eventId: String?,
        fallbackRoute: Uri? = null,
    ) {
        val route = eventUri(eventId) ?: fallbackRoute
        bindDeepLink(context, views, id, route)
    }

    protected fun bindCalendarLink(
        context: Context,
        views: RemoteViews,
        id: Int,
        date: LocalDate?,
    ) {
        bindDeepLink(context, views, id, calendarUriForDate(date))
    }

    private fun eventUri(eventId: String?): Uri? {
        val normalized = eventId?.trim()
        if (normalized.isNullOrBlank()) {
            return null
        }

        return Uri.Builder().scheme(PLANFLOW_SCHEME).authority(PLANFLOW_EVENT_HOST).appendPath(normalized).build()
    }

    protected fun calendarUriForDate(localDate: LocalDate?): Uri? {
        if (localDate == null) {
            return null
        }

        return Uri.Builder()
            .scheme(PLANFLOW_SCHEME)
            .authority(PLANFLOW_CALENDAR_HOST)
            .appendQueryParameter("date", localDate.format(PLANFLOW_DATE_FORMATTER))
            .build()
    }

    protected fun parseDate(rawDate: String?): LocalDate? {
        val dateTime = parseDateTime(rawDate) ?: return null
        return dateTime.toLocalDate()
    }

    protected fun parseLocalDate(rawDate: String?): LocalDate? {
        if (rawDate.isNullOrBlank()) {
            return null
        }
        return try {
            LocalDate.parse(rawDate, PLANFLOW_DATE_FORMATTER)
        } catch (_: Exception) {
            parseDate(rawDate)
        }
    }

    protected fun todayDate(): LocalDate {
        return LocalDate.now(planFlowZone)
    }

    protected fun hideWeekends(widgetData: SharedPreferences): Boolean {
        return widgetData.getBoolean("widget_hide_weekends", false)
    }

    protected fun isWeekend(date: LocalDate?): Boolean {
        return date?.dayOfWeek == java.time.DayOfWeek.SATURDAY ||
            date?.dayOfWeek == java.time.DayOfWeek.SUNDAY
    }

    protected fun formatTime(raw: String?): String {
        if (raw.isNullOrBlank()) {
            return "시간 미정"
        }

        return try {
            val dateTime = Instant.parse(raw).atZone(planFlowZone)
            DateTimeFormatter.ofPattern("M/d HH:mm", Locale.KOREA).format(dateTime)
        } catch (_: Exception) {
            raw
        }
    }

    protected fun formatShortTime(raw: String?): String {
        if (raw.isNullOrBlank()) {
            return ""
        }

        return try {
            val dateTime = Instant.parse(raw).atZone(planFlowZone)
            DateTimeFormatter.ofPattern("HH:mm", Locale.KOREA).format(dateTime)
        } catch (_: Exception) {
            ""
        }
    }

    protected fun formatHourOnly(raw: String?): String {
        if (raw.isNullOrBlank()) {
            return ""
        }

        return try {
            val dateTime = Instant.parse(raw).atZone(planFlowZone)
            "${dateTime.hour}시"
        } catch (_: Exception) {
            ""
        }
    }

    protected fun formatWeekdayLabel(raw: String?, fallback: String): String {
        if (raw.isNullOrBlank()) {
            return fallback
        }

        return try {
            val dateTime = Instant.parse(raw).atZone(planFlowZone)
            DateTimeFormatter.ofPattern("E", Locale.KOREA).format(dateTime)
        } catch (_: Exception) {
            fallback
        }
    }

    protected fun formatMonthDay(raw: String?, fallback: String): String {
        if (raw.isNullOrBlank()) {
            return fallback
        }

        return try {
            val dateTime = Instant.parse(raw).atZone(planFlowZone)
            DateTimeFormatter.ofPattern("M/d", Locale.KOREA).format(dateTime)
        } catch (_: Exception) {
            fallback
        }
    }

    protected fun formatMonthDayWithWeekday(date: LocalDate): String {
        return DateTimeFormatter.ofPattern("M/d(E)", Locale.KOREA).format(date)
    }

    protected fun formatTravelMinutes(travelMinutes: Int?): String {
        if (travelMinutes == null || travelMinutes <= 0) {
            return ""
        }
        return "출발 ${travelMinutes}분 전"
    }

    protected fun formatDepartureTime(startAt: String?, travelMinutes: Int?): String {
        if (travelMinutes == null || travelMinutes <= 0) {
            return ""
        }

        val dateTime = parseDateTime(startAt) ?: return ""
        val departureAt = dateTime.minusMinutes(travelMinutes.toLong())
        return "알림: ${DateTimeFormatter.ofPattern("HH:mm", Locale.KOREA).format(departureAt)}"
    }

    protected fun formatCountdown(startAt: String?): String {
        val dateTime = parseDateTime(startAt) ?: return ""
        val now = ZonedDateTime.now(planFlowZone)
        val minutes = Duration.between(now, dateTime).toMinutes()
        if (minutes <= 0) {
            return ""
        }
        return "D-${minutes}분"
    }

    private fun parseDateTime(raw: String?): ZonedDateTime? {
        if (raw.isNullOrBlank()) {
            return null
        }

        return try {
            Instant.parse(raw).atZone(planFlowZone)
        } catch (_: Exception) {
            null
        }
    }

    protected fun bindTextIfNotEmpty(
        views: RemoteViews,
        id: Int,
        text: String,
    ) {
        if (text.isBlank()) {
            views.setViewVisibility(id, View.GONE)
            return
        }
        views.setTextViewText(id, text)
        views.setViewVisibility(id, View.VISIBLE)
    }

    protected fun bindEventText(
        views: RemoteViews,
        id: Int,
        title: String?,
        time: String?,
        isCritical: Boolean,
        isMuted: Boolean = false,
        emptyText: String? = null,
        hourOnly: Boolean = false,
    ) {
        val text = title?.trim()?.takeIf { it.isNotBlank() }
        if (text.isNullOrBlank()) {
            if (emptyText == null) {
                views.setViewVisibility(id, View.GONE)
                return
            }
            views.setTextViewText(id, emptyText)
            views.setTextColor(id, MUTED_TEXT_COLOR)
            views.setViewVisibility(id, View.VISIBLE)
            return
        }

        val formattedTime = if (hourOnly) formatHourOnly(time) else formatShortTime(time)
        val content = if (formattedTime.isBlank()) text else "$formattedTime  $text"
        views.setTextViewText(id, content)
        views.setTextColor(
            id,
            if (isMuted) MUTED_TEXT_COLOR else if (isCritical) CRITICAL_TEXT_COLOR else DEFAULT_TEXT_COLOR,
        )
        views.setViewVisibility(id, View.VISIBLE)
    }

    protected fun bindTimelineItem(
        views: RemoteViews,
        id: Int,
        slot: Int,
        widgetData: SharedPreferences,
    ) {
        val title = widgetData.getString("event_list_${slot}_title", null)
            ?.takeIf { it.isNotBlank() }
            ?: return when (slot) {
                1 -> {
                    views.setTextViewText(id, "남은 일정 없음")
                    views.setTextColor(id, DEFAULT_TEXT_COLOR)
                    views.setViewVisibility(id, View.VISIBLE)
                }
                else -> {
                    views.setViewVisibility(id, View.GONE)
                    return
                }
            }

        val isCritical = widgetData.getBoolean("event_list_${slot}_is_critical", false)
        val rawTime = widgetData.getString("event_list_${slot}_time", null)
        bindEventText(views, id, title, rawTime, isCritical)
    }

    protected fun findViewId(context: Context, idName: String): Int {
        return context.resources.getIdentifier(idName, "id", context.packageName)
    }

    protected fun bindSectionEvents(
        context: Context,
        views: RemoteViews,
        widgetData: SharedPreferences,
        prefix: String,
        eventIds: IntArray,
        isFaded: Boolean,
        emptyMessageId: Int? = null,
        emptyMessage: String? = null,
        hideWeekendEvents: Boolean = false,
    ) {
        var hasAnyEvent = false

        eventIds.forEachIndexed { index, id ->
            val slot = index + 1
            var title = widgetData.getString("${prefix}_${slot}_title", null)?.takeIf { it.isNotBlank() }
            val time = widgetData.getString("${prefix}_${slot}_time", null)
            val isCritical = widgetData.getBoolean("${prefix}_${slot}_is_critical", false)
            if (hideWeekendEvents && isWeekend(parseDate(time))) {
                title = null
            }
            if (!title.isNullOrBlank()) {
                hasAnyEvent = true
            }
            bindEventText(views, id, title, time, isCritical, isFaded)
        }

        if (emptyMessageId != null) {
            if (hasAnyEvent) {
                views.setViewVisibility(emptyMessageId, View.GONE)
            } else if (emptyMessage != null) {
                views.setTextViewText(emptyMessageId, emptyMessage)
                views.setTextColor(emptyMessageId, MUTED_TEXT_COLOR)
                views.setViewVisibility(emptyMessageId, View.VISIBLE)
            } else {
                views.setViewVisibility(emptyMessageId, View.GONE)
            }
        }
    }
}

class PlanFlowHomeWidgetProvider : BasePlanFlowWidgetProvider(R.layout.planflow_home_widget) {
    override fun render(
        context: Context,
        views: RemoteViews,
        widgetData: SharedPreferences,
    ) {
        val title = widgetData.getString("next_event_title", null) ?: "오늘 첫 일정"
        val location = widgetData.getString("next_event_location", null) ?: "입력으로 일정 추가"
        val startAt = widgetData.getString("next_event_start_at", null)
        val isCritical = widgetData.getBoolean("next_event_is_critical", false)
        val travelMinutes = if (widgetData.contains("next_event_travel_buffer_minutes")) {
            widgetData.getInt("next_event_travel_buffer_minutes", 0)
        } else {
            null
        }

        views.setTextViewText(R.id.widget_title, title)
        views.setTextViewText(R.id.widget_time, formatTime(startAt))
        views.setTextViewText(R.id.widget_location, location)
        bindTextIfNotEmpty(views, R.id.widget_travel_minutes, formatTravelMinutes(travelMinutes))
        bindTextIfNotEmpty(views, R.id.widget_departure, formatDepartureTime(startAt, travelMinutes))
        bindTextIfNotEmpty(views, R.id.widget_countdown, formatCountdown(startAt))

        if (isCritical) {
            views.setTextViewText(R.id.widget_badge, "긴급 일정")
            views.setInt(
                R.id.widget_badge,
                "setBackgroundResource",
                R.drawable.widget_critical_badge_background,
            )
            views.setTextColor(R.id.widget_badge, CRITICAL_TEXT_COLOR)
        } else {
            views.setTextViewText(R.id.widget_badge, "오늘 일정")
            views.setInt(
                R.id.widget_badge,
                "setBackgroundResource",
                R.drawable.widget_normal_badge_background,
            )
            views.setTextColor(R.id.widget_badge, DEFAULT_TEXT_COLOR)
        }

        bindTimelineItem(views, R.id.widget_list_item_1, 1, widgetData)
        bindTimelineItem(views, R.id.widget_list_item_2, 2, widgetData)
        bindTimelineItem(views, R.id.widget_list_item_3, 3, widgetData)

        bindEventLinkIfAvailable(
            context,
            views,
            R.id.widget_container,
            widgetData.getString("next_event_id", null),
            Uri.Builder().scheme(PLANFLOW_SCHEME).authority(PLANFLOW_CALENDAR_HOST).build(),
        )
        bindCalendarLink(context, views, R.id.widget_brand, todayDate())
        bindCalendarLink(context, views, R.id.widget_next_panel, todayDate())
        bindEventLinkIfAvailable(
            context,
            views,
            R.id.widget_list_item_1,
            widgetData.getString("event_list_1_id", null),
        )
        bindEventLinkIfAvailable(
            context,
            views,
            R.id.widget_list_item_2,
            widgetData.getString("event_list_2_id", null),
        )
        bindEventLinkIfAvailable(
            context,
            views,
            R.id.widget_list_item_3,
            widgetData.getString("event_list_3_id", null),
        )
        bindVoice(context, views, R.id.widget_voice_button)
    }
}

class PlanFlowVerticalScheduleWidgetProvider :
    BasePlanFlowWidgetProvider(R.layout.planflow_vertical_schedule_widget) {
    override fun render(
        context: Context,
        views: RemoteViews,
        widgetData: SharedPreferences,
    ) {
        views.setTextViewText(R.id.widget_vertical_title, "오늘 일정")
        val hideWeekendEvents = hideWeekends(widgetData)

        bindEventText(
            views,
            R.id.widget_last_past_event_1_title,
            widgetData.getString("last_past_event_title", null)
                ?.takeUnless {
                    hideWeekendEvents &&
                        isWeekend(parseDate(widgetData.getString("last_past_event_time", null)))
                },
            widgetData.getString("last_past_event_time", null),
            widgetData.getBoolean("last_past_event_is_critical", false),
            isMuted = true,
        )
        views.setViewVisibility(R.id.widget_last_past_event_2_title, View.GONE)

        bindSectionEvents(
            context,
            views,
            widgetData,
            "today_upcoming",
            intArrayOf(
                R.id.widget_today_upcoming_event_1_title,
                R.id.widget_today_upcoming_event_2_title,
                R.id.widget_today_upcoming_event_3_title,
                R.id.widget_today_upcoming_event_4_title,
                R.id.widget_today_upcoming_event_5_title,
                R.id.widget_today_upcoming_event_6_title,
            ),
            isFaded = false,
            emptyMessageId = R.id.widget_today_upcoming_empty_message,
            emptyMessage = "오늘 남은 일정은 없어요",
            hideWeekendEvents = hideWeekendEvents,
        )

        bindSectionEvents(
            context,
            views,
            widgetData,
            "tomorrow_event",
            intArrayOf(
                R.id.widget_tomorrow_event_1_title,
                R.id.widget_tomorrow_event_2_title,
            ),
            isFaded = false,
            hideWeekendEvents = hideWeekendEvents,
        )
        val tomorrowCount = if (hideWeekendEvents) {
            (1..2).count { slot ->
                !widgetData.getString("tomorrow_event_${slot}_title", null).isNullOrBlank() &&
                    !isWeekend(parseDate(widgetData.getString("tomorrow_event_${slot}_time", null)))
            }
        } else {
            widgetData.getInt("tomorrow_event_count", 0)
        }
        views.setViewVisibility(
            R.id.widget_tomorrow_section_label,
            if (tomorrowCount > 0) View.VISIBLE else View.GONE,
        )

        bindCalendarLink(
            context,
            views,
            R.id.widget_vertical_container,
            todayDate(),
        )
        bindCalendarLink(context, views, R.id.widget_vertical_title, todayDate())
        bindCalendarLink(context, views, R.id.widget_tomorrow_section_label, todayDate())
        bindEventLinkIfAvailable(
            context,
            views,
            R.id.widget_last_past_event_1_title,
            widgetData.getString("last_past_event_id", null),
        )
        bindEventLinkIfAvailable(
            context,
            views,
            R.id.widget_today_upcoming_event_1_title,
            widgetData.getString("today_upcoming_1_id", null),
        )
        bindEventLinkIfAvailable(
            context,
            views,
            R.id.widget_today_upcoming_event_2_title,
            widgetData.getString("today_upcoming_2_id", null),
        )
        bindEventLinkIfAvailable(
            context,
            views,
            R.id.widget_today_upcoming_event_3_title,
            widgetData.getString("today_upcoming_3_id", null),
        )
        bindEventLinkIfAvailable(
            context,
            views,
            R.id.widget_today_upcoming_event_4_title,
            widgetData.getString("today_upcoming_4_id", null),
        )
        bindEventLinkIfAvailable(
            context,
            views,
            R.id.widget_today_upcoming_event_5_title,
            widgetData.getString("today_upcoming_5_id", null),
        )
        bindEventLinkIfAvailable(
            context,
            views,
            R.id.widget_today_upcoming_event_6_title,
            widgetData.getString("today_upcoming_6_id", null),
        )
        bindEventLinkIfAvailable(
            context,
            views,
            R.id.widget_tomorrow_event_1_title,
            widgetData.getString("tomorrow_event_1_id", null),
        )
        bindEventLinkIfAvailable(
            context,
            views,
            R.id.widget_tomorrow_event_2_title,
            widgetData.getString("tomorrow_event_2_id", null),
        )
        bindVoice(context, views, R.id.widget_vertical_voice_button)
    }
}

class PlanFlowWeeklyWidgetProvider :
    BasePlanFlowWidgetProvider(R.layout.planflow_weekly_widget) {
    override fun render(
        context: Context,
        views: RemoteViews,
        widgetData: SharedPreferences,
    ) {
        views.setTextViewText(R.id.widget_week_title, "주간 일정")
        val hideWeekendColumns = hideWeekends(widgetData)
        val weekStart = todayDate().minusDays((todayDate().dayOfWeek.value - 1).toLong())
        val weekColumnIds = intArrayOf(
            R.id.widget_week_day_1_column,
            R.id.widget_week_day_2_column,
            R.id.widget_week_day_3_column,
            R.id.widget_week_day_4_column,
            R.id.widget_week_day_5_column,
            R.id.widget_week_day_6_column,
            R.id.widget_week_day_7_column,
        )

        val labelIds = intArrayOf(
            R.id.widget_week_day_1_label,
            R.id.widget_week_day_2_label,
            R.id.widget_week_day_3_label,
            R.id.widget_week_day_4_label,
            R.id.widget_week_day_5_label,
            R.id.widget_week_day_6_label,
            R.id.widget_week_day_7_label,
        )
        val dateIds = intArrayOf(
            R.id.widget_week_day_1_date,
            R.id.widget_week_day_2_date,
            R.id.widget_week_day_3_date,
            R.id.widget_week_day_4_date,
            R.id.widget_week_day_5_date,
            R.id.widget_week_day_6_date,
            R.id.widget_week_day_7_date,
        )
        val event1Ids = intArrayOf(
            R.id.widget_week_day_1_event_1,
            R.id.widget_week_day_2_event_1,
            R.id.widget_week_day_3_event_1,
            R.id.widget_week_day_4_event_1,
            R.id.widget_week_day_5_event_1,
            R.id.widget_week_day_6_event_1,
            R.id.widget_week_day_7_event_1,
        )
        val event2Ids = intArrayOf(
            R.id.widget_week_day_1_event_2,
            R.id.widget_week_day_2_event_2,
            R.id.widget_week_day_3_event_2,
            R.id.widget_week_day_4_event_2,
            R.id.widget_week_day_5_event_2,
            R.id.widget_week_day_6_event_2,
            R.id.widget_week_day_7_event_2,
        )
        val event3Ids = intArrayOf(
            R.id.widget_week_day_1_event_3,
            R.id.widget_week_day_2_event_3,
            R.id.widget_week_day_3_event_3,
            R.id.widget_week_day_4_event_3,
            R.id.widget_week_day_5_event_3,
            R.id.widget_week_day_6_event_3,
            R.id.widget_week_day_7_event_3,
        )
        val event4Ids = intArrayOf(
            R.id.widget_week_day_1_event_4,
            R.id.widget_week_day_2_event_4,
            R.id.widget_week_day_3_event_4,
            R.id.widget_week_day_4_event_4,
            R.id.widget_week_day_5_event_4,
            R.id.widget_week_day_6_event_4,
            R.id.widget_week_day_7_event_4,
        )
        val overflowIds = intArrayOf(
            R.id.widget_week_day_1_overflow,
            R.id.widget_week_day_2_overflow,
            R.id.widget_week_day_3_overflow,
            R.id.widget_week_day_4_overflow,
            R.id.widget_week_day_5_overflow,
            R.id.widget_week_day_6_overflow,
            R.id.widget_week_day_7_overflow,
        )

        for (index in 0 until 7) {
            val slot = index + 1
            val rawDate = widgetData.getString("week_day_${slot}_date", null)
            val fallbackDate = weekStart.plusDays(index.toLong())
            val targetDate = parseLocalDate(rawDate) ?: fallbackDate
            if (hideWeekendColumns && isWeekend(targetDate)) {
                views.setViewVisibility(weekColumnIds[index], View.GONE)
                continue
            }
            views.setViewVisibility(weekColumnIds[index], View.VISIBLE)
            views.setTextViewText(labelIds[index], formatWeekdayLabel(rawDate, "월"))
            views.setTextViewText(dateIds[index], formatMonthDay(rawDate, ""))
            bindCalendarLink(
                context,
                views,
                weekColumnIds[index],
                targetDate,
            )

            val e1Title = widgetData.getString("week_day_${slot}_event_1_title", null)
                ?.takeIf { it.isNotBlank() }
            val e2Title = widgetData.getString("week_day_${slot}_event_2_title", null)
                ?.takeIf { it.isNotBlank() }
            val e3Title = widgetData.getString("week_day_${slot}_event_3_title", null)
                ?.takeIf { it.isNotBlank() }
            val e4Title = widgetData.getString("week_day_${slot}_event_4_title", null)
                ?.takeIf { it.isNotBlank() }
            val e1Time = widgetData.getString("week_day_${slot}_event_1_time", null)
            val e2Time = widgetData.getString("week_day_${slot}_event_2_time", null)
            val e3Time = widgetData.getString("week_day_${slot}_event_3_time", null)
            val e4Time = widgetData.getString("week_day_${slot}_event_4_time", null)
            val e1Critical = widgetData.getBoolean("week_day_${slot}_event_1_is_critical", false)
            val e2Critical = widgetData.getBoolean("week_day_${slot}_event_2_is_critical", false)
            val e3Critical = widgetData.getBoolean("week_day_${slot}_event_3_is_critical", false)
            val e4Critical = widgetData.getBoolean("week_day_${slot}_event_4_is_critical", false)

            var overflow = 0
            if (widgetData.contains("week_day_${slot}_overflow_count")) {
                overflow = widgetData.getInt("week_day_${slot}_overflow_count", 0)
            } else {
                val totalCount = widgetData.getInt("week_day_${slot}_count", 0)
                val hasE1 = !e1Title.isNullOrBlank()
                val hasE2 = !e2Title.isNullOrBlank()
                val hasE3 = !e3Title.isNullOrBlank()
                val hasE4 = !e4Title.isNullOrBlank()
                overflow = (
                    totalCount -
                        (if (hasE1) 1 else 0) -
                        (if (hasE2) 1 else 0) -
                        (if (hasE3) 1 else 0) -
                        (if (hasE4) 1 else 0)
                    ).coerceAtLeast(0)
            }

            bindEventText(
                views,
                event1Ids[index],
                e1Title,
                e1Time,
                e1Critical,
                emptyText = if (e1Title == null && e2Title == null && overflow == 0) "일정 없음" else null,
                hourOnly = true,
            )
            bindEventText(
                views,
                event2Ids[index],
                e2Title,
                e2Time,
                e2Critical,
                hourOnly = true,
            )
            bindEventText(
                views,
                event3Ids[index],
                e3Title,
                e3Time,
                e3Critical,
                hourOnly = true,
            )
            bindEventText(
                views,
                event4Ids[index],
                e4Title,
                e4Time,
                e4Critical,
                hourOnly = true,
            )
            bindEventLinkIfAvailable(
                context,
                views,
                event1Ids[index],
                widgetData.getString("week_day_${slot}_event_1_id", null),
            )
            bindEventLinkIfAvailable(
                context,
                views,
                event2Ids[index],
                widgetData.getString("week_day_${slot}_event_2_id", null),
            )
            bindEventLinkIfAvailable(
                context,
                views,
                event3Ids[index],
                widgetData.getString("week_day_${slot}_event_3_id", null),
            )
            bindEventLinkIfAvailable(
                context,
                views,
                event4Ids[index],
                widgetData.getString("week_day_${slot}_event_4_id", null),
            )

            if (overflow > 0) {
                views.setTextViewText(overflowIds[index], "+$overflow")
                views.setViewVisibility(overflowIds[index], View.VISIBLE)
            } else {
                views.setViewVisibility(overflowIds[index], View.GONE)
            }
        }

        bindCalendarLink(context, views, R.id.widget_week_container, todayDate())
        bindCalendarLink(context, views, R.id.widget_week_title, todayDate())
        bindVoice(context, views, R.id.widget_week_voice_button)
    }
}

class PlanFlowWeeklyListWidgetProvider :
    BasePlanFlowWidgetProvider(R.layout.planflow_weekly_list_widget) {
    override fun render(
        context: Context,
        views: RemoteViews,
        widgetData: SharedPreferences,
    ) {
        views.setTextViewText(R.id.widget_week_list_title, "주간 일정")
        val hideWeekendRows = hideWeekends(widgetData)
        val weekStart = todayDate().minusDays((todayDate().dayOfWeek.value - 1).toLong())

        for (index in 0 until 7) {
            val slot = index + 1
            val rawDate = widgetData.getString("week_day_${slot}_date", null)
            val fallbackDate = weekStart.plusDays(index.toLong())
            val targetDate = parseLocalDate(rawDate) ?: fallbackDate

            val rowId = findViewId(context, "widget_week_list_day_${slot}_row")
            val labelId = findViewId(context, "widget_week_list_day_${slot}_label")
            val overflowId = findViewId(context, "widget_week_list_day_${slot}_overflow")
            if (rowId == 0 || labelId == 0 || overflowId == 0) {
                continue
            }
            if (hideWeekendRows && isWeekend(targetDate)) {
                views.setViewVisibility(rowId, View.GONE)
                continue
            }
            views.setViewVisibility(rowId, View.VISIBLE)

            views.setTextViewText(
                labelId,
                formatMonthDayWithWeekday(targetDate),
            )
            bindCalendarLink(context, views, rowId, targetDate)

            var shownCount = 0
            for (eventSlot in 1..4) {
                val eventId = findViewId(context, "widget_week_list_day_${slot}_event_${eventSlot}")
                if (eventId == 0) {
                    continue
                }
                val title = widgetData.getString("week_day_${slot}_event_${eventSlot}_title", null)
                    ?.takeIf { it.isNotBlank() }
                val time = widgetData.getString("week_day_${slot}_event_${eventSlot}_time", null)
                val isCritical =
                    widgetData.getBoolean("week_day_${slot}_event_${eventSlot}_is_critical", false)
                if (!title.isNullOrBlank()) {
                    shownCount += 1
                }
                bindEventText(
                    views,
                    eventId,
                    title,
                    time,
                    isCritical,
                    emptyText = if (eventSlot == 1) "일정 없음" else null,
                )
                bindEventLinkIfAvailable(
                    context,
                    views,
                    eventId,
                    widgetData.getString("week_day_${slot}_event_${eventSlot}_id", null),
                )
            }

            val overflow = if (widgetData.contains("week_day_${slot}_overflow_count")) {
                widgetData.getInt("week_day_${slot}_overflow_count", 0)
            } else {
                (widgetData.getInt("week_day_${slot}_count", 0) - shownCount).coerceAtLeast(0)
            }
            if (overflow > 0) {
                views.setTextViewText(overflowId, "+$overflow")
                views.setViewVisibility(overflowId, View.VISIBLE)
            } else {
                views.setViewVisibility(overflowId, View.GONE)
            }
        }

        bindCalendarLink(context, views, R.id.widget_week_list_container, todayDate())
        bindCalendarLink(context, views, R.id.widget_week_list_title, todayDate())
        bindVoice(context, views, R.id.widget_week_list_voice_button)
    }
}

class PlanFlowMonthlyWidgetProvider :
    BasePlanFlowWidgetProvider(R.layout.planflow_monthly_widget) {
    override fun render(
        context: Context,
        views: RemoteViews,
        widgetData: SharedPreferences,
    ) {
        val hasMonthCellPayload = hasMonthCellPayload(widgetData)
        val hideWeekendCells = hideWeekends(widgetData)
        val monthStart = LocalDate.now(ZoneId.of("Asia/Seoul")).withDayOfMonth(1)
        val fallbackCells = buildCurrentMonthFallbackCells(monthStart)

        views.setTextViewText(
            R.id.widget_month_title,
            widgetData.getString("month_title", null) ?: fallbackMonthTitle(),
        )

        for (slot in 1..42) {
            val prefix = "month_cell_${slot}"
            val dayId = findViewId(context, "${prefix}_day")
            val cellContainerId = findViewId(context, "${prefix}_container")
            val cellDate = parseLocalDate(widgetData.getString("${prefix}_date", null))
            val inMonthId = findViewId(context, "${prefix}_in_month")
            val overflowId = findViewId(context, "${prefix}_overflow_count")
            val fallbackCell = fallbackCells?.getOrNull(slot - 1)
            val targetDate = cellDate ?: fallbackCell?.third

            if (dayId == 0) {
                continue
            }
            if (cellContainerId != 0) {
                views.setViewVisibility(
                    cellContainerId,
                    if (hideWeekendCells && isWeekend(targetDate)) View.GONE else View.VISIBLE,
                )
            }
            if (hideWeekendCells && isWeekend(targetDate)) {
                continue
            }

            val dayValue = widgetData.all["${prefix}_day"]?.toString()
            val dayText = if (hasMonthCellPayload) {
                dayValue?.trim()?.takeIf { it.isNotBlank() }
            } else {
                fallbackCell?.first?.toString()
            }
            val inMonth = if (hasMonthCellPayload) {
                if (widgetData.contains("${prefix}_in_month")) {
                    widgetData.getBoolean("${prefix}_in_month", false)
                } else {
                    false
                } && dayText != null
            } else {
                fallbackCell?.second ?: false
            }

            var overflow = if (hasMonthCellPayload) {
                widgetData.getInt("${prefix}_overflow_count", 0)
            } else {
                0
            }

            views.setTextViewText(dayId, dayText ?: "")
            views.setViewVisibility(dayId, if (dayText == null) View.INVISIBLE else View.VISIBLE)
            if (inMonth) {
                views.setTextColor(dayId, DEFAULT_TEXT_COLOR)
            } else {
                views.setTextColor(dayId, MUTED_TEXT_COLOR)
            }

            if (inMonthId != 0) {
                views.setTextViewText(
                    inMonthId,
                    "",
                )
                views.setTextColor(inMonthId, MUTED_TEXT_COLOR)
                views.setViewVisibility(inMonthId, View.GONE)
            }

            bindCalendarLink(context, views, cellContainerId, targetDate)

            if (overflow > 0) {
                views.setTextViewText(overflowId, "+$overflow")
                views.setViewVisibility(overflowId, if (inMonth) View.VISIBLE else View.GONE)
            } else {
                views.setViewVisibility(overflowId, View.GONE)
            }

            for (eventSlot in 1..3) {
                val eventId = findViewId(context, "${prefix}_event_${eventSlot}_title")
                val eventTitle =
                    if (hasMonthCellPayload) {
                        widgetData.getString("${prefix}_event_${eventSlot}_title", null)
                            ?.takeIf { it.isNotBlank() }
                    } else {
                        null
                    }
                val eventTime =
                    if (hasMonthCellPayload) {
                        widgetData.getString("${prefix}_event_${eventSlot}_time", null)
                    } else {
                        null
                    }
                val eventCritical = if (hasMonthCellPayload) {
                    widgetData.getBoolean("${prefix}_event_${eventSlot}_is_critical", false)
                } else {
                    false
                }
                if (eventId != 0) {
                    bindEventText(
                        views,
                        eventId,
                        if (inMonth) eventTitle else null,
                        if (inMonth) eventTime else null,
                        isCritical = eventCritical,
                        isMuted = !inMonth,
                    )
                    bindEventLinkIfAvailable(
                        context,
                        views,
                        eventId,
                        widgetData.getString("${prefix}_event_${eventSlot}_id", null),
                        if (inMonth) calendarUriForDate(targetDate) else null,
                    )
                }
            }
        }

        bindCalendarLink(context, views, R.id.widget_month_container, todayDate())
        bindCalendarLink(context, views, R.id.widget_month_title, todayDate())
        bindVoice(context, views, R.id.widget_month_voice_button)
    }

    private fun hasMonthCellPayload(widgetData: SharedPreferences): Boolean {
        for (slot in 1..42) {
            if (widgetData.contains("month_cell_${slot}_day")) {
                return true
            }
        }
        return false
    }

    private fun buildCurrentMonthFallbackCells(monthStart: LocalDate): List<Triple<Int, Boolean, LocalDate>> {
        val startOffset = monthStart.dayOfWeek.value % 7
        val firstCellDate = monthStart.minusDays(startOffset.toLong())
        return List(42) { index ->
            val day = firstCellDate.plusDays(index.toLong())
            val inMonth = day.year == monthStart.year && day.month == monthStart.month
            Triple(day.dayOfMonth, inMonth, day)
        }
    }

    private fun fallbackMonthTitle(): String {
        val now = LocalDate.now(ZoneId.of("Asia/Seoul"))
        return "${now.year}년 ${now.monthValue}월"
    }
}

class PlanFlowMicWidgetProvider : BasePlanFlowWidgetProvider(R.layout.planflow_mic_widget) {
    override fun render(
        context: Context,
        views: RemoteViews,
        widgetData: SharedPreferences,
    ) {
        bindVoice(context, views, R.id.widget_mic_container)
    }
}
