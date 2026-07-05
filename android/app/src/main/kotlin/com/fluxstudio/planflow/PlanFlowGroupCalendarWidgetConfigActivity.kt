package com.fluxstudio.planflow

import android.app.Activity
import android.app.AlertDialog
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray

/**
 * 그룹 달력 위젯 설정 액티비티.
 *
 * 위젯 배치 시 자동 실행되며, "그룹 변경" 버튼으로도 재실행된다.
 *
 * 읽는 키:
 *   gw_groups_json          : JSON 배열 [{"id":"<gid>","name":"<name>"}, ...]
 *   gw_<appWidgetId>_gid    : 현재 선택된 그룹 ID (있으면 기본 선택)
 *
 * 쓰는 키:
 *   gw_<appWidgetId>_gid    : 사용자가 선택한 그룹 ID
 */
class PlanFlowGroupCalendarWidgetConfigActivity : Activity() {

    private var appWidgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 기본값: 사용자가 취소한 경우 위젯 추가 취소
        setResult(RESULT_CANCELED)

        // EXTRA_APPWIDGET_ID 가져오기
        appWidgetId = intent.getIntExtra(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID,
        )
        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }

        showGroupPickerDialog()
    }

    private fun showGroupPickerDialog() {
        val prefs = HomeWidgetPlugin.getData(this)
        val groupsJson = prefs.getString("gw_groups_json", null)?.trim()

        // 그룹 데이터 없음 처리
        if (groupsJson.isNullOrBlank()) {
            AlertDialog.Builder(this)
                .setTitle("그룹 달력")
                .setMessage("앱을 먼저 실행해 그룹을 불러오세요")
                .setPositiveButton("확인") { _, _ -> finish() }
                .setOnCancelListener { finish() }
                .show()
            return
        }

        // JSON 파싱
        val groupArray: JSONArray = try {
            JSONArray(groupsJson)
        } catch (e: Exception) {
            android.util.Log.e("GroupCalWidget", "gw_groups_json 파싱 실패: ${e.message}")
            AlertDialog.Builder(this)
                .setTitle("그룹 달력")
                .setMessage("앱을 먼저 실행해 그룹을 불러오세요")
                .setPositiveButton("확인") { _, _ -> finish() }
                .setOnCancelListener { finish() }
                .show()
            return
        }

        if (groupArray.length() == 0) {
            AlertDialog.Builder(this)
                .setTitle("그룹 달력")
                .setMessage("앱을 먼저 실행해 그룹을 불러오세요")
                .setPositiveButton("확인") { _, _ -> finish() }
                .setOnCancelListener { finish() }
                .show()
            return
        }

        // 그룹 ID / 이름 추출 (Dart 쪽이 마지막 선택 그룹을 0번째로 정렬해 전달)
        val groupIds = mutableListOf<String>()
        val groupNames = mutableListOf<String>()
        for (i in 0 until groupArray.length()) {
            val obj = groupArray.optJSONObject(i) ?: continue
            val id = obj.optString("id", "").trim()
            val name = obj.optString("name", "").trim()
            if (id.isNotBlank() && name.isNotBlank()) {
                groupIds.add(id)
                groupNames.add(name)
            }
        }

        if (groupIds.isEmpty()) {
            AlertDialog.Builder(this)
                .setTitle("그룹 달력")
                .setMessage("앱을 먼저 실행해 그룹을 불러오세요")
                .setPositiveButton("확인") { _, _ -> finish() }
                .setOnCancelListener { finish() }
                .show()
            return
        }

        // 현재 선택 그룹 (기본 선택 인덱스)
        val currentGid = prefs.getString("gw_${appWidgetId}_gid", null)?.takeIf { it.isNotBlank() }
        val defaultIndex = if (currentGid != null) {
            groupIds.indexOf(currentGid).takeIf { it >= 0 } ?: 0
        } else {
            0
        }

        var selectedIndex = defaultIndex
        AlertDialog.Builder(this)
            .setTitle("그룹 선택")
            .setSingleChoiceItems(
                groupNames.toTypedArray(),
                defaultIndex,
            ) { _, which ->
                selectedIndex = which
            }
            .setPositiveButton("확인") { _, _ ->
                val chosenGid = groupIds[selectedIndex]
                onGroupSelected(chosenGid)
            }
            .setNegativeButton("취소") { _, _ -> finish() }
            .setOnCancelListener { finish() }
            .show()
    }

    private fun onGroupSelected(gid: String) {
        // SharedPreferences에 선택 저장
        val prefs = HomeWidgetPlugin.getData(this)
        prefs.edit().putString("gw_${appWidgetId}_gid", gid).apply()

        // 프로바이더에 업데이트 브로드캐스트
        val appWidgetManager = AppWidgetManager.getInstance(this)
        val updateIntent = Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE).apply {
            component = ComponentName(this@PlanFlowGroupCalendarWidgetConfigActivity, PlanFlowGroupCalendarWidgetProvider::class.java)
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, intArrayOf(appWidgetId))
        }
        sendBroadcast(updateIntent)

        // RESULT_OK + appWidgetId 반환
        val resultIntent = Intent().apply {
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
        }
        setResult(RESULT_OK, resultIntent)
        finish()
    }
}
