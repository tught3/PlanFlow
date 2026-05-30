package com.fluxstudio.planflow

import android.appwidget.AppWidgetManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
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
private const val ACTION_MONTH_PREVIOUS = "com.fluxstudio.planflow.widget.MONTH_PREVIOUS"
private const val ACTION_MONTH_NEXT = "com.fluxstudio.planflow.widget.MONTH_NEXT"
private const val ACTION_MONTH_TODAY = "com.fluxstudio.planflow.widget.MONTH_TODAY"
private const val MONTH_WIDGET_OFFSET_KEY = "month_widget_offset"
private const val ACTION_WEEK_PREVIOUS = "com.fluxstudio.planflow.widget.WEEK_PREVIOUS"
private const val ACTION_WEEK_NEXT = "com.fluxstudio.planflow.widget.WEEK_NEXT"
private const val ACTION_WEEK_TODAY = "com.fluxstudio.planflow.widget.WEEK_TODAY"
private const val WEEK_WIDGET_OFFSET_KEY = "week_widget_offset"
private const val ACTION_DAY_PREVIOUS = "com.fluxstudio.planflow.widget.DAY_PREVIOUS"
private const val ACTION_DAY_NEXT = "com.fluxstudio.planflow.widget.DAY_NEXT"
private const val ACTION_DAY_TODAY = "com.fluxstudio.planflow.widget.DAY_TODAY"
private const val DAY_WIDGET_OFFSET_KEY = "day_widget_offset"
private val PLANFLOW_DATE_FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd")

abstract class BasePlanFlowWidgetProvider(
    private val layoutId: Int,
) : HomeWidgetProvider() {
    protected val planFlowZone: ZoneId = ZoneId.of("Asia/Seoul")

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
            return "\uc2dc\uac04 \ubbf8\uc815"
        }

        return try {
            val dateTime = Instant.parse(raw).atZone(planFlowZone)
            val time = DateTimeFormatter.ofPattern("HH:mm", Locale.KOREA).format(dateTime)
            when (dateTime.toLocalDate()) {
                todayDate().plusDays(1) -> "내일 $time"
                todayDate().plusDays(2) -> "모레 $time"
                else -> DateTimeFormatter.ofPattern("M/d HH:mm", Locale.KOREA).format(dateTime)
            }
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
            "${dateTime.hour}\uc2dc"
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
        return "\uc774\ub3d9 ${travelMinutes}\ubd84"
    }

    protected fun formatDepartureTime(startAt: String?, travelMinutes: Int?): String {
        if (travelMinutes == null || travelMinutes <= 0) {
            return ""
        }

        val dateTime = parseDateTime(startAt) ?: return ""
        val departureAt = dateTime.minusMinutes(travelMinutes.toLong())
        return "\ucd9c\ubc1c: ${DateTimeFormatter.ofPattern("HH:mm", Locale.KOREA).format(departureAt)}"
    }

    protected fun formatCountdown(startAt: String?): String {
        val dateTime = parseDateTime(startAt) ?: return ""
        val now = ZonedDateTime.now(planFlowZone)
        val minutes = Duration.between(now, dateTime).toMinutes()
        return when {
            minutes <= 0 -> ""
            minutes < 60 -> "${minutes}\ubd84 \ud6c4"
            minutes < 1440 -> "${minutes / 60}\uc2dc\uac04 \ud6c4"
            minutes < 2880 -> "\ub0b4\uc77c"
            minutes < 4320 -> "\ubaa8\ub808"
            else -> "D-${minutes / 1440}\uc77c"
        }
    }

    protected fun parseDateTime(raw: String?): ZonedDateTime? {
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
                    views.setTextViewText(id, "\ub0a8\uc740 \uc77c\uc815 \uc5c6\uc74c")
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

    protected fun bindWeekAction(context: Context, views: RemoteViews, viewId: Int, action: String, providerClass: Class<*>) {
        if (viewId == 0) return
        val intent = Intent(context, providerClass).apply { this.action = action }
        val pendingIntent = android.app.PendingIntent.getBroadcast(
            context, action.hashCode(), intent,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE,
        )
        views.setOnClickPendingIntent(viewId, pendingIntent)
    }

    protected fun bindDayAction(context: Context, views: RemoteViews, viewId: Int, action: String) {
        if (viewId == 0) return
        val intent = Intent(context, PlanFlowVerticalScheduleWidgetProvider::class.java).apply { this.action = action }
        val pendingIntent = android.app.PendingIntent.getBroadcast(
            context, action.hashCode(), intent,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE,
        )
        views.setOnClickPendingIntent(viewId, pendingIntent)
    }

}

