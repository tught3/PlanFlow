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

    protected fun formatWeekday(raw: String?, fallback: String): String {
        if (raw.isNullOrBlank()) {
            return fallback
        }

        return try {
            val dateTime = Instant.parse(raw).atZone(planFlowZone)
            DateTimeFormatter.ofPattern("E M/d", Locale.KOREA).format(dateTime)
        } catch (_: Exception) {
            fallback
        }
    }

    protected fun formatTravelMinutes(travelMinutes: Int?): String {
        if (travelMinutes == null || travelMinutes <= 0) {
            return ""
        }
        return "이동: ${travelMinutes}분"
    }

    protected fun formatDepartureTime(startAt: String?, travelMinutes: Int?): String {
        if (travelMinutes == null || travelMinutes <= 0) {
            return ""
        }

        val dateTime = parseDateTime(startAt) ?: return ""
        val departureAt = dateTime.minusMinutes(travelMinutes.toLong())
        return "출발: ${DateTimeFormatter.ofPattern("HH:mm", Locale.KOREA).format(departureAt)}"
    }

    protected fun formatCountdown(startAt: String?): String {
        val dateTime = parseDateTime(startAt) ?: return ""
        val now = ZonedDateTime.now(planFlowZone)
        val minutes = Duration.between(now, dateTime).toMinutes()
        if (minutes <= 0) {
            return ""
        }
        return "남은 시간: ${minutes}분"
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

    protected fun formatTimelineItem(widgetData: SharedPreferences, slot: Int): Pair<String, Boolean> {
        val title = widgetData.getString("event_list_${slot}_title", null)
            ?.takeIf { it.isNotBlank() }
            ?: return when (slot) {
                1 -> Pair("남은 일정이 없어요", false)
                else -> Pair("", false)
            }
        val isCritical = widgetData.getBoolean("event_list_${slot}_is_critical", false)
        val rawTime = widgetData.getString("event_list_${slot}_time", null)
        val time = formatShortTime(rawTime)
        val prefix = if (isCritical) "중요 " else ""
        val text = if (time.isBlank()) "$prefix$title" else "$time  $prefix$title"
        return Pair(text, isCritical)
    }

    protected fun bindTimelineItem(
        views: RemoteViews,
        id: Int,
        slot: Int,
        widgetData: SharedPreferences,
    ) {
        val (text, isCritical) = formatTimelineItem(widgetData, slot)
        if (text.isBlank()) {
            views.setViewVisibility(id, View.GONE)
            return
        }

        views.setTextViewText(id, text)
        views.setTextColor(id, if (isCritical) CRITICAL_TEXT_COLOR else DEFAULT_TEXT_COLOR)
        views.setViewVisibility(id, View.VISIBLE)
    }
}

class PlanFlowHomeWidgetProvider : BasePlanFlowWidgetProvider(R.layout.planflow_home_widget) {
    override fun render(
        context: Context,
        views: RemoteViews,
        widgetData: SharedPreferences,
    ) {
        val title = widgetData.getString("next_event_title", null)
            ?: "오늘 다음 일정이 없어요"
        val location = widgetData.getString("next_event_location", null)
            ?: "음성으로 일정을 추가해 보세요"
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
            views.setTextViewText(R.id.widget_badge, "중요 일정")
            views.setInt(
                R.id.widget_badge,
                "setBackgroundResource",
                R.drawable.widget_critical_badge_background,
            )
            views.setTextColor(R.id.widget_badge, CRITICAL_TEXT_COLOR)
        } else {
            views.setTextViewText(R.id.widget_badge, "다음 일정")
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
        views.setTextViewText(R.id.widget_vertical_title, "오늘 남은 일정")
        views.setTextViewText(
            R.id.widget_vertical_subtitle,
            widgetData.getString("next_event_title", null)?.let { "현재 다음: $it" }
                ?: "음성으로 일정을 추가해 보세요",
        )

        val ids = intArrayOf(
            R.id.widget_today_item_1,
            R.id.widget_today_item_2,
            R.id.widget_today_item_3,
            R.id.widget_today_item_4,
            R.id.widget_today_item_5,
            R.id.widget_today_item_6,
        )
        ids.forEachIndexed { index, id ->
            bindTimelineItem(views, id, index + 1, widgetData)
        }

        bindOpenApp(context, views, R.id.widget_vertical_container)
        bindVoice(context, views, R.id.widget_vertical_voice_button)
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
            widgetData.getString("month_title", null) ?: "이번 달",
        )

