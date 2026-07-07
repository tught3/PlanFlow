package com.fluxstudio.planflow

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * 그룹 달력 홈 위젯 프로바이더.
 *
 * SharedPreferences 키 규약 (home_widget 플러그인 기본 파일 공유):
 *   gw_groups_json           : JSON 배열 [{"id":"<gid>","name":"<name>"}, ...]
 *   gw_<appWidgetId>_gid     : 이 위젯 인스턴스에 선택된 그룹 ID
 *   gw_<gid>_name            : 그룹 표시 이름
 *   gw_<gid>_title           : 현재 달 타이틀 문자열 (폴백용, 오프셋 0일 때만 참고)
 *   gw_<gid>_occurrences_json: JSON 배열 [{"d":"yyyy-MM-dd","n":"표시이름"}, ...]
 *                              (현재월 ±12개월 범위, 다일 일정은 걸치는 모든 날짜에 항목이 이미 펼쳐져 있음)
 *
 *   ※ 과거 셀별 키(gw_<gid>_c<i>_d/_m/_t/_n/_names)는 더 이상 사용하지 않는다.
 *      달 그리드/타이틀은 오프셋 기준으로 이 provider가 직접 계산한다.
 *
 * 딥링크: planflow://group-calendar?groupId=<gid>
 */
class PlanFlowGroupCalendarWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val ACTION_GROUP_MONTH_PREVIOUS = "com.fluxstudio.planflow.widget.GROUP_MONTH_PREVIOUS"
        private const val ACTION_GROUP_MONTH_NEXT = "com.fluxstudio.planflow.widget.GROUP_MONTH_NEXT"
        private const val ACTION_GROUP_MONTH_TODAY = "com.fluxstudio.planflow.widget.GROUP_MONTH_TODAY"
        private const val GROUP_MONTH_WIDGET_OFFSET_KEY = "gw_month_offset"
        private val OCCURRENCE_DATE_FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd")
        private val PLANFLOW_ZONE = ZoneId.of("Asia/Seoul")
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_GROUP_MONTH_PREVIOUS, ACTION_GROUP_MONTH_NEXT, ACTION_GROUP_MONTH_TODAY -> {
                val prefs = HomeWidgetPlugin.getData(context)
                val nextOffset = when (intent.action) {
                    ACTION_GROUP_MONTH_PREVIOUS -> prefs.getInt(GROUP_MONTH_WIDGET_OFFSET_KEY, 0) - 1
                    ACTION_GROUP_MONTH_NEXT -> prefs.getInt(GROUP_MONTH_WIDGET_OFFSET_KEY, 0) + 1
                    else -> 0
                }
                prefs.edit().putInt(GROUP_MONTH_WIDGET_OFFSET_KEY, nextOffset).apply()

                val manager = AppWidgetManager.getInstance(context)
                val ids = manager.getAppWidgetIds(
                    ComponentName(context, PlanFlowGroupCalendarWidgetProvider::class.java),
                )
                onUpdate(context, manager, ids)
                return
            }
        }
        super.onReceive(context, intent)
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val prefs = HomeWidgetPlugin.getData(context)
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.planflow_group_calendar_widget)
            try {
                val gid = prefs.getString("gw_${appWidgetId}_gid", null)?.takeIf { it.isNotBlank() }
                if (gid == null) {
                    // 그룹 미선택 — 플레이스홀더 표시
                    renderPlaceholder(context, views, appWidgetId)
                } else {
                    renderCalendar(context, views, prefs, appWidgetId, gid)
                }
            } catch (e: Exception) {
                android.util.Log.e("GroupCalendarWidget", "onUpdate failed for $appWidgetId: ${e.message}", e)
                renderPlaceholder(context, views, appWidgetId)
            }
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        // 위젯 삭제 시 해당 인스턴스 gid 설정 제거
        val prefs = HomeWidgetPlugin.getData(context)
        val editor = prefs.edit()
        for (appWidgetId in appWidgetIds) {
            editor.remove("gw_${appWidgetId}_gid")
        }
        editor.apply()
        super.onDeleted(context, appWidgetIds)
    }

    // ── 플레이스홀더 렌더링 ──────────────────────────────────────────────────────

    private fun renderPlaceholder(context: Context, views: RemoteViews, appWidgetId: Int) {
        views.setViewVisibility(R.id.group_cal_header, View.GONE)
        views.setViewVisibility(R.id.group_cal_dow_header, View.GONE)
        views.setViewVisibility(R.id.group_cal_grid, View.GONE)
        views.setViewVisibility(R.id.group_cal_empty_hint, View.VISIBLE)
        views.setTextViewText(R.id.group_cal_empty_hint, "탭하여 그룹 선택")

        // 탭 → 설정 액티비티 열기
        val configIntent = buildConfigIntent(context, appWidgetId)
        views.setOnClickPendingIntent(R.id.group_cal_empty_hint, configIntent)
        views.setOnClickPendingIntent(R.id.group_cal_root, configIntent)
    }

    // ── 달력 렌더링 ──────────────────────────────────────────────────────────────

    private fun renderCalendar(
        context: Context,
        views: RemoteViews,
        prefs: SharedPreferences,
        appWidgetId: Int,
        gid: String,
    ) {
        views.setViewVisibility(R.id.group_cal_empty_hint, View.GONE)
        views.setViewVisibility(R.id.group_cal_header, View.VISIBLE)
        views.setViewVisibility(R.id.group_cal_dow_header, View.VISIBLE)
        views.setViewVisibility(R.id.group_cal_grid, View.VISIBLE)

        val monthOffset = prefs.getInt(GROUP_MONTH_WIDGET_OFFSET_KEY, 0)
        val today = LocalDate.now(PLANFLOW_ZONE)
        val monthStart = today.plusMonths(monthOffset.toLong()).withDayOfMonth(1)

        // 헤더
        val groupName = prefs.getString("gw_${gid}_name", null) ?: "그룹 달력"
        val monthTitle = if (monthOffset == 0) {
            prefs.getString("gw_${gid}_title", null) ?: formatMonthTitle(monthStart)
        } else {
            formatMonthTitle(monthStart)
        }
        views.setTextViewText(R.id.header_group, groupName)
        views.setTextViewText(R.id.header_month, monthTitle)

        // "그룹 변경" 버튼 → 설정 액티비티
        val configIntent = buildConfigIntent(context, appWidgetId)
        views.setOnClickPendingIntent(R.id.btn_change_group, configIntent)

        // 전체 위젯 탭 → 그룹 달력 딥링크
        val deepLinkIntent = buildDeepLinkIntent(context, gid)
        views.setOnClickPendingIntent(R.id.group_cal_root, deepLinkIntent)

        // 이전/다음 달 이동 버튼 + 타이틀 탭 → 이번 달로 복귀
        bindMonthAction(context, views, R.id.group_cal_prev, ACTION_GROUP_MONTH_PREVIOUS)
        bindMonthAction(context, views, R.id.group_cal_next, ACTION_GROUP_MONTH_NEXT)
        bindMonthAction(context, views, R.id.header_month, ACTION_GROUP_MONTH_TODAY)

        // 42칸 그리드 날짜 계산 (일요일 시작, 6주)
        val cellDays = buildMonthGridDays(monthStart)

        // 발생분 파싱: 날짜 문자열 → 이름별 개수 맵
        val occurrencesByDay: Map<LocalDate, Map<String, Int>> = parseOccurrences(prefs, gid)

        for (i in 0 until 42) {
            val day = cellDays[i]
            val inMonth = day.year == monthStart.year && day.month == monthStart.month
            val isToday = day == today

            val dayViewId = context.resources.getIdentifier("cell_${i}_day", "id", context.packageName)
            val countViewId = context.resources.getIdentifier("cell_${i}_count", "id", context.packageName)
            val cellContainerId = context.resources.getIdentifier("cell_${i}_container", "id", context.packageName)

            if (dayViewId == 0 || countViewId == 0) continue

            // 날짜 숫자
            views.setTextViewText(dayViewId, day.dayOfMonth.toString())

            // 오늘 강조(개인 위젯과 동일하게 날짜 숫자에 원 배경 + 흰 글자) vs 다른 달 흐리게
            val dayColor = when {
                isToday -> 0xFFFFFFFF.toInt()           // 흰색 (오늘 원 배경 위)
                inMonth -> 0xFF203A57.toInt()           // 진한 파랑 (현재 달)
                else -> 0xFF9AADC0.toInt()             // 흐린 색 (전/다음 달)
            }
            views.setTextColor(dayViewId, dayColor)
            views.setInt(
                dayViewId,
                "setBackgroundResource",
                if (isToday) R.drawable.widget_month_today_day_background else android.R.color.transparent,
            )

            // 오늘 셀 배경 (격자선은 기본, 오늘은 연한 파랑 강조)
            if (cellContainerId != 0) {
                views.setInt(
                    cellContainerId,
                    "setBackgroundResource",
                    if (isToday) R.drawable.widget_month_cell_today_bg else R.drawable.widget_month_cell_grid,
                )
            }

            // 멤버별 "이름 개수건" 요약
            val namesForDay = occurrencesByDay[day]
            val summaryText = namesForDay
                ?.entries
                ?.sortedByDescending { it.value }
                ?.joinToString("\n") { (name, count) -> "$name ${count}개" }
                ?.takeIf { it.isNotBlank() }

            if (summaryText != null) {
                views.setTextViewText(countViewId, summaryText)
                views.setTextColor(countViewId, 0xFF17181C.toInt())
                views.setViewVisibility(countViewId, View.VISIBLE)
            } else {
                views.setTextViewText(countViewId, "")
                views.setViewVisibility(countViewId, View.GONE)
            }
        }
    }

    // ── 그리드/파싱 헬퍼 ─────────────────────────────────────────────────────────

    /** 대상 달의 42칸(6주 x 7일, 일요일 시작) 그리드 날짜 목록 생성. */
    private fun buildMonthGridDays(monthStart: LocalDate): List<LocalDate> {
        // DayOfWeek.value: 월=1 ... 일=7. %7 → 일=0, 월=1 ... 토=6 (일요일 시작 오프셋)
        val startOffset = monthStart.dayOfWeek.value % 7
        val firstCellDate = monthStart.minusDays(startOffset.toLong())
        return List(42) { index -> firstCellDate.plusDays(index.toLong()) }
    }

    private fun formatMonthTitle(monthStart: LocalDate): String {
        return "${monthStart.year}년 ${monthStart.monthValue}월"
    }

    /** gw_<gid>_occurrences_json을 파싱해 날짜별 {이름: 개수} 맵을 만든다. 실패 시 빈 맵으로 폴백. */
    private fun parseOccurrences(prefs: SharedPreferences, gid: String): Map<LocalDate, Map<String, Int>> {
        val raw = prefs.getString("gw_${gid}_occurrences_json", null)?.takeIf { it.isNotBlank() }
            ?: return emptyMap()

        val result = HashMap<LocalDate, HashMap<String, Int>>()
        try {
            val array = JSONArray(raw)
            for (i in 0 until array.length()) {
                val item = array.optJSONObject(i) ?: continue
                val dateStr = item.optString("d", "").takeIf { it.isNotBlank() } ?: continue
                val name = item.optString("n", "").takeIf { it.isNotBlank() } ?: continue
                val day = try {
                    LocalDate.parse(dateStr, OCCURRENCE_DATE_FORMATTER)
                } catch (e: Exception) {
                    continue
                }
                val dayMap = result.getOrPut(day) { HashMap() }
                dayMap[name] = (dayMap[name] ?: 0) + 1
            }
        } catch (e: Exception) {
            android.util.Log.e("GroupCalendarWidget", "occurrences parse failed for $gid: ${e.message}", e)
            return emptyMap()
        }
        return result
    }

    // ── 인텐트 빌더 ──────────────────────────────────────────────────────────────

    private fun bindMonthAction(context: Context, views: RemoteViews, viewId: Int, action: String) {
        if (viewId == 0) return
        val intent = Intent(context, PlanFlowGroupCalendarWidgetProvider::class.java).apply {
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

    private fun buildConfigIntent(context: Context, appWidgetId: Int): PendingIntent {
        val intent = Intent(context, PlanFlowGroupCalendarWidgetConfigActivity::class.java).apply {
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
            // 각 appWidgetId마다 고유한 인텐트가 되도록 data URI 설정
            data = Uri.parse("planflow-config://group-calendar/$appWidgetId")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            context,
            appWidgetId,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun buildDeepLinkIntent(context: Context, gid: String): PendingIntent {
        val uri = Uri.Builder()
            .scheme("planflow")
            .authority("group-calendar")
            .appendQueryParameter("groupId", gid)
            .build()
        val intent = Intent(Intent.ACTION_VIEW, uri).apply {
            setClass(context, MainActivity::class.java)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        return PendingIntent.getActivity(
            context,
            // gid 기반 요청 코드 (충돌 방지)
            ("deeplink_$gid").hashCode() and 0x7FFFFFFF,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