class PlanFlowHomeWidgetProvider : BasePlanFlowWidgetProvider(R.layout.planflow_home_widget) {
    override fun render(
        context: Context,
        views: RemoteViews,
        widgetData: SharedPreferences,
    ) {
        val startAt = widgetData.getString("next_event_start_at", null)
        val isPast = startAt != null &&
            (parseDateTime(startAt)?.isBefore(ZonedDateTime.now(planFlowZone)) == true)

        if (isPast) {
            views.setTextViewText(R.id.widget_title, "\uc608\uc815\ub41c \uc77c\uc815\uc774 \uc5c6\uc5b4\uc694")
            views.setTextViewText(R.id.widget_badge, "\ub2e4\uc74c \uc77c\uc815")
            views.setInt(R.id.widget_badge, "setBackgroundResource", R.drawable.widget_normal_badge_background)
            views.setTextColor(R.id.widget_badge, DEFAULT_TEXT_COLOR)
            views.setViewVisibility(R.id.widget_time, View.GONE)
            views.setViewVisibility(R.id.widget_location, View.GONE)
            views.setViewVisibility(R.id.widget_travel_minutes, View.GONE)
            views.setViewVisibility(R.id.widget_departure, View.GONE)
            views.setViewVisibility(R.id.widget_countdown, View.GONE)
        } else {
            val title = widgetData.getString("next_event_title", null) ?: "\uc624\ub298 \uccab \uc77c\uc815"
            val location = widgetData.getString("next_event_location", null)
            val isCritical = widgetData.getBoolean("next_event_is_critical", false)
            val travelMinutes = if (widgetData.contains("next_event_travel_buffer_minutes")) {
                widgetData.getInt("next_event_travel_buffer_minutes", 0)
            } else {
                null
            }

            views.setTextViewText(R.id.widget_title, title)
            views.setTextViewText(R.id.widget_time, formatTime(startAt))
            views.setViewVisibility(R.id.widget_time, View.VISIBLE)
            bindTextIfNotEmpty(views, R.id.widget_location, location ?: "")
            bindTextIfNotEmpty(views, R.id.widget_travel_minutes, formatTravelMinutes(travelMinutes))
            bindTextIfNotEmpty(views, R.id.widget_departure, formatDepartureTime(startAt, travelMinutes))
            bindTextIfNotEmpty(views, R.id.widget_countdown, formatCountdown(startAt))

            if (isCritical) {
                views.setTextViewText(R.id.widget_badge, "\uc911\uc694 \uc77c\uc815")
                views.setInt(R.id.widget_badge, "setBackgroundResource", R.drawable.widget_critical_badge_background)
                views.setTextColor(R.id.widget_badge, CRITICAL_TEXT_COLOR)
            } else {
                views.setTextViewText(R.id.widget_badge, "\ub2e4\uc74c \uc77c\uc815")
                views.setInt(R.id.widget_badge, "setBackgroundResource", R.drawable.widget_normal_badge_background)
                views.setTextColor(R.id.widget_badge, DEFAULT_TEXT_COLOR)
            }
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

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_DAY_PREVIOUS, ACTION_DAY_NEXT, ACTION_DAY_TODAY -> {
                val data = HomeWidgetPlugin.getData(context)
                val nextOffset = when (intent.action) {
                    ACTION_DAY_PREVIOUS -> data.getInt(DAY_WIDGET_OFFSET_KEY, 0) - 1
                    ACTION_DAY_NEXT -> data.getInt(DAY_WIDGET_OFFSET_KEY, 0) + 1
                    else -> 0
                }.coerceIn(-1, 1)
                data.edit().putInt(DAY_WIDGET_OFFSET_KEY, nextOffset).apply()

                val manager = AppWidgetManager.getInstance(context)
                val ids = manager.getAppWidgetIds(ComponentName(context, PlanFlowVerticalScheduleWidgetProvider::class.java))
                onUpdate(context, manager, ids, data)
                return
            }
        }
        super.onReceive(context, intent)
    }

