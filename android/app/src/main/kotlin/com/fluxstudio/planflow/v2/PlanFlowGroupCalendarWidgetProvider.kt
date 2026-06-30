package com.fluxstudio.planflow.v2

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray

/**
 * 그룹 달력 홈 위젯 프로바이더.
 *
 * SharedPreferences 키 규약 (home_widget 플러그인 기본 파일 공유):
 *   gw_groups_json          : JSON 배열 [{"id":"<gid>","name":"<name>"}, ...]
 *   gw_<appWidgetId>_gid    : 이 위젯 인스턴스에 선택된 그룹 ID
 *   gw_<gid>_name           : 그룹 표시 이름
 *   gw_<gid>_title          : 월 레이블 e.g. "2026년 7월"
 *   gw_<gid>_c<i>_d         : i번 셀의 날짜 숫자 문자열 (0..41)
 *   gw_<gid>_c<i>_m         : "1" = 현재 달 셀, "0" = 이전/다음 달 셀
 *   gw_<gid>_c<i>_t         : "1" = 오늘 셀
 *   gw_<gid>_c<i>_n         : 일정 수 (정수 문자열)
 *
 * 딥링크: planflow-v2://group-calendar?groupId=<gid>
 */
class PlanFlowGroupCalendarWidgetProvider : AppWidgetProvider() {

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
        prefs: android.content.SharedPreferences,
        appWidgetId: Int,
        gid: String,
    ) {
        views.setViewVisibility(R.id.group_cal_empty_hint, View.GONE)
        views.setViewVisibility(R.id.group_cal_header, View.VISIBLE)
        views.setViewVisibility(R.id.group_cal_dow_header, View.VISIBLE)
        views.setViewVisibility(R.id.group_cal_grid, View.VISIBLE)

        // 헤더
        val groupName = prefs.getString("gw_${gid}_name", null) ?: "그룹 달력"
        val monthTitle = prefs.getString("gw_${gid}_title", null) ?: ""
        views.setTextViewText(R.id.header_group, groupName)
        views.setTextViewText(R.id.header_month, monthTitle)

        // "그룹 변경" 버튼 → 설정 액티비티
        val configIntent = buildConfigIntent(context, appWidgetId)
        views.setOnClickPendingIntent(R.id.btn_change_group, configIntent)

        // 전체 위젯 탭 → 그룹 달력 딥링크
        val deepLinkIntent = buildDeepLinkIntent(context, gid)
        views.setOnClickPendingIntent(R.id.group_cal_root, deepLinkIntent)

        // 42개 셀 바인딩
        for (i in 0 until 42) {
            val dayStr = prefs.getString("gw_${gid}_c${i}_d", null) ?: ""
            val inMonth = prefs.getString("gw_${gid}_c${i}_m", "0") == "1"
            val isToday = prefs.getString("gw_${gid}_c${i}_t", "0") == "1"
            val count = prefs.getString("gw_${gid}_c${i}_n", "0")?.toIntOrNull() ?: 0

            val dayViewId = context.resources.getIdentifier("cell_${i}_day", "id", context.packageName)
            val countViewId = context.resources.getIdentifier("cell_${i}_count", "id", context.packageName)
            val cellContainerId = context.resources.getIdentifier("cell_${i}_container", "id", context.packageName)

            if (dayViewId == 0 || countViewId == 0) continue

            // 날짜 숫자
            views.setTextViewText(dayViewId, dayStr)

            // 오늘 강조 vs 다른 달 흐리게
            val dayColor = when {
                isToday -> 0xFF183A5D.toInt()           // 진한 남색 (오늘 하이라이트 배경 위)
                inMonth -> 0xFF203A57.toInt()           // 진한 파랑 (현재 달)
                else -> 0xFF9AADC0.toInt()             // 흐린 색 (전/다음 달)
            }
            views.setTextColor(dayViewId, dayColor)

            // 오늘 배경
            if (cellContainerId != 0) {
                if (isToday) {
                    views.setInt(cellContainerId, "setBackgroundResource", R.drawable.widget_today_highlight_background)
                } else {
                    views.setInt(cellContainerId, "setBackgroundResource", android.R.color.transparent)
                }
            }

            // 일정 수 표시
            if (count > 0) {
                views.setTextViewText(countViewId, "${count}건")
                views.setViewVisibility(countViewId, View.VISIBLE)
            } else {
                views.setTextViewText(countViewId, "")
                views.setViewVisibility(countViewId, View.GONE)
            }
        }
    }

    // ── 인텐트 빌더 ──────────────────────────────────────────────────────────────

    private fun buildConfigIntent(context: Context, appWidgetId: Int): PendingIntent {
        val intent = Intent(context, PlanFlowGroupCalendarWidgetConfigActivity::class.java).apply {
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
            // 각 appWidgetId마다 고유한 인텐트가 되도록 data URI 설정
            data = Uri.parse("planflow-v2-config://group-calendar/$appWidgetId")
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
            .scheme("planflow-v2")
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
