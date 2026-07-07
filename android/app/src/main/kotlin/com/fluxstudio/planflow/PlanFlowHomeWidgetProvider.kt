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
import org.json.JSONArray
import org.json.JSONObject
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

private const val DEFAULT_TEXT_COLOR = 0xFF203A57.toInt()
private const val MUTED_TEXT_COLOR = 0xFF8FA4B7.toInt()
private const val CRITICAL_TEXT_COLOR = 0xFFD94444.toInt()
private const val HOLIDAY_TEXT_COLOR = 0xFFB42318.toInt()
private const val MULTI_DAY_TEXT_COLOR = 0xFF174F4A.toInt()
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

data class RawWidgetEvent(
    val id: String,
    val title: String,
    val startAt: ZonedDateTime?,
    val endAt: ZonedDateTime?,
    val location: String?,
    val isCritical: Boolean,
    val isAllDay: Boolean,
    val isMultiDay: Boolean,
    val parentEventId: String?,
)

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
            var views: RemoteViews? = null
            try {
                views = RemoteViews(context.packageName, layoutId)
                render(context, views, widgetData)
            } catch (e: Exception) {
                android.util.Log.e("PlanFlowWidget", "onUpdate failed for $widgetId: ${e.message}", e)
            } finally {
                views?.let { appWidgetManager.updateAppWidget(widgetId, it) }
            }
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

    protected fun looksLikeHolidayTitle(title: String?): Boolean {
        val normalized = title?.trim().orEmpty()
            .replace("\\s+".toRegex(), "")
            .lowercase(Locale.KOREA)
        if (normalized.isBlank()) {
            return false
        }
        val keywords = listOf(
            "공휴일",
            "대체공휴일",
            "임시공휴일",
            "신정",
            "설날",
            "추석",
            "삼일절",
            "어린이날",
            "현충일",
            "광복절",
            "개천절",
            "한글날",
            "성탄절",
            "부처님오신날",
            "휴일",
        )
        return keywords.any { keyword ->
            normalized.contains(keyword.replace("\\s+".toRegex(), "").lowercase(Locale.KOREA))
        }
    }

    protected fun hasHolidayEvent(events: List<RawWidgetEvent>, day: LocalDate): Boolean {
        return rawWidgetEventsForDay(events, day).any { looksLikeHolidayTitle(it.title) }
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

    protected fun formatOverflowLabel(
        previewTitle: String?,
        overflowCount: Int,
    ): String? {
        if (overflowCount <= 0) {
            return null
        }

        val title = previewTitle?.trim()?.takeIf { it.isNotBlank() }
        return when {
            title == null -> "+$overflowCount"
            overflowCount == 1 -> title
            else -> "$title 외 ${overflowCount}건"
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

    protected fun loadRawWidgetEvents(widgetData: SharedPreferences): List<RawWidgetEvent> {
        val rawJson = widgetData.getString("schedule_events_json", null)?.trim()
        if (rawJson.isNullOrBlank()) {
            return emptyList()
        }

        return try {
            val array = JSONArray(rawJson)
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    val id = item.optString("id", "").trim()
                    val title = item.optString("title", "").trim()
                    val userId = item.optString("user_id", "").trim()
                    if (id.isBlank() || title.isBlank() || userId.isBlank()) {
                        continue
                    }
                    add(
                        RawWidgetEvent(
                            id = id,
                            title = title,
                            startAt = parseRawWidgetDateTime(item.optString("start_at", null)),
                            endAt = parseRawWidgetDateTime(item.optString("end_at", null)),
                            location = item.optString("location", null)?.trim()?.takeIf { it.isNotBlank() },
                            isCritical = item.optBoolean("is_critical", false),
                            isAllDay = item.optBoolean("is_all_day", false),
                            isMultiDay = item.optBoolean("is_multi_day", false),
                            parentEventId = item.optString("parent_event_id", null)?.trim()?.takeIf { it.isNotBlank() },
                        ),
                    )
                }
            }.sortedWith(
                compareBy<RawWidgetEvent> { it.startAt?.toInstant() ?: Instant.MAX }
                    .thenBy { it.title },
            )
        } catch (_: Exception) {
            emptyList()
        }
    }

    protected fun parseRawWidgetDateTime(raw: String?): ZonedDateTime? {
        if (raw.isNullOrBlank()) {
            return null
        }

        return try {
            Instant.parse(raw).atZone(planFlowZone)
        } catch (_: Exception) {
            null
        }
    }

    protected fun rawWidgetEventsForDay(
        events: List<RawWidgetEvent>,
        day: LocalDate,
    ): List<RawWidgetEvent> {
        return events.filter { rawWidgetEventIntersectsDay(it, day) }
            .sortedWith(
                compareBy<RawWidgetEvent> { it.startAt?.toInstant() ?: Instant.MAX }
                    .thenBy { it.title },
            )
    }

    protected fun rawWidgetEventDisplayEndDay(event: RawWidgetEvent): LocalDate {
        val startAt = event.startAt ?: return LocalDate.of(1970, 1, 1)
        val endAt = event.endAt ?: startAt
        var localEnd = endAt
        if (endAt.isAfter(startAt) &&
            localEnd.toLocalTime() == LocalTime.MIDNIGHT
        ) {
            localEnd = localEnd.minusNanos(1_000)
        }
        return localEnd.toLocalDate()
    }

    protected fun rawWidgetEventIntersectsDay(event: RawWidgetEvent, day: LocalDate): Boolean {
        val startAt = event.startAt ?: return false
        val firstDay = startAt.toLocalDate()
        val lastDay = rawWidgetEventDisplayEndDay(event)
        return !day.isBefore(firstDay) && !day.isAfter(lastDay)
    }

    protected fun rawWidgetMonthSegment(
        event: RawWidgetEvent,
        cellDay: LocalDate,
    ): String {
        val startAt = event.startAt ?: return "single"
        val firstEventDay = startAt.toLocalDate()
        val lastEventDay = rawWidgetEventDisplayEndDay(event)
        val isRowStart = cellDay.dayOfWeek == java.time.DayOfWeek.SUNDAY || cellDay.dayOfMonth == 1
        val isRowEnd = cellDay.dayOfWeek == java.time.DayOfWeek.SATURDAY ||
            cellDay == cellDay.withDayOfMonth(cellDay.lengthOfMonth())

        return when {
            (cellDay == firstEventDay || isRowStart) && (cellDay == lastEventDay || isRowEnd) -> "single"
            cellDay == firstEventDay || isRowStart -> "start"
            cellDay == lastEventDay || isRowEnd -> "end"
            else -> "middle"
        }
    }

    protected fun isMonthRangeSegment(segment: String?): Boolean {
        return segment == "start" || segment == "middle" || segment == "end"
    }

    protected fun monthRangeBackground(segment: String?, isCritical: Boolean): Int {
        return when (segment) {
            "start" -> if (isCritical) {
                R.drawable.widget_month_event_critical_start
            } else {
                R.drawable.widget_month_event_start
            }
            "middle" -> if (isCritical) {
                R.drawable.widget_month_event_critical_middle
            } else {
                R.drawable.widget_month_event_middle
            }
            "end" -> if (isCritical) {
                R.drawable.widget_month_event_critical_end
            } else {
                R.drawable.widget_month_event_end
            }
            else -> android.R.color.transparent
        }
    }

    protected fun formatLocalMonthDay(date: LocalDate): String {
        return DateTimeFormatter.ofPattern("M/d", Locale.KOREA).format(date)
    }

    protected fun formatLocalWeekday(date: LocalDate): String {
        return DateTimeFormatter.ofPattern("E", Locale.KOREA).format(date)
    }

    protected fun formatMonthOffsetTitle(monthStart: LocalDate): String {
        return "${monthStart.year}.${monthStart.monthValue.toString().padStart(2, '0')}"
    }

    protected fun formatWeekOffsetTitle(weekStart: LocalDate, weekOffset: Int): String {
        return when (weekOffset) {
            -1 -> "지난 주"
            0 -> "주간 일정"
            1 -> "다음 주"
            else -> "${formatLocalMonthDay(weekStart)} ~ ${formatLocalMonthDay(weekStart.plusDays(6))}"
        }
    }

    protected fun formatDayOffsetTitle(day: LocalDate, dayOffset: Int): String {
        return when (dayOffset) {
            -1 -> "어제 일정"
            0 -> "오늘 일정"
            1 -> "내일 일정"
            else -> "${formatMonthDayWithWeekday(day)} 일정"
        }
    }

    protected fun formatDayOffsetEmptyMessage(day: LocalDate, dayOffset: Int): String {
        return when (dayOffset) {
            -1 -> "어제 일정이 없습니다"
            0 -> "오늘 일정이 없습니다"
            1 -> "내일 일정이 없습니다"
            else -> "${formatMonthDayWithWeekday(day)} 일정이 없습니다"
        }
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
                }
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
        val rawEvents = loadRawWidgetEvents(widgetData)
        val dayOffset = widgetData.getInt(DAY_WIDGET_OFFSET_KEY, 0)
        val targetDate = todayDate().plusDays(dayOffset.toLong())
        val hideWeekendEvents = hideWeekends(widgetData)

        views.setTextViewText(R.id.widget_vertical_title, formatDayOffsetTitle(targetDate, dayOffset))
        bindDayAction(context, views, R.id.widget_vertical_prev_button, ACTION_DAY_PREVIOUS)
        bindDayAction(context, views, R.id.widget_vertical_next_button, ACTION_DAY_NEXT)

        val maxVisibleVertical = 5
        val eventIds = intArrayOf(
            R.id.widget_today_upcoming_event_1_title,
            R.id.widget_today_upcoming_event_2_title,
            R.id.widget_today_upcoming_event_3_title,
            R.id.widget_today_upcoming_event_4_title,
            R.id.widget_today_upcoming_event_5_title,
            // event_6 슬롯은 overflow 라벨 전용으로 사용
        )
        val verticalOverflowViewId = R.id.widget_today_upcoming_event_6_title

        if (rawEvents.isNotEmpty()) {
            val allDayEvents = rawWidgetEventsForDay(rawEvents, targetDate)
            val events = allDayEvents.take(maxVisibleVertical)
            var hasAnyEvent = false
            for (slot in 1..maxVisibleVertical) {
                val eventId = eventIds[slot - 1]
                val event = events.getOrNull(slot - 1)
                if (event != null) {
                    hasAnyEvent = true
                    bindEventText(
                        views,
                        eventId,
                        event.title,
                        null,
                        event.isCritical,
                        emptyText = null,
                    )
                    bindEventLinkIfAvailable(context, views, eventId, event.id)
                } else if (slot == 1) {
                    bindEventText(
                        views,
                        eventId,
                        null,
                        null,
                        false,
                        emptyText = formatDayOffsetEmptyMessage(targetDate, dayOffset),
                    )
                } else {
                    views.setViewVisibility(eventId, View.GONE)
                }
            }
            // overflow 라벨 (6번째 슬롯)
            val verticalOverflow = (allDayEvents.size - maxVisibleVertical).coerceAtLeast(0)
            val verticalOverflowLabel = formatOverflowLabel(
                allDayEvents.drop(maxVisibleVertical).firstOrNull()?.title,
                verticalOverflow,
            )
            if (verticalOverflowLabel != null) {
                views.setTextViewText(verticalOverflowViewId, verticalOverflowLabel)
                views.setViewVisibility(verticalOverflowViewId, View.VISIBLE)
            } else {
                views.setViewVisibility(verticalOverflowViewId, View.GONE)
            }
            if (hasAnyEvent) {
                views.setViewVisibility(R.id.widget_today_upcoming_empty_message, View.GONE)
            } else {
                views.setTextViewText(
                    R.id.widget_today_upcoming_empty_message,
                    formatDayOffsetEmptyMessage(targetDate, dayOffset),
                )
                views.setTextColor(R.id.widget_today_upcoming_empty_message, MUTED_TEXT_COLOR)
                views.setViewVisibility(R.id.widget_today_upcoming_empty_message, View.VISIBLE)
            }
        } else {
            val dayPrefix = "day_offset_${dayOffset}_event"
            bindSectionEvents(
                context, views, widgetData, dayPrefix, eventIds,
                isFaded = false,
                emptyMessageId = R.id.widget_today_upcoming_empty_message,
                emptyMessage = formatDayOffsetEmptyMessage(targetDate, dayOffset),
                hideWeekendEvents = hideWeekendEvents,
            )
            for (slot in 1..maxVisibleVertical) {
                bindEventLinkIfAvailable(context, views, eventIds[slot - 1],
                    widgetData.getString("${dayPrefix}_${slot}_id", null))
            }
            // SharedPreferences 경로 overflow 라벨
            val totalVerticalCount = widgetData.getInt("day_offset_${dayOffset}_count", 0)
            val verticalOverflow = (totalVerticalCount - maxVisibleVertical).coerceAtLeast(0)
            val verticalOverflowPreviewTitle =
                widgetData.getString("day_offset_${dayOffset}_overflow_preview_title", null)
                    ?: widgetData.getString("${dayPrefix}_6_title", null)
            val verticalOverflowLabel = formatOverflowLabel(verticalOverflowPreviewTitle, verticalOverflow)
            if (verticalOverflowLabel != null) {
                views.setTextViewText(verticalOverflowViewId, verticalOverflowLabel)
                views.setViewVisibility(verticalOverflowViewId, View.VISIBLE)
            } else {
                views.setViewVisibility(verticalOverflowViewId, View.GONE)
            }
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
                }
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
        val rawEvents = loadRawWidgetEvents(widgetData)
        val weekOffset = widgetData.getInt(WEEK_WIDGET_OFFSET_KEY, 0)
        val baseWeekStart = todayDate().minusDays((todayDate().dayOfWeek.value - 1).toLong())
        val weekStart = baseWeekStart.plusWeeks(weekOffset.toLong())
        val weekTitle = formatWeekOffsetTitle(weekStart, weekOffset)
        views.setTextViewText(R.id.widget_week_title, weekTitle)
        bindWeekAction(context, views, R.id.widget_week_prev_button, ACTION_WEEK_PREVIOUS, PlanFlowWeeklyWidgetProvider::class.java)
        bindWeekAction(context, views, R.id.widget_week_next_button, ACTION_WEEK_NEXT, PlanFlowWeeklyWidgetProvider::class.java)
        val hideWeekendColumns = hideWeekends(widgetData)
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
            val targetDate = weekStart.plusDays(index.toLong())
            if (hideWeekendColumns && isWeekend(targetDate)) {
                views.setViewVisibility(weekColumnIds[index], View.GONE)
                continue
            }
            views.setViewVisibility(weekColumnIds[index], View.VISIBLE)
            views.setTextViewText(labelIds[index], formatLocalWeekday(targetDate))
            views.setTextViewText(dateIds[index], formatLocalMonthDay(targetDate))
            bindCalendarLink(context, views, weekColumnIds[index], targetDate)

            val dayEvents = if (rawEvents.isNotEmpty()) {
                rawWidgetEventsForDay(rawEvents, targetDate).take(4)
            } else {
                emptyList()
            }

            if (rawEvents.isNotEmpty()) {
                val fullDayEvents = rawWidgetEventsForDay(rawEvents, targetDate)
                val overflow = (fullDayEvents.size - dayEvents.size).coerceAtLeast(0)
                val overflowLabel = formatOverflowLabel(
                    fullDayEvents.drop(4).firstOrNull()?.title,
                    overflow,
                )
                bindEventText(
                    views,
                    event1Ids[index],
                    dayEvents.getOrNull(0)?.title,
                    null,
                    dayEvents.getOrNull(0)?.isCritical == true,
                    emptyText = if (dayEvents.isEmpty()) "일정 없음" else null,
                )
                bindEventText(views, event2Ids[index], dayEvents.getOrNull(1)?.title, null, dayEvents.getOrNull(1)?.isCritical == true)
                bindEventText(views, event3Ids[index], dayEvents.getOrNull(2)?.title, null, dayEvents.getOrNull(2)?.isCritical == true)
                bindEventText(views, event4Ids[index], dayEvents.getOrNull(3)?.title, null, dayEvents.getOrNull(3)?.isCritical == true)
                dayEvents.getOrNull(0)?.let { bindEventLinkIfAvailable(context, views, event1Ids[index], it.id) }
                dayEvents.getOrNull(1)?.let { bindEventLinkIfAvailable(context, views, event2Ids[index], it.id) }
                dayEvents.getOrNull(2)?.let { bindEventLinkIfAvailable(context, views, event3Ids[index], it.id) }
                dayEvents.getOrNull(3)?.let { bindEventLinkIfAvailable(context, views, event4Ids[index], it.id) }

                if (overflowLabel != null) {
                    views.setTextViewText(overflowIds[index], overflowLabel)
                    views.setViewVisibility(overflowIds[index], View.VISIBLE)
                } else {
                    views.setViewVisibility(overflowIds[index], View.GONE)
                }
            } else {
                val weekPrefix = when (weekOffset) {
                    -1 -> "week_offset_-1_day"
                    1 -> "week_offset_1_day"
                    else -> "week_day"
                }
                val rawDate = widgetData.getString("${weekPrefix}_${slot}_date", null)
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
                val overflowLabel = formatOverflowLabel(
                    widgetData.getString("${weekPrefix}_${slot}_overflow_preview_title", null)
                        ?: e4Title,
                    overflow,
                )

                bindEventText(views, event1Ids[index], e1Title, null, e1Critical,
                    emptyText = if (e1Title == null && e2Title == null && overflow == 0) "\uc77c\uc815 \uc5c6\uc74c" else null)
                bindEventText(views, event2Ids[index], e2Title, null, e2Critical)
                bindEventText(views, event3Ids[index], e3Title, null, e3Critical)
                bindEventText(views, event4Ids[index], e4Title, null, e4Critical)
                bindEventLinkIfAvailable(context, views, event1Ids[index], widgetData.getString("${weekPrefix}_${slot}_event_1_id", null))
                bindEventLinkIfAvailable(context, views, event2Ids[index], widgetData.getString("${weekPrefix}_${slot}_event_2_id", null))
                bindEventLinkIfAvailable(context, views, event3Ids[index], widgetData.getString("${weekPrefix}_${slot}_event_3_id", null))
                bindEventLinkIfAvailable(context, views, event4Ids[index], widgetData.getString("${weekPrefix}_${slot}_event_4_id", null))

                if (overflowLabel != null) {
                    views.setTextViewText(overflowIds[index], overflowLabel)
                    views.setViewVisibility(overflowIds[index], View.VISIBLE)
                } else {
                    views.setViewVisibility(overflowIds[index], View.GONE)
                }
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
                }
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
        val rawEvents = loadRawWidgetEvents(widgetData)
        val weekOffset = widgetData.getInt(WEEK_WIDGET_OFFSET_KEY, 0)
        val baseWeekStart = todayDate().minusDays((todayDate().dayOfWeek.value - 1).toLong())
        val weekStart = baseWeekStart.plusWeeks(weekOffset.toLong())
        val weekTitle = formatWeekOffsetTitle(weekStart, weekOffset)
        views.setTextViewText(R.id.widget_week_list_title, weekTitle)
        bindWeekAction(context, views, R.id.widget_week_list_prev_button, ACTION_WEEK_PREVIOUS, PlanFlowWeeklyListWidgetProvider::class.java)
        bindWeekAction(context, views, R.id.widget_week_list_next_button, ACTION_WEEK_NEXT, PlanFlowWeeklyListWidgetProvider::class.java)
        val hideWeekendRows = hideWeekends(widgetData)

        for (index in 0 until 7) {
            val slot = index + 1
            val fallbackDate = weekStart.plusDays(index.toLong())
            val targetDate = fallbackDate
            val weekPrefix = when (weekOffset) {
                -1 -> "week_offset_-1_day"
                1 -> "week_offset_1_day"
                else -> "week_day"
            }

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

            val dayEvents = if (rawEvents.isNotEmpty()) {
                rawWidgetEventsForDay(rawEvents, targetDate).take(4)
            } else {
                emptyList()
            }

            val overflow = if (rawEvents.isNotEmpty()) {
                (rawWidgetEventsForDay(rawEvents, targetDate).size - dayEvents.size).coerceAtLeast(0)
            } else if (widgetData.contains("${weekPrefix}_${slot}_overflow_count")) {
                widgetData.getInt("${weekPrefix}_${slot}_overflow_count", 0)
            } else {
                val e1 = widgetData.getString("${weekPrefix}_${slot}_event_1_title", null)?.takeIf { it.isNotBlank() }
                val e2 = widgetData.getString("${weekPrefix}_${slot}_event_2_title", null)?.takeIf { it.isNotBlank() }
                val e3 = widgetData.getString("${weekPrefix}_${slot}_event_3_title", null)?.takeIf { it.isNotBlank() }
                val e4 = widgetData.getString("${weekPrefix}_${slot}_event_4_title", null)?.takeIf { it.isNotBlank() }
                val totalCount = widgetData.getInt("${weekPrefix}_${slot}_count", 0)
                (totalCount - listOf(e1, e2, e3, e4).count { !it.isNullOrBlank() }).coerceAtLeast(0)
            }
            val overflowPreviewTitle = if (rawEvents.isNotEmpty()) {
                rawWidgetEventsForDay(rawEvents, targetDate).drop(4).firstOrNull()?.title
            } else {
                widgetData.getString("${weekPrefix}_${slot}_overflow_preview_title", null)
                    ?: widgetData.getString("${weekPrefix}_${slot}_event_4_title", null)
            }
            val overflowLabel = formatOverflowLabel(overflowPreviewTitle, overflow)

            if (rawEvents.isNotEmpty()) {
                val eventIds = intArrayOf(
                    findViewId(context, "widget_week_list_day_${slot}_event_1"),
                    findViewId(context, "widget_week_list_day_${slot}_event_2"),
                    findViewId(context, "widget_week_list_day_${slot}_event_3"),
                    findViewId(context, "widget_week_list_day_${slot}_event_4"),
                )
                dayEvents.forEachIndexed { eventIndex, event ->
                    val eventId = eventIds.getOrNull(eventIndex) ?: 0
                    if (eventId == 0) return@forEachIndexed
                    bindEventText(
                        views,
                        eventId,
                        event.title,
                        null,
                        event.isCritical,
                    )
                    bindEventLinkIfAvailable(context, views, eventId, event.id)
                }
                if (dayEvents.isEmpty()) {
                    val firstEventId = eventIds.firstOrNull() ?: 0
                    if (firstEventId != 0) {
                        bindEventText(views, firstEventId, null, null, false, emptyText = "\uc77c\uc815 \uc5c6\uc74c")
                    }
                    for (eventIndex in 1..3) {
                        val eventId = eventIds.getOrNull(eventIndex) ?: 0
                        if (eventId != 0) {
                            views.setViewVisibility(eventId, View.GONE)
                        }
                    }
                } else {
                    for (eventIndex in dayEvents.size until 4) {
                        val eventId = eventIds.getOrNull(eventIndex) ?: 0
                        if (eventId != 0) {
                            views.setViewVisibility(eventId, View.GONE)
                        }
                    }
                }
            } else {
                for (eventSlot in 1..4) {
                    val eventId = findViewId(context, "widget_week_list_day_${slot}_event_${eventSlot}")
                    if (eventId == 0) continue
                    val title = widgetData.getString("${weekPrefix}_${slot}_event_${eventSlot}_title", null)?.takeIf { it.isNotBlank() }
                    val isCritical = widgetData.getBoolean("${weekPrefix}_${slot}_event_${eventSlot}_is_critical", false)
                    bindEventText(views, eventId, title, null, isCritical,
                        emptyText = if (eventSlot == 1) "\uc77c\uc815 \uc5c6\uc74c" else null)
                    bindEventLinkIfAvailable(context, views, eventId,
                        widgetData.getString("${weekPrefix}_${slot}_event_${eventSlot}_id", null))
                }
            }

            if (overflowLabel != null) {
                views.setTextViewText(overflowId, overflowLabel)
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
                }
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
        try {
            val rawEvents = loadRawWidgetEvents(widgetData)
            val monthOffset = widgetData.getInt(MONTH_WIDGET_OFFSET_KEY, 0)
            val cellPrefix = if (monthOffset == 0) "month_cell" else "month_offset_${monthOffset}_cell"
            val hasMonthCellPayload = hasMonthCellPayload(widgetData, cellPrefix)
            val hideWeekendCells = hideWeekends(widgetData)
            val monthStart = LocalDate.now(ZoneId.of("Asia/Seoul")).plusMonths(monthOffset.toLong()).withDayOfMonth(1)
            val fallbackCells = buildCurrentMonthFallbackCells(monthStart)

            views.setTextViewText(
                R.id.widget_month_title,
                if (rawEvents.isNotEmpty()) {
                    formatMonthOffsetTitle(monthStart)
                } else {
                    widgetData.getString(monthTitleKey(monthOffset), null) ?: fallbackMonthTitle(monthStart)
                },
            )
            bindMonthAction(context, views, R.id.widget_month_prev_button, ACTION_MONTH_PREVIOUS)
            bindMonthAction(context, views, R.id.widget_month_next_button, ACTION_MONTH_NEXT)
            bindMonthAction(context, views, R.id.widget_month_today_button, ACTION_MONTH_TODAY)

            if (rawEvents.isNotEmpty()) {
                val cellDays = fallbackCells.map { it.third }
                val slotMap = List(42) { arrayOfNulls<RawWidgetEvent>(4) }
                val overflowCounts = IntArray(42)
                val sortedEvents = rawEvents
                    .filter { it.startAt != null }
                    .sortedWith(
                        compareBy<RawWidgetEvent> { it.startAt?.toInstant() ?: Instant.MAX }
                            .thenBy { it.title },
                    )

                val multiDayEvents = sortedEvents.filter { event ->
                    val firstDay = event.startAt?.toLocalDate() ?: return@filter false
                    rawWidgetEventDisplayEndDay(event).isAfter(firstDay)
                }

                for (event in multiDayEvents) {
                    val firstDay = event.startAt?.toLocalDate() ?: continue
                    val lastDay = rawWidgetEventDisplayEndDay(event)
                    val cellIndices = cellDays.indices.filter { index ->
                        val day = cellDays[index]
                        !day.isBefore(firstDay) && !day.isAfter(lastDay)
                    }
                    if (cellIndices.isEmpty()) continue

                    var reserved = false
                    for (slot in 0 until 4) {
                        if (cellIndices.all { slotMap[it][slot] == null }) {
                            for (i in cellIndices) {
                                slotMap[i][slot] = event
                            }
                            reserved = true
                            break
                        }
                    }
                    if (!reserved) {
                        for (i in cellIndices) {
                            overflowCounts[i] += 1
                        }
                    }
                }

                for (index in 0 until 42) {
                    val day = cellDays[index]
                    val singleEvents = sortedEvents.filter { event ->
                        val startAt = event.startAt ?: return@filter false
                        val firstDay = startAt.toLocalDate()
                        val lastDay = rawWidgetEventDisplayEndDay(event)
                        !lastDay.isAfter(firstDay) && firstDay == day
                    }
                    for (event in singleEvents) {
                        var placed = false
                        for (slot in 0 until 4) {
                            if (slotMap[index][slot] == null) {
                                slotMap[index][slot] = event
                                placed = true
                                break
                            }
                        }
                        if (!placed) {
                            overflowCounts[index] += 1
                        }
                    }
                }

                // 2.5단계: overflow가 필요한 셀의 마지막 슬롯을 비워 overflow에 합산
                // 인앱 미니 캘린더와 동일한 requiresOverflowLabel 기준: 하루 교차 일정
                // 총수가 4를 초과하면 마지막 슬롯을 비워 항상 "+N개"를 표시한다.
                // (라이브 경로의 overflow 수치는 hiddenEvents.size로 동적 계산되므로
                //  slotMap만 비우면 overflow 카운트가 자동으로 올바르게 반영됨)
                for (index in 0 until 42) {
                    val totalDayEvents = rawWidgetEventsForDay(rawEvents, cellDays[index]).size
                    val requiresOverflowLabel = overflowCounts[index] > 0 || totalDayEvents > 4
                    if (requiresOverflowLabel && slotMap[index][3] != null) {
                        slotMap[index][3] = null
                    }
                }

                for (slot in 1..42) {
                    val dayId = findViewId(context, "month_cell_${slot}_day")
                        .takeIf { it != 0 }
                    val cellContainerId = findViewId(context, "month_cell_${slot}_container")
                        .takeIf { it != 0 }
                    val inMonthId = findViewId(context, "month_cell_${slot}_in_month")
                        .takeIf { it != 0 }
                    val overflowId = findViewId(context, "month_cell_${slot}_overflow_count")
                        .takeIf { it != 0 }
                    val day = cellDays[slot - 1]
                    val inMonth = day.year == monthStart.year && day.month == monthStart.month

                    if (cellContainerId != null) {
                        views.setViewVisibility(
                            cellContainerId,
                            if (hideWeekendCells && isWeekend(day)) View.GONE else View.VISIBLE,
                        )
                    }
                    if (hideWeekendCells && isWeekend(day)) {
                        continue
                    }

                    if (dayId != null) {
                        views.setTextViewText(dayId, day.dayOfMonth.toString())
                        views.setViewVisibility(dayId, View.VISIBLE)
                        val isToday = day == todayDate()
                        val isHoliday = hasHolidayEvent(rawEvents, day)
                        views.setTextColor(
                            dayId,
                            when {
                                isToday -> 0xFFFFFFFF.toInt()
                                isHoliday -> HOLIDAY_TEXT_COLOR
                                inMonth -> DEFAULT_TEXT_COLOR
                                else -> MUTED_TEXT_COLOR
                            },
                        )
                        views.setInt(
                            dayId,
                            "setBackgroundResource",
                            if (isToday) R.drawable.widget_month_today_day_background else android.R.color.transparent,
                        )
                        if (cellContainerId != null) {
                            views.setInt(
                                cellContainerId,
                                "setBackgroundResource",
                                if (isToday) {
                                    R.drawable.widget_month_cell_today_bg
                                } else {
                                    R.drawable.widget_month_cell_grid
                                },
                            )
                        }
                        bindCalendarLink(context, views, dayId, day)
                        if (cellContainerId != null) {
                            bindCalendarLink(context, views, cellContainerId, day)
                        }
                    }

                    if (inMonthId != null) {
                        views.setTextViewText(inMonthId, "")
                        views.setTextColor(inMonthId, MUTED_TEXT_COLOR)
                        views.setViewVisibility(inMonthId, View.GONE)
                    }

                    if (overflowId != null) {
                        val dayEvents = rawWidgetEventsForDay(rawEvents, day)
                        val visibleEventIds = slotMap[slot - 1]
                            .filterNotNull()
                            .map { it.id }
                            .toSet()
                        val hiddenEvents = dayEvents.filterNot { visibleEventIds.contains(it.id) }
                        val overflow = hiddenEvents.size
                        val overflowLabel = formatOverflowLabel(
                            hiddenEvents.firstOrNull()?.title,
                            overflow,
                        )
                        if (overflowLabel != null) {
                            views.setTextViewText(overflowId, overflowLabel)
                            views.setViewVisibility(overflowId, View.VISIBLE)
                        } else {
                            views.setViewVisibility(overflowId, View.GONE)
                        }
                    }

                    for (eventSlot in 1..4) {
                        val eventId = findViewId(context, "month_cell_${slot}_event_${eventSlot}_title")
                        if (eventId == 0) continue
                        val event = slotMap[slot - 1][eventSlot - 1]
                        if (event == null) {
                            views.setViewVisibility(eventId, View.GONE)
                            continue
                        }

                        val segment = rawWidgetMonthSegment(event, day)
                        val showTitle = segment == "single" || segment == "start"
                        val bgRes = monthRangeBackground(segment, event.isCritical)
                        views.setInt(eventId, "setBackgroundResource", bgRes)
                        views.setViewPadding(
                            eventId,
                            0,
                            if (event.isCritical && isMonthRangeSegment(segment) && showTitle) 1 else 0,
                            0,
                            0,
                        )
                        if (showTitle) {
                            bindEventText(
                                views,
                                eventId,
                                event.title,
                                null,
                                event.isCritical,
                                isMuted = !inMonth,
                            )
                            if (isMonthRangeSegment(segment) && inMonth) {
                                views.setTextColor(eventId, MULTI_DAY_TEXT_COLOR)
                            } else if (event.isCritical && inMonth) {
                                views.setTextColor(eventId, CRITICAL_TEXT_COLOR)
                            }
                        } else {
                            views.setTextViewText(eventId, "")
                            views.setTextColor(eventId, if (inMonth) MULTI_DAY_TEXT_COLOR else MUTED_TEXT_COLOR)
                            views.setViewVisibility(eventId, View.VISIBLE)
                        }
                    }
                }

                bindVoice(context, views, R.id.widget_month_voice_button)
                return
            }

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
                val targetDate = cellDate ?: fallbackCell?.third ?: continue

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
                val overflowLabel = formatOverflowLabel(
                    widgetData.getString("${prefix}_overflow_preview_title", null),
                    overflow,
                )

                views.setTextViewText(dayId, dayText ?: "")
                views.setViewVisibility(dayId, if (dayText == null) View.INVISIBLE else View.VISIBLE)
                val isToday = targetDate == todayDate()
                val isHoliday = hasHolidayEvent(rawEvents, targetDate)
                views.setTextColor(
                    dayId,
                    when {
                        isToday -> 0xFFFFFFFF.toInt()
                        isHoliday -> HOLIDAY_TEXT_COLOR
                        inMonth -> DEFAULT_TEXT_COLOR
                        else -> MUTED_TEXT_COLOR
                    },
                )
                views.setInt(
                    dayId,
                    "setBackgroundResource",
                    if (isToday) R.drawable.widget_month_today_day_background else android.R.color.transparent,
                )
                if (cellContainerId != 0) {
                    views.setInt(
                        cellContainerId,
                        "setBackgroundResource",
                        if (isToday) {
                            R.drawable.widget_month_cell_today_bg
                        } else {
                            R.drawable.widget_month_cell_grid
                        },
                    )
                }

                if (inMonthId != 0) {
                    views.setTextViewText(
                        inMonthId,
                        "",
                    )
                    views.setTextColor(inMonthId, MUTED_TEXT_COLOR)
                    views.setViewVisibility(inMonthId, View.GONE)
                }

                if (dayText != null) {
                    bindCalendarLink(context, views, dayId, targetDate)
                    if (cellContainerId != 0) {
                        bindCalendarLink(context, views, cellContainerId, targetDate)
                    }
                } else {
                    views.setOnClickPendingIntent(dayId, null)
                    if (cellContainerId != 0) {
                        views.setOnClickPendingIntent(cellContainerId, null)
                    }
                }

                if (overflowLabel != null) {
                    views.setTextViewText(overflowId, overflowLabel)
                    views.setViewVisibility(overflowId, View.VISIBLE)
                } else {
                    views.setViewVisibility(overflowId, View.GONE)
                }

                for (eventSlot in 1..4) {
                    val eventId = findViewId(context, "${prefix}_event_${eventSlot}_title")
                        .takeIf { it != 0 } ?: findViewId(context, "month_cell_${slot}_event_${eventSlot}_title")

                    // overflow > 0이면 마지막 슬롯(event_4)은 overflow_count에 위임 → 강제 GONE
                    if (eventSlot == 4 && overflow > 0) {
                        if (eventId != 0) views.setViewVisibility(eventId, View.GONE)
                        continue
                    }

                    val rawTitle = if (hasMonthCellPayload) {
                        widgetData.getString("${prefix}_event_${eventSlot}_title", null)?.takeIf { it.isNotBlank() }
                    } else null
                    val eventCritical = if (hasMonthCellPayload) {
                        widgetData.getBoolean("${prefix}_event_${eventSlot}_is_critical", false)
                    } else false
                    val segment = widgetData.getString("${prefix}_event_${eventSlot}_segment", null)
                    val showTitle = widgetData.getBoolean("${prefix}_event_${eventSlot}_show_title", true)

                    if (eventId != 0) {
                        // segment 배경 적용 (single은 배경 없음)
                        val bgRes = monthRangeBackground(segment, eventCritical)
                        views.setInt(eventId, "setBackgroundResource", bgRes)
                        views.setViewPadding(
                            eventId,
                            0,
                            if (eventCritical && isMonthRangeSegment(segment) && showTitle) 1 else 0,
                            0,
                            0,
                        )

                        // middle/end 셀: 빈 텍스트로 배경 bar만 표시 (GONE 방지)
                        val isBarContinuation = !showTitle && (segment == "middle" || segment == "end")
                        if (isBarContinuation && rawTitle != null) {
                            views.setTextViewText(eventId, "")
                            views.setViewVisibility(eventId, View.VISIBLE)
                        } else {
                            bindEventText(views, eventId, rawTitle, null, isCritical = eventCritical, isMuted = !inMonth)
                            if (isMonthRangeSegment(segment) && inMonth) {
                                views.setTextColor(eventId, MULTI_DAY_TEXT_COLOR)
                            } else if (eventCritical && inMonth) {
                                views.setTextColor(eventId, CRITICAL_TEXT_COLOR)
                            }
                        }
                    }
                }
            }

            bindVoice(context, views, R.id.widget_month_voice_button)
        } catch (e: Exception) {
            views.setTextViewText(R.id.widget_month_title, "일정 로드 실패 — 앱을 열어 새로고침하세요")
        }
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