    override fun render(
        context: Context,
        views: RemoteViews,
        widgetData: SharedPreferences,
    ) {
        val dayOffset = widgetData.getInt(DAY_WIDGET_OFFSET_KEY, 0).coerceIn(-1, 1)
        val dayPrefix = "day_offset_${dayOffset}_event"
        val dayTitle = when (dayOffset) {
            -1 -> "\uc5b4\uc81c \uc77c\uc815"
            1 -> "\ub0b4\uc77c \uc77c\uc815"
            else -> "\uc624\ub298 \uc77c\uc815"
        }
        val emptyMsg = when (dayOffset) {
            -1 -> "\uc5b4\uc81c \uc77c\uc815\uc774 \uc5c6\uc2b5\ub2c8\ub2e4"
            1 -> "\ub0b4\uc77c \uc77c\uc815\uc774 \uc5c6\uc2b5\ub2c8\ub2e4"
            else -> "\uc624\ub298 \uc77c\uc815\uc774 \uc5c6\uc2b5\ub2c8\ub2e4"
        }
        val targetDate = todayDate().plusDays(dayOffset.toLong())
        val hideWeekendEvents = hideWeekends(widgetData)

        views.setTextViewText(R.id.widget_vertical_title, dayTitle)
        bindDayAction(context, views, R.id.widget_vertical_prev_button, ACTION_DAY_PREVIOUS)
        bindDayAction(context, views, R.id.widget_vertical_next_button, ACTION_DAY_NEXT)

        val eventIds = intArrayOf(
            R.id.widget_today_upcoming_event_1_title,
            R.id.widget_today_upcoming_event_2_title,
            R.id.widget_today_upcoming_event_3_title,
            R.id.widget_today_upcoming_event_4_title,
            R.id.widget_today_upcoming_event_5_title,
            R.id.widget_today_upcoming_event_6_title,
        )
        bindSectionEvents(
            context, views, widgetData, dayPrefix, eventIds,
            isFaded = false,
            emptyMessageId = R.id.widget_today_upcoming_empty_message,
            emptyMessage = emptyMsg,
            hideWeekendEvents = hideWeekendEvents,
        )

        for (slot in 1..6) {
            bindEventLinkIfAvailable(context, views, eventIds[slot - 1],
                widgetData.getString("${dayPrefix}_${slot}_id", null))
        }

        bindCalendarLink(context, views, R.id.widget_vertical_container, targetDate)
        bindCalendarLink(context, views, R.id.widget_vertical_title, targetDate)
        bindVoice(context, views, R.id.widget_vertical_voice_button)
    }
}

