package com.fluxstudio.planflow

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.text.TextPaint
import android.text.TextUtils
import android.util.TypedValue
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
 * 딥링크: planflow://group-calendar?groupId=<gid>[&date=yyyy-MM-dd]
 *   - date 없음: 위젯 전체(헤더 등) 탭 — 그룹 캘린더 화면으로 진입(기본 보기).
 *   - date 있음: 날짜 셀 탭 — 그 날짜를 캘린더 보기로 강제 진입해 해당 날짜의
 *     그룹일정을 바로 보여준다.
 */
class PlanFlowGroupCalendarWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val ACTION_GROUP_MONTH_PREVIOUS = "com.fluxstudio.planflow.widget.GROUP_MONTH_PREVIOUS"
        private const val ACTION_GROUP_MONTH_NEXT = "com.fluxstudio.planflow.widget.GROUP_MONTH_NEXT"
        private const val ACTION_GROUP_MONTH_TODAY = "com.fluxstudio.planflow.widget.GROUP_MONTH_TODAY"
        private const val GROUP_MONTH_WIDGET_OFFSET_KEY = "gw_month_offset"
        // 한 날짜 칸에 실제로 보여줄 최대 멤버 줄 수. 넘으면 마지막 줄을
        // "+N명"으로 대체한다(전체 멤버 목록을 그대로 다 이어붙이면 인원이
        // 많을 때 셀이 끝없이 길어져 균일한 GridLayout 행 높이를 넘친다).
        private const val MAX_VISIBLE_MEMBERS_PER_CELL = 4
        private val OCCURRENCE_DATE_FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd")
        private val PLANFLOW_ZONE = ZoneId.of("Asia/Seoul")

        // planflow_group_calendar_widget.xml의 cell_N_count textSize(8.5sp bold)와 반드시 일치시킬 것.
        private const val CELL_COUNT_TEXT_SIZE_SP = 8.5f
        // cell_N_container의 paddingLeft(1dp) + paddingRight(1dp) 합.
        private const val CELL_CONTAINER_HORIZONTAL_PADDING_DP = 2f
        // 위젯 옵션 조회 실패 시 폴백으로 쓸 셀 텍스트 폭(dp 상당).
        private const val FALLBACK_CELL_TEXT_WIDTH_DP = 100f
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

        // 셀 요약 텍스트("이름 N개")가 칸 폭을 넘지 않도록, 실제 렌더 폭을 미리 측정해둔다.
        // 위젯당 1회만 계산(셀마다 반복 계산할 필요 없음). 측정 실패 시 안전한 폴백 폭 사용.
        val cellTextWidthPx = measureCellTextWidthPx(context, appWidgetId)
        val summaryTextPaint = TextPaint().apply {
            isAntiAlias = true
            isFakeBoldText = true
            textSize = TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_SP,
                CELL_COUNT_TEXT_SIZE_SP,
                context.resources.displayMetrics,
            )
        }

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

            // 멤버별 "이름 개수건" 요약. 멤버가 많아질수록 줄이 끝없이 늘어나면
            // 셀이 넘치므로(균일한 GridLayout 행 높이를 넘어감), 최대
            // MAX_VISIBLE_MEMBERS_PER_CELL명까지만 실제로 보여주고, 그보다
            // 많으면 마지막 줄을 "+N명"으로 대체한다(개인/주간 위젯과 동일한
            // "마지막 칸 대체" 패턴 — 별도 줄을 추가하는 대신 자리 하나를
            // 대신 차지하게 해 항상 정해진 줄 수 안에 들어오게 한다).
            val sortedMembers = occurrencesByDay[day]
                ?.entries
                ?.sortedByDescending { it.value }
                ?: emptyList()
            val summaryLines = if (sortedMembers.size > MAX_VISIBLE_MEMBERS_PER_CELL) {
                val visible = sortedMembers.take(MAX_VISIBLE_MEMBERS_PER_CELL - 1)
                val hiddenMemberCount = sortedMembers.size - visible.size
                visible.map { (name, count) ->
                    buildFittedSummaryLine(name, count, summaryTextPaint, cellTextWidthPx)
                } + "+${hiddenMemberCount}명"
            } else {
                sortedMembers.map { (name, count) ->
                    buildFittedSummaryLine(name, count, summaryTextPaint, cellTextWidthPx)
                }
            }
            val summaryText = summaryLines
                .joinToString("\n")
                .takeIf { it.isNotBlank() }

            if (summaryText != null) {
                views.setTextViewText(countViewId, summaryText)
                views.setTextColor(countViewId, 0xFF17181C.toInt())
                views.setViewVisibility(countViewId, View.VISIBLE)
            } else {
                views.setTextViewText(countViewId, "")
                views.setViewVisibility(countViewId, View.GONE)
            }

            // 날짜 셀 탭 → 그 날짜의 그룹일정으로 딥링크(위젯 전체 탭의 groupId-only
            // 링크보다 우선 적용됨: RemoteViews는 자식 뷰에 명시적으로 설정된
            // PendingIntent가 있으면 그 영역에서는 부모의 것 대신 자식 것을 쓴다).
            val dayDeepLink = buildDeepLinkIntent(context, gid, day)
            views.setOnClickPendingIntent(dayViewId, dayDeepLink)
            if (cellContainerId != 0) {
                views.setOnClickPendingIntent(cellContainerId, dayDeepLink)
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

    /**
     * 위젯 인스턴스의 실제 폭(OPTION_APPWIDGET_MIN_WIDTH)을 읽어 셀 하나("42칸 그리드"는 7열)당
     * 텍스트가 쓸 수 있는 폭(px)을 추정한다. 옵션 조회 실패/값 없음이면 폴백 폭을 반환한다.
     * 런처마다 실제 렌더 크기가 조금씩 다를 수 있어 완벽한 정확도는 보장하지 않으며,
     * 크래시 없이 안전하게 동작하는 것을 우선한다.
     */
    private fun measureCellTextWidthPx(context: Context, appWidgetId: Int): Int {
        val density = context.resources.displayMetrics.density
        val fallbackPx = (FALLBACK_CELL_TEXT_WIDTH_DP * density).toInt().coerceAtLeast(1)
        return try {
            val options = AppWidgetManager.getInstance(context).getAppWidgetOptions(appWidgetId)
            val minWidthDp = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0) ?: 0
            if (minWidthDp <= 0) {
                fallbackPx
            } else {
                val totalWidthPx = minWidthDp * density
                val cellWidthPx = totalWidthPx / 7f
                val horizontalPaddingPx = CELL_CONTAINER_HORIZONTAL_PADDING_DP * density
                (cellWidthPx - horizontalPaddingPx).toInt().coerceAtLeast(1)
            }
        } catch (e: Exception) {
            android.util.Log.e("GroupCalendarWidget", "cell width measure failed for $appWidgetId: ${e.message}", e)
            fallbackPx
        }
    }

    /**
     * "이름 N개" 한 줄을 셀 텍스트 폭(availableWidthPx)에 맞춘다. " N개" 접미사는 항상 완전하게
     * 유지하고, 이름 부분만 남는 폭에 맞춰 TextUtils.ellipsize로 말줄임표를 붙여 자른다.
     * 측정/자르기 도중 예외가 나면 자르지 않은 원본 "이름 N개"로 폴백한다(안전성 우선).
     */
    private fun buildFittedSummaryLine(
        name: String,
        count: Int,
        paint: TextPaint,
        availableWidthPx: Int,
    ): String {
        val suffix = " ${count}개"
        return try {
            val suffixWidth = paint.measureText(suffix)
            val availableForName = (availableWidthPx - suffixWidth).coerceAtLeast(0f)
            val fittedName = TextUtils.ellipsize(name, paint, availableForName, TextUtils.TruncateAt.END)
            "$fittedName$suffix"
        } catch (e: Exception) {
            android.util.Log.e("GroupCalendarWidget", "summary line fit failed: ${e.message}", e)
            "$name$suffix"
        }
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

    /**
     * 그룹 달력 딥링크 PendingIntent를 만든다. [date]가 주어지면
     * `planflow://group-calendar?groupId=<gid>&date=yyyy-MM-dd`로,
     * 앱은 그 날짜를 캘린더 보기로 강제 진입해 해당 날짜의 그룹일정을 바로
     * 보여준다(날짜 셀 클릭용). [date]가 null이면 groupId만 넣어 위젯 전체
     * 탭(헤더 등)의 기본 진입 링크로 쓴다.
     */
    private fun buildDeepLinkIntent(context: Context, gid: String, date: LocalDate? = null): PendingIntent {
        val uriBuilder = Uri.Builder()
            .scheme("planflow")
            .authority("group-calendar")
            .appendQueryParameter("groupId", gid)
        if (date != null) {
            uriBuilder.appendQueryParameter("date", date.format(OCCURRENCE_DATE_FORMATTER))
        }
        val uri = uriBuilder.build()
        val intent = Intent(Intent.ACTION_VIEW, uri).apply {
            setClass(context, MainActivity::class.java)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        // gid(+날짜) 기반 요청 코드로 셀마다 서로 다른 PendingIntent가 되게 한다.
        // 같지 않으면 FLAG_UPDATE_CURRENT가 이전 셀의 date extra로 덮어써 모든 셀이
        // 같은(마지막) 날짜로 열리는 문제가 생긴다.
        val requestKey = if (date != null) "deeplink_${gid}_$date" else "deeplink_$gid"
        return PendingIntent.getActivity(
            context,
            requestKey.hashCode() and 0x7FFFFFFF,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
