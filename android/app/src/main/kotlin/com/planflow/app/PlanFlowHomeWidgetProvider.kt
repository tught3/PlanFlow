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
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

private const val DEFAULT_TEXT_COLOR = 0xFF203A57.toInt()
private const val MUTED_TEXT_COLOR = 0xFF8FA4B7.toInt()
private const val CRITICAL_TEXT_COLOR = 0xFFD94444.toInt()

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
        val voiceIntent = HomeWidgetLaunchIntent.getActivity(
            context,
            MainActivity::class.java,
            Uri.parse("planflow://voice"),
        )
        views.setOnClickPendingIntent(id, voiceIntent)
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

        val formattedTime = formatShortTime(time)
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
    ) {
        var hasAnyEvent = false

        eventIds.forEachIndexed { index, id ->
            val slot = index + 1
            val title = widgetData.getString("${prefix}_${slot}_title", null)?.takeIf { it.isNotBlank() }
            val time = widgetData.getString("${prefix}_${slot}_time", null)
            val isCritical = widgetData.getBoolean("${prefix}_${slot}_is_critical", false)
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

        bindOpenApp(context, views, R.id.widget_container)
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

        bindEventText(
            views,
            R.id.widget_last_past_event_1_title,
            widgetData.getString("last_past_event_title", null),
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
            ),
            isFaded = false,
            emptyMessageId = R.id.widget_today_upcoming_empty_message,
            emptyMessage = "오늘 남은 일정은 없어요",
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
        )

        bindOpenApp(context, views, R.id.widget_vertical_container)
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
            views.setTextViewText(labelIds[index], formatWeekdayLabel(rawDate, "월"))
            views.setTextViewText(dateIds[index], formatMonthDay(rawDate, ""))

            val e1Title = widgetData.getString("week_day_${slot}_event_1_title", null)
                ?.takeIf { it.isNotBlank() }
            val e2Title = widgetData.getString("week_day_${slot}_event_2_title", null)
                ?.takeIf { it.isNotBlank() }
            val e1Time = widgetData.getString("week_day_${slot}_event_1_time", null)
            val e2Time = widgetData.getString("week_day_${slot}_event_2_time", null)
            val e1Critical = widgetData.getBoolean("week_day_${slot}_event_1_is_critical", false)
            val e2Critical = widgetData.getBoolean("week_day_${slot}_event_2_is_critical", false)

            var overflow = 0
            if (widgetData.contains("week_day_${slot}_overflow_count")) {
                overflow = widgetData.getInt("week_day_${slot}_overflow_count", 0)
            } else {
                val totalCount = widgetData.getInt("week_day_${slot}_count", 0)
                val hasE2 = !e2Title.isNullOrBlank()
                val hasE1 = !e1Title.isNullOrBlank()
                overflow = (totalCount - (if (hasE1) 1 else 0) - (if (hasE2) 1 else 0)).coerceAtLeast(0)
            }

            bindEventText(
                views,
                event1Ids[index],
                e1Title,
                e1Time,
                e1Critical,
                emptyText = if (e1Title == null && e2Title == null && overflow == 0) "일정 없음" else null,
            )
            bindEventText(
                views,
                event2Ids[index],
                e2Title,
                e2Time,
                e2Critical,
            )

            if (overflow > 0) {
                views.setTextViewText(overflowIds[index], "+$overflow")
                views.setViewVisibility(overflowIds[index], View.VISIBLE)
            } else {
                views.setViewVisibility(overflowIds[index], View.GONE)
            }
        }

        bindOpenApp(context, views, R.id.widget_week_container)
        bindVoice(context, views, R.id.widget_week_voice_button)
    }
}

class PlanFlowMonthlyWidgetProvider :
    BasePlanFlowWidgetProvider(R.layout.planflow_monthly_widget) {
    override fun render(
        context: Context,
        views: RemoteViews,
        widgetData: SharedPreferences,
    ) {
        views.setTextViewText(
            R.id.widget_month_title,
            widgetData.getString("month_title", null) ?: "월간 일정",
        )

        for (slot in 1..42) {
            val prefix = "month_cell_${slot}"
            val dayId = findViewId(context, "${prefix}_day")
            val inMonthId = findViewId(context, "${prefix}_in_month")
            val overflowId = findViewId(context, "${prefix}_overflow_count")

            if (dayId == 0) {
                continue
            }

            val dayValue = widgetData.all["${prefix}_day"]?.toString()
            val dayText = dayValue?.trim()?.takeIf { it.isNotBlank() }
            val inMonth = if (widgetData.contains("${prefix}_in_month")) {
                widgetData.getBoolean("${prefix}_in_month", true)
            } else {
                true
            } && dayText != null

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

            var overflow = widgetData.getInt("${prefix}_overflow_count", 0)
            if (overflow > 0) {
                views.setTextViewText(overflowId, "+$overflow")
                views.setViewVisibility(overflowId, if (inMonth) View.VISIBLE else View.GONE)
            } else {
                views.setViewVisibility(overflowId, View.GONE)
            }

            for (eventSlot in 1..3) {
                val eventId = findViewId(context, "${prefix}_event_${eventSlot}_title")
                val title = widgetData.getString("${prefix}_event_${eventSlot}_title", null)?.takeIf { it.isNotBlank() }
                val time = widgetData.getString("${prefix}_event_${eventSlot}_time", null)
                val isCritical = widgetData.getBoolean(
                    "${prefix}_event_${eventSlot}_is_critical",
                    false,
                )
                if (eventId != 0) {
                    bindEventText(
                        views,
                        eventId,
                        if (inMonth) title else null,
                        if (inMonth) time else null,
                        isCritical = isCritical,
                        isMuted = !inMonth,
                    )
                }
            }
        }

        bindOpenApp(context, views, R.id.widget_month_container)
        bindVoice(context, views, R.id.widget_month_voice_button)
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