class PlanFlowWeeklyWidgetProvider :
    BasePlanFlowWidgetProvider(R.layout.planflow_weekly_widget) {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_WEEK_PREVIOUS, ACTION_WEEK_NEXT, ACTION_WEEK_TODAY -> {
                val data = HomeWidgetPlugin.getData(context)
                val nextOffset = when (intent.action) {
                    ACTION_WEEK_PREVIOUS -> data.getInt(WEEK_WIDGET_OFFSET_KEY, 0) - 1
                    ACTION_WEEK_NEXT -> data.getInt(WEEK_WIDGET_OFFSET_KEY, 0) + 1
                    else -> 0
                }.coerceIn(-1, 1)
                data.edit().putInt(WEEK_WIDGET_OFFSET_KEY, nextOffset).apply()

                val manager = AppWidgetManager.getInstance(context)
                val gridIds = manager.getAppWidgetIds(ComponentName(context, PlanFlowWeeklyWidgetProvider::class.java))
                val listIds = manager.getAppWidgetIds(ComponentName(context, PlanFlowWeeklyListWidgetProvider::class.java))
                onUpdate(context, manager, gridIds, data)
                PlanFlowWeeklyListWidgetProvider().onUpdate(context, manager, listIds, data)
                return
            }
        }
        super.onReceive(context, intent)
    }

    override fun render(
        context: Context,
        views: RemoteViews,
        widgetData: SharedPreferences,
    ) {
        val weekOffset = widgetData.getInt(WEEK_WIDGET_OFFSET_KEY, 0).coerceIn(-1, 1)
        val weekPrefix = when (weekOffset) {
            -1 -> "week_offset_-1_day"
            1 -> "week_offset_1_day"
            else -> "week_day"
        }
        val weekTitle = when (weekOffset) {
            -1 -> widgetData.getString("week_title_offset_-1", "\uc9c0\ub09c \uc8fc")
            1 -> widgetData.getString("week_title_offset_1", "\ub2e4\uc74c \uc8fc")
            else -> "\uc8fc\uac04 \uc77c\uc815"
        }
        views.setTextViewText(R.id.widget_week_title, weekTitle ?: "\uc8fc\uac04 \uc77c\uc815")
        bindWeekAction(context, views, R.id.widget_week_prev_button, ACTION_WEEK_PREVIOUS, PlanFlowWeeklyWidgetProvider::class.java)
        bindWeekAction(context, views, R.id.widget_week_next_button, ACTION_WEEK_NEXT, PlanFlowWeeklyWidgetProvider::class.java)
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
            val rawDate = widgetData.getString("${weekPrefix}_${slot}_date", null)
            val fallbackDate = weekStart.plusDays(index.toLong())
            val targetDate = parseLocalDate(rawDate) ?: fallbackDate
            if (hideWeekendColumns && isWeekend(targetDate)) {
                views.setViewVisibility(weekColumnIds[index], View.GONE)
                continue
            }
            views.setViewVisibility(weekColumnIds[index], View.VISIBLE)
            views.setTextViewText(labelIds[index], formatWeekdayLabel(rawDate, ""))
            views.setTextViewText(dateIds[index], formatMonthDay(rawDate, ""))
            bindCalendarLink(context, views, weekColumnIds[index], targetDate)

            val e1Title = widgetData.getString("${weekPrefix}_${slot}_event_1_title", null)?.takeIf { it.isNotBlank() }
            val e2Title = widgetData.getString("${weekPrefix}_${slot}_event_2_title", null)?.takeIf { it.isNotBlank() }
            val e3Title = widgetData.getString("${weekPrefix}_${slot}_event_3_title", null)?.takeIf { it.isNotBlank() }
            val e4Title = widgetData.getString("${weekPrefix}_${slot}_event_4_title", null)?.takeIf { it.isNotBlank() }
            val e1Critical = widgetData.getBoolean("${weekPrefix}_${slot}_event_1_is_critical", false)
            val e2Critical = widgetData.getBoolean("${weekPrefix}_${slot}_event_2_is_critical", false)
            val e3Critical = widgetData.getBoolean("${weekPrefix}_${slot}_event_3_is_critical", false)
            val e4Critical = widgetData.getBoolean("${weekPrefix}_${slot}_event_4_is_critical", false)

            var overflow = 0
            if (widgetData.contains("${weekPrefix}_${slot}_overflow_count")) {
                overflow = widgetData.getInt("${weekPrefix}_${slot}_overflow_count", 0)
            } else {
                val totalCount = widgetData.getInt("${weekPrefix}_${slot}_count", 0)
                overflow = (totalCount - listOf(e1Title, e2Title, e3Title, e4Title).count { !it.isNullOrBlank() }).coerceAtLeast(0)
            }

            bindEventText(views, event1Ids[index], e1Title, null, e1Critical,
                emptyText = if (e1Title == null && e2Title == null && overflow == 0) "\uc77c\uc815 \uc5c6\uc74c" else null)
            bindEventText(views, event2Ids[index], e2Title, null, e2Critical)
            bindEventText(views, event3Ids[index], e3Title, null, e3Critical)
            bindEventText(views, event4Ids[index], e4Title, null, e4Critical)
            bindEventLinkIfAvailable(context, views, event1Ids[index], widgetData.getString("${weekPrefix}_${slot}_event_1_id", null))
            bindEventLinkIfAvailable(context, views, event2Ids[index], widgetData.getString("${weekPrefix}_${slot}_event_2_id", null))
            bindEventLinkIfAvailable(context, views, event3Ids[index], widgetData.getString("${weekPrefix}_${slot}_event_3_id", null))
            bindEventLinkIfAvailable(context, views, event4Ids[index], widgetData.getString("${weekPrefix}_${slot}_event_4_id", null))

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

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_WEEK_PREVIOUS, ACTION_WEEK_NEXT, ACTION_WEEK_TODAY -> {
                val data = HomeWidgetPlugin.getData(context)
                val nextOffset = when (intent.action) {
                    ACTION_WEEK_PREVIOUS -> data.getInt(WEEK_WIDGET_OFFSET_KEY, 0) - 1
                    ACTION_WEEK_NEXT -> data.getInt(WEEK_WIDGET_OFFSET_KEY, 0) + 1
                    else -> 0
                }.coerceIn(-1, 1)
                data.edit().putInt(WEEK_WIDGET_OFFSET_KEY, nextOffset).apply()

                val manager = AppWidgetManager.getInstance(context)
                val gridIds = manager.getAppWidgetIds(ComponentName(context, PlanFlowWeeklyWidgetProvider::class.java))
                val listIds = manager.getAppWidgetIds(ComponentName(context, PlanFlowWeeklyListWidgetProvider::class.java))
                PlanFlowWeeklyWidgetProvider().onUpdate(context, manager, gridIds, data)
                onUpdate(context, manager, listIds, data)
                return
            }
        }
        super.onReceive(context, intent)
    }

    override fun render(
        context: Context,
        views: RemoteViews,
        widgetData: SharedPreferences,
    ) {
        val weekOffset = widgetData.getInt(WEEK_WIDGET_OFFSET_KEY, 0).coerceIn(-1, 1)
        val weekPrefix = when (weekOffset) {
            -1 -> "week_offset_-1_day"
            1 -> "week_offset_1_day"
            else -> "week_day"
        }
        val weekTitle = when (weekOffset) {
            -1 -> widgetData.getString("week_title_offset_-1", "\uc9c0\ub09c \uc8fc")
            1 -> widgetData.getString("week_title_offset_1", "\ub2e4\uc74c \uc8fc")
            else -> "\uc8fc\uac04 \uc77c\uc815"
        }
        views.setTextViewText(R.id.widget_week_list_title, weekTitle ?: "\uc8fc\uac04 \uc77c\uc815")
        bindWeekAction(context, views, R.id.widget_week_list_prev_button, ACTION_WEEK_PREVIOUS, PlanFlowWeeklyListWidgetProvider::class.java)
        bindWeekAction(context, views, R.id.widget_week_list_next_button, ACTION_WEEK_NEXT, PlanFlowWeeklyListWidgetProvider::class.java)
        val hideWeekendRows = hideWeekends(widgetData)
        val weekStart = todayDate().minusDays((todayDate().dayOfWeek.value - 1).toLong())

        for (index in 0 until 7) {
            val slot = index + 1
            val rawDate = widgetData.getString("${weekPrefix}_${slot}_date", null)
            val fallbackDate = weekStart.plusDays(index.toLong())
            val targetDate = parseLocalDate(rawDate) ?: fallbackDate

            val rowId = findViewId(context, "widget_week_list_day_${slot}_row")
            val labelId = findViewId(context, "widget_week_list_day_${slot}_label")
            val overflowId = findViewId(context, "widget_week_list_day_${slot}_overflow")
            if (rowId == 0 || labelId == 0 || overflowId == 0) continue
            if (hideWeekendRows && isWeekend(targetDate)) {
                views.setViewVisibility(rowId, View.GONE)
                continue
            }
            views.setViewVisibility(rowId, View.VISIBLE)
            views.setTextViewText(labelId, formatMonthDayWithWeekday(targetDate))
            bindCalendarLink(context, views, rowId, targetDate)

            var shownCount = 0
            for (eventSlot in 1..4) {
                val eventId = findViewId(context, "widget_week_list_day_${slot}_event_${eventSlot}")
                if (eventId == 0) continue
                val title = widgetData.getString("${weekPrefix}_${slot}_event_${eventSlot}_title", null)?.takeIf { it.isNotBlank() }
                val isCritical = widgetData.getBoolean("${weekPrefix}_${slot}_event_${eventSlot}_is_critical", false)
                if (!title.isNullOrBlank()) shownCount += 1
                bindEventText(views, eventId, title, null, isCritical,
                    emptyText = if (eventSlot == 1) "\uc77c\uc815 \uc5c6\uc74c" else null)
                bindEventLinkIfAvailable(context, views, eventId,
                    widgetData.getString("${weekPrefix}_${slot}_event_${eventSlot}_id", null))
            }

            val overflow = if (widgetData.contains("${weekPrefix}_${slot}_overflow_count")) {
                widgetData.getInt("${weekPrefix}_${slot}_overflow_count", 0)
            } else {
                (widgetData.getInt("${weekPrefix}_${slot}_count", 0) - shownCount).coerceAtLeast(0)
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
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_MONTH_PREVIOUS, ACTION_MONTH_NEXT, ACTION_MONTH_TODAY -> {
                val data = HomeWidgetPlugin.getData(context)
                val nextOffset = when (intent.action) {
                    ACTION_MONTH_PREVIOUS -> data.getInt(MONTH_WIDGET_OFFSET_KEY, 0) - 1
                    ACTION_MONTH_NEXT -> data.getInt(MONTH_WIDGET_OFFSET_KEY, 0) + 1
                    else -> 0
                }.coerceIn(-1, 1)
                data.edit().putInt(MONTH_WIDGET_OFFSET_KEY, nextOffset).apply()

                val manager = AppWidgetManager.getInstance(context)
                val ids = manager.getAppWidgetIds(
                    ComponentName(context, PlanFlowMonthlyWidgetProvider::class.java),
                )
                onUpdate(context, manager, ids, data)
                return
            }
        }
        super.onReceive(context, intent)
    }

    override fun render(
        context: Context,
        views: RemoteViews,
        widgetData: SharedPreferences,
    ) {
        val monthOffset = widgetData.getInt(MONTH_WIDGET_OFFSET_KEY, 0).coerceIn(-1, 1)
        val cellPrefix = if (monthOffset == 0) "month_cell" else "month_offset_${monthOffset}_cell"
        val hasMonthCellPayload = hasMonthCellPayload(widgetData, cellPrefix)
        val hideWeekendCells = hideWeekends(widgetData)
        val monthStart = LocalDate.now(ZoneId.of("Asia/Seoul")).plusMonths(monthOffset.toLong()).withDayOfMonth(1)
        val fallbackCells = buildCurrentMonthFallbackCells(monthStart)

        views.setTextViewText(
            R.id.widget_month_title,
            widgetData.getString(monthTitleKey(monthOffset), null) ?: fallbackMonthTitle(monthStart),
        )
        bindMonthAction(context, views, R.id.widget_month_prev_button, ACTION_MONTH_PREVIOUS)
        bindMonthAction(context, views, R.id.widget_month_next_button, ACTION_MONTH_NEXT)
        bindMonthAction(context, views, R.id.widget_month_today_button, ACTION_MONTH_TODAY)

        for (slot in 1..42) {
            val prefix = "${cellPrefix}_${slot}"
            val dayId = findViewId(context, "${prefix}_day")
                .takeIf { it != 0 } ?: findViewId(context, "month_cell_${slot}_day")
            val cellContainerId = findViewId(context, "${prefix}_container")
                .takeIf { it != 0 } ?: findViewId(context, "month_cell_${slot}_container")
            val cellDate = parseLocalDate(widgetData.getString("${prefix}_date", null))
            val inMonthId = findViewId(context, "${prefix}_in_month")
                .takeIf { it != 0 } ?: findViewId(context, "month_cell_${slot}_in_month")
            val overflowId = findViewId(context, "${prefix}_overflow_count")
                .takeIf { it != 0 } ?: findViewId(context, "month_cell_${slot}_overflow_count")
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
            val isToday = targetDate == todayDate()
            views.setTextColor(
                dayId,
                when {
                    isToday -> 0xFFFFFFFF.toInt()
                    inMonth -> DEFAULT_TEXT_COLOR
                    else -> MUTED_TEXT_COLOR
                },
            )
            views.setInt(
                dayId,
                "setBackgroundResource",
                if (isToday) R.drawable.widget_month_today_day_background else android.R.color.transparent,
            )

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
                views.setViewVisibility(overflowId, View.VISIBLE)
            } else {
                views.setViewVisibility(overflowId, View.GONE)
            }

            for (eventSlot in 1..3) {
                val eventId = findViewId(context, "${prefix}_event_${eventSlot}_title")
                    .takeIf { it != 0 } ?: findViewId(context, "month_cell_${slot}_event_${eventSlot}_title")
                val rawTitle = if (hasMonthCellPayload) {
                    widgetData.getString("${prefix}_event_${eventSlot}_title", null)?.takeIf { it.isNotBlank() }
                } else null
                val eventCritical = if (hasMonthCellPayload) {
                    widgetData.getBoolean("${prefix}_event_${eventSlot}_is_critical", false)
                } else false
                val segment = widgetData.getString("${prefix}_event_${eventSlot}_segment", null)
                val showTitle = widgetData.getBoolean("${prefix}_event_${eventSlot}_show_title", true)

                if (eventId != 0) {
                    // segment 배경 적용
                    val bgRes = when (segment) {
                        "start" -> R.drawable.widget_month_event_start
                        "middle" -> R.drawable.widget_month_event_middle
                        "end" -> R.drawable.widget_month_event_end
                        "single" -> R.drawable.widget_month_event_single
                        else -> android.R.color.transparent
                    }
                    views.setInt(eventId, "setBackgroundResource", bgRes)

                    // middle/end 셀은 제목 숨기고 공간만 유지
                    val displayTitle = if (showTitle) rawTitle else if (segment != null && segment != "single") " " else rawTitle
                    bindEventText(views, eventId, displayTitle, null, isCritical = eventCritical, isMuted = !inMonth)
                    if (eventCritical && inMonth) {
                        views.setTextColor(eventId, 0xFF9C5C71.toInt())
                    }
                    bindEventLinkIfAvailable(context, views, eventId,
                        widgetData.getString("${prefix}_event_${eventSlot}_id", null),
                        calendarUriForDate(targetDate))
                }
            }
        }

        bindCalendarLink(context, views, R.id.widget_month_container, todayDate())
        bindCalendarLink(context, views, R.id.widget_month_title, todayDate())
        bindVoice(context, views, R.id.widget_month_voice_button)
    }

    private fun hasMonthCellPayload(widgetData: SharedPreferences, prefix: String = "month_cell"): Boolean {
        for (slot in 1..42) {
            if (widgetData.contains("${prefix}_${slot}_day")) {
                return true
            }
        }
        return false
    }

    private fun bindMonthAction(context: Context, views: RemoteViews, viewId: Int, action: String) {
        val intent = Intent(context, PlanFlowMonthlyWidgetProvider::class.java).apply {
            this.action = action
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            action.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        views.setOnClickPendingIntent(viewId, pendingIntent)
    }

    private fun monthTitleKey(offset: Int): String {
        return if (offset == 0) "month_title" else "month_title_offset_${offset}"
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

    private fun fallbackMonthTitle(monthStart: LocalDate): String {
        return "${monthStart.year}.${monthStart.monthValue.toString().padStart(2, '0')}"
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
