package com.example.planflow

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

class PlanFlowHomeWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            val title = widgetData.getString("next_event_title", null)
                ?: "오늘 다음 일정이 없어요"
            val location = widgetData.getString("next_event_location", null)
                ?: "마이크를 눌러 새 일정을 추가하세요"
            val startAt = widgetData.getString("next_event_start_at", null)
            val isCritical = widgetData.getBoolean("next_event_is_critical", false)

            val views = RemoteViews(context.packageName, R.layout.planflow_home_widget).apply {
                setTextViewText(R.id.widget_title, title)
                setTextViewText(R.id.widget_time, formatTime(startAt))
                setTextViewText(R.id.widget_location, location)
                setTextViewText(
                    R.id.widget_badge,
                    if (isCritical) "중요 일정" else "PlanFlow",
                )

                val openAppIntent = HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                )
                setOnClickPendingIntent(R.id.widget_container, openAppIntent)

                val voiceIntent = HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("planflow://voice"),
                )
                setOnClickPendingIntent(R.id.widget_voice_button, voiceIntent)
            }

            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    private fun formatTime(raw: String?): String {
        if (raw.isNullOrBlank()) {
            return "시간 미정"
        }

        return try {
            val dateTime = Instant.parse(raw).atZone(ZoneId.systemDefault())
            DateTimeFormatter.ofPattern("M/d HH:mm").format(dateTime)
        } catch (_: Exception) {
            raw
        }
    }
}