        val ids = intArrayOf(
            R.id.widget_month_day_1,
            R.id.widget_month_day_2,
            R.id.widget_month_day_3,
            R.id.widget_month_day_4,
            R.id.widget_month_day_5,
            R.id.widget_month_day_6,
            R.id.widget_month_day_7,
            R.id.widget_month_day_8,
            R.id.widget_month_day_9,
            R.id.widget_month_day_10,
            R.id.widget_month_day_11,
            R.id.widget_month_day_12,
            R.id.widget_month_day_13,
            R.id.widget_month_day_14,
            R.id.widget_month_day_15,
            R.id.widget_month_day_16,
            R.id.widget_month_day_17,
            R.id.widget_month_day_18,
            R.id.widget_month_day_19,
            R.id.widget_month_day_20,
            R.id.widget_month_day_21,
            R.id.widget_month_day_22,
            R.id.widget_month_day_23,
            R.id.widget_month_day_24,
            R.id.widget_month_day_25,
            R.id.widget_month_day_26,
            R.id.widget_month_day_27,
            R.id.widget_month_day_28,
            R.id.widget_month_day_29,
            R.id.widget_month_day_30,
            R.id.widget_month_day_31,
        )

        ids.forEachIndexed { index, id ->
            val day = index + 1
            val count = widgetData.getInt("month_day_${day}_count", 0)
            val hasCritical = widgetData.getBoolean("month_day_${day}_has_critical", false)
            views.setTextViewText(
                id,
                if (count <= 0) {
                    "$day"
                } else {
                    "$day\n${count}건${if (hasCritical) " · 중요" else ""}"
                },
            )
            views.setTextColor(id, if (hasCritical) CRITICAL_TEXT_COLOR else DEFAULT_TEXT_COLOR)
        }

        bindOpenApp(context, views, R.id.widget_month_container)
        bindVoice(context, views, R.id.widget_month_voice_button)
    }
}

class PlanFlowWeeklyWidgetProvider :
    BasePlanFlowWidgetProvider(R.layout.planflow_weekly_widget) {
    override fun render(
        context: Context,
        views: RemoteViews,
        widgetData: SharedPreferences,
    ) {
        views.setTextViewText(R.id.widget_week_title, "이번 주 일정")

        val labelIds = intArrayOf(
            R.id.widget_week_day_1_label,
            R.id.widget_week_day_2_label,
            R.id.widget_week_day_3_label,
            R.id.widget_week_day_4_label,
            R.id.widget_week_day_5_label,
            R.id.widget_week_day_6_label,
            R.id.widget_week_day_7_label,
        )
        val summaryIds = intArrayOf(
            R.id.widget_week_day_1_summary,
            R.id.widget_week_day_2_summary,
            R.id.widget_week_day_3_summary,
            R.id.widget_week_day_4_summary,
            R.id.widget_week_day_5_summary,
            R.id.widget_week_day_6_summary,
            R.id.widget_week_day_7_summary,
        )

        labelIds.indices.forEach { index ->
            val slot = index + 1
            views.setTextViewText(
                labelIds[index],
                formatWeekday(widgetData.getString("week_day_${slot}_date", null), "${slot}일"),
            )
            val summary = formatWeekSummary(widgetData, slot)
            views.setTextViewText(summaryIds[index], summary)
            val isCritical = widgetData.getBoolean("week_day_${slot}_has_critical", false)
            views.setTextColor(summaryIds[index], if (isCritical) CRITICAL_TEXT_COLOR else DEFAULT_TEXT_COLOR)
        }

        bindOpenApp(context, views, R.id.widget_week_container)
        bindVoice(context, views, R.id.widget_week_voice_button)
    }

    private fun formatWeekSummary(widgetData: SharedPreferences, slot: Int): String {
        val firstEvent = widgetData.getString("week_day_${slot}_event_1_title", null)
            ?.takeIf { it.isNotBlank() }
        val explicitSummary = widgetData.getString("week_day_${slot}_summary", null)
            ?.takeIf { it.isNotBlank() }
        val count = widgetData.getInt("week_day_${slot}_count", 0)
        val isCritical = widgetData.getBoolean("week_day_${slot}_has_critical", false)
        if (firstEvent == null && (explicitSummary == null || explicitSummary == "일정 없음") && count <= 0) {
            return "일정 없음"
        }
        val title = firstEvent ?: explicitSummary ?: "일정 없음"
        val criticalLabel = if (isCritical) " · 중요" else ""
        return "$title · ${count}건$criticalLabel"
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
