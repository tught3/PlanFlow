package com.planflow.app

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

abstract class BasePlanFlowWidgetProvider(
    private val layoutId: Int,
) : HomeWidgetProvider() {
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
            val dateTime = Instant.parse(raw).atZone(ZoneId.systemDefault())
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
            val dateTime = Instant.parse(raw).atZone(ZoneId.systemDefault())
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
            val dateTime = Instant.parse(raw).atZone(ZoneId.systemDefault())
            DateTimeFormatter.ofPattern("E M/d", Locale.KOREA).format(dateTime)
        } catch (_: Exception) {
            fallback
        }
    }

    protected fun formatListItem(widgetData: SharedPreferences, slot: Int): String {
        val title = widgetData.getString("event_list_${slot}_title", null)
            ?.takeIf { it.isNotBlank() }
            ?: return when (slot) {
                1 -> "다가오는 일정 없음"
                else -> ""
            }
        val rawTime = widgetData.getString("event_list_${slot}_time", null)
        val time = formatShortTime(rawTime)
        return if (time.isBlank()) title else "$time  $title"
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
            ?: "마이크로 일정을 추가해 보세요"
        val startAt = widgetData.getString("next_event_start_at", null)
        val isCritical = widgetData.getBoolean("next_event_is_critical", false)

        views.setTextViewText(R.id.widget_title, title)
        views.setTextViewText(R.id.widget_time, formatTime(startAt))
        views.setTextViewText(R.id.widget_location, location)
        views.setTextViewText(R.id.widget_badge, if (isCritical) "중요 일정" else "다음 일정")
        views.setTextViewText(R.id.widget_list_item_1, formatListItem(widgetData, 1))
        views.setTextViewText(R.id.widget_list_item_2, formatListItem(widgetData, 2))
        views.setTextViewText(R.id.widget_list_item_3, formatListItem(widgetData, 3))

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
            widgetData.getString("next_event_title", null)?.let { "지금 다음: $it" }
                ?: "마이크로 일정을 추가해 보세요",
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
            val text = formatListItem(widgetData, index + 1)
            views.setTextViewText(id, text)
            views.setViewVisibility(id, if (text.isBlank()) View.GONE else View.VISIBLE)
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
            val summary = widgetData.getString("month_day_${day}_summary", null)
                ?.takeIf { it.isNotBlank() }
            views.setTextViewText(id, if (summary == null) "$day" else "$day\n$summary")
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
            views.setTextViewText(summaryIds[index], formatWeekSummary(widgetData, slot))
        }

        bindOpenApp(context, views, R.id.widget_week_container)
        bindVoice(context, views, R.id.widget_week_voice_button)
    }

    private fun formatWeekSummary(widgetData: SharedPreferences, slot: Int): String {
        val explicitSummary = widgetData.getString("week_day_${slot}_summary", null)
            ?.takeIf { it.isNotBlank() }
        if (explicitSummary != null) {
            return explicitSummary
        }

        val first = widgetData.getString("week_day_${slot}_event_1_title", null)
            ?.takeIf { it.isNotBlank() }
        val second = widgetData.getString("week_day_${slot}_event_2_title", null)
            ?.takeIf { it.isNotBlank() }
        return listOfNotNull(first, second).joinToString(" · ").ifBlank { "일정 없음" }
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
