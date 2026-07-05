# PlanFlow 프로젝트 디렉토리 구조

> 생성 일시: 2026-07-05
> 스캔 대상: 프로젝트 루트 전체 (`.git`, `build`, `.dart_tool`, `.flutter-plugins-dependencies` 제외)

---

## 루트 파일

```
.flux/
.env.example
.gitignore
.metadata
AGENTS.md
CLAUDE.md
analysis_options.yaml
deploy-planflow.bat
firebase.json
l10n.yaml
planflow_v2_group_home_structure.md
planflowlogo.png
pubspec.lock
pubspec.yaml
skills-lock.json
TASK_20260606_123120_done.md
TASK_20260607_030411_done.md
TASK_20260608_004809_done.md
TASK_20260608_141130_done.md
```

---

## lib/ — 메인 애플리케이션 코드

### lib/ (최상위)
```
app.dart
firebase_options.dart
main.dart
```

### lib/core/
```
analytics_service.dart
constants.dart
diag_logger.dart
env.dart
event_metadata.dart
local_time.dart
log_text.dart
region_settings.dart
responsive.dart
router.dart
runtime_error_filter.dart
safe_prefs.dart
startup_route_gate.dart
supabase_auth_options.dart
supabase_client.dart
theme.dart
time_format_controller.dart
```

### lib/data/
```
models/
  calendar_connection_model.dart
  early_bird_email_model.dart
  event_model.dart
  feedback_report_model.dart
  pre_action_model.dart
  user_settings_model.dart
  voice_correction_rule.dart
repositories/
  calendar_connection_repository.dart
  early_bird_email_repository.dart
  event_repository.dart
  feedback_repository.dart
  settings_repository.dart
  voice_correction_rule_repository.dart
```

### lib/features/
```
groups/
  models/
    calendar_overlay_item.dart
    group_backup_model.dart
    group_event_comment_model.dart
    group_event_model.dart
    group_event_recurrence.dart
    group_invite_model.dart
    group_json.dart
    group_member_model.dart
    group_model.dart
    group_role_delegation_model.dart
  providers/
    group_calendar_overlay_provider.dart
    group_calendar_overlay_state.dart
    group_context_provider.dart
    group_context_state.dart
    group_dashboard_provider.dart
    group_dashboard_state.dart
    group_event_provider.dart
    group_event_state.dart
    group_invite_provider.dart
    group_invite_state.dart
    group_member_provider.dart
    group_member_state.dart
  repositories/
    group_backup_repository.dart
    group_dashboard_repository.dart
    group_delegation_repository.dart
    group_event_comment_repository.dart
    group_event_repository.dart
    group_invite_repository.dart
    group_repository.dart
  screens/
    group_create_screen.dart
    group_dashboard_screen.dart
    group_detail_screen.dart
    group_event_create_screen.dart
    group_event_detail_screen.dart
    group_event_list_screen.dart
    group_invite_link_screen.dart
    group_invite_screen.dart
    group_list_screen.dart
    group_member_screen.dart
  services/
    group_calendar_widget_service.dart
    group_event_share_service.dart
    group_instruction_inbox_service.dart
  widgets/
    group_event_tile.dart
    group_month_calendar.dart
    group_multi_select_sheet.dart
    member_shared_events_sheet.dart

plan/
  models/
    plan_model.dart
  providers/
    plan_provider.dart
    plan_state.dart
  repositories/
    plan_repository.dart
  screens/
    plan_create_screen.dart
    plan_detail_screen.dart
    plan_list_screen.dart

task/
  models/
    task_model.dart
  providers/
    task_state.dart
  repositories/
    task_repository.dart
```

### lib/l10n/
```
app_en.arb
app_ko.arb
app_l10n.dart
app_localizations.dart
app_localizations_en.dart
app_localizations_ko.dart
```

### lib/providers/
```
auth_provider.dart
settings_provider.dart
```

### lib/screens/
```
placeholder_screen.dart
shell_screen.dart

auth/
  login_screen.dart
  reset_password_screen.dart
briefing/
  briefing_launch_screen.dart
calendar/
  calendar_screen.dart
  calendar_widgets.dart
event/
  event_detail_screen.dart
  event_edit_screen.dart
home/
  home_screen.dart
  home_widgets.dart
location/
  location_pick_flow.dart
  location_picker_screen.dart
onboarding/
  permission_onboarding_screen.dart
settings/
  beta_survey_sheet.dart
  feedback_report_sheet.dart
  naver_ics_import_screen.dart
  settings_screen.dart
  settings_widgets.dart
splash/
  splash_screen.dart
voice/
  confirm_screen.dart
  confirm_widgets.dart
  voice_action_screen.dart
  voice_action_widgets.dart
  voice_conversation_screen.dart
  voice_input_screen.dart
```

### lib/services/
```
alarm_service.dart
api_usage_guard.dart
app_feedback_service.dart
app_permission_service.dart
auth_service.dart
background_task_service.dart
backup_service.dart
battery_optimization_service.dart
briefing_scheduler_service.dart
calendar_auto_sync_service.dart
calendar_sync_service.dart
critical_alarm_channel_migration_service.dart
daily_backup_scheduler_service.dart
departure_acknowledgement_store.dart
departure_alarm_service.dart
device_calendar_service.dart
event_prefetch_service.dart
event_preparation_service.dart
event_range_utils.dart
event_refresh_bus.dart
event_reminder_channel_migration_service.dart
external_calendar_sync_guide_service.dart
external_event_import_classifier.dart
gpt_service.dart
home_header_summary_service.dart
home_widget_platform.dart
home_widget_platform_io.dart
home_widget_platform_stub.dart
home_widget_service.dart
location_lookup_service.dart
manual_event_side_effect_service.dart
map_service.dart
naver_caldav_remote_store.dart
naver_caldav_service.dart
naver_calendar_launch_service.dart
naver_calendar_permission_service.dart
naver_ics_import_service.dart
naver_ics_share_store.dart
naver_open_api_calendar_service.dart
notification_service.dart
oauth_callback_handler.dart
remote_config_service.dart
review_service.dart
smart_preparation_alarm_service.dart
smart_preparation_payload_migration_service.dart
stt_service.dart
travel_time_buffer_service.dart
tts_service.dart
update_service.dart
voice_command_analysis_service.dart
voice_command_pipeline.dart
voice_command_router.dart
voice_conversation_controller.dart
voice_correction_learning_service.dart
voice_date_range_parser.dart
voice_schedule_structure_service.dart
voice_text_cleanup_service.dart
```

### lib/shared/
```
README.md
constants/
  constants.dart
extensions/
  extensions.dart
utils/
  utils.dart
widgets/
  widgets.dart
```

### lib/widgets/
```
calendar_style_event_editor.dart
location_resolution_status.dart
overlap_warning_dialog.dart
planflow_action_buttons.dart
planflow_logo.dart
planflow_voice_fab.dart
recurrence_selector.dart
reminder_offset_selector.dart
schedule_save_scope_card.dart
```

---

## test/ — 단위/위젯 테스트

### test/ (최상위)
```
android_deep_link_guard_test.dart
app_home_widget_route_test.dart
```

### test/core/
```
app_env_test.dart
local_time_test.dart
responsive_test.dart
router_group_route_order_test.dart
runtime_error_filter_test.dart
supabase_auth_options_test.dart
supabase_client_test.dart
```

### test/data/
```
models/
  early_bird_email_model_test.dart
  event_model_test.dart
  pre_action_model_test.dart
  user_settings_model_test.dart
repositories/
  early_bird_email_repository_test.dart
  event_repository_external_import_test.dart
  event_repository_overlap_test.dart
  feedback_repository_test.dart
  settings_repository_test.dart
  voice_correction_rule_repository_test.dart
```

### test/features/
```
groups/
  group_backup_model_test.dart
  group_backup_repository_test.dart
  group_calendar_overlay_provider_test.dart
  group_context_provider_test.dart
  group_create_screen_test.dart
  group_dashboard_provider_test.dart
  group_dashboard_repository_test.dart
  group_dashboard_screen_test.dart
  group_detail_screen_test.dart
  group_event_comment_model_test.dart
  group_event_create_screen_test.dart
  group_event_detail_screen_test.dart
  group_event_list_screen_test.dart
  group_event_provider_test.dart
  group_event_recurrence_test.dart
  group_event_share_service_test.dart
  group_invite_provider_test.dart
  group_invite_repository_test.dart
  group_invite_screen_test.dart
  group_list_screen_test.dart
  group_member_provider_test.dart
  group_member_repository_test.dart
  group_member_screen_test.dart
```

### test/providers/
```
auth_provider_test.dart
settings_provider_test.dart
```

### test/screens/
```
briefing_launch_screen_test.dart
calendar_day_events_sheet_test.dart
calendar_deeplink_test.dart
calendar_marker_test.dart
calendar_screen_test.dart
confirm_screen_test.dart
event_detail_screen_test.dart
event_edit_screen_test.dart
feedback_report_sheet_test.dart
home_recent_past_events_test.dart
home_screen_test.dart
location_picker_screen_test.dart
login_screen_test.dart
permission_onboarding_screen_test.dart
settings_screen_test.dart
shell_swipe_gesture_test.dart
splash_screen_test.dart
voice_action_screen_test.dart
voice_conversation_screen_test.dart
voice_input_screen_test.dart
```

### test/services/
```
api_usage_guard_test.dart
auth_service_test.dart
background_task_service_test.dart
backup_service_test.dart
battery_optimization_service_test.dart
briefing_scheduler_service_test.dart
calendar_auto_sync_service_test.dart
calendar_sync_service_test.dart
critical_alarm_channel_migration_service_test.dart
departure_alarm_service_test.dart
device_calendar_service_test.dart
event_prefetch_service_test.dart
event_preparation_service_test.dart
external_calendar_sync_guide_service_test.dart
external_event_import_classifier_test.dart
gpt_service_test.dart
home_header_summary_service_test.dart
home_widget_service_test.dart
location_lookup_service_test.dart
manual_event_side_effect_service_test.dart
map_service_test.dart
naver_caldav_credential_store_test.dart
naver_caldav_service_test.dart
naver_calendar_permission_service_test.dart
naver_ics_import_service_test.dart
naver_open_api_calendar_service_test.dart
notification_service_test.dart
oauth_callback_handler_test.dart
smart_preparation_alarm_service_test.dart
stt_service_test.dart
travel_time_buffer_service_test.dart
update_service_test.dart
voice_command_analysis_service_test.dart
voice_command_pipeline_test.dart
voice_command_router_test.dart
voice_conversation_controller_test.dart
voice_correction_learning_service_test.dart
voice_date_range_parser_test.dart
voice_schedule_structure_service_test.dart
voice_text_cleanup_service_test.dart
```

### test/supabase/
```
feedback_reports_schema_test.dart
user_settings_schema_test.dart
voice_correction_learning_schema_test.dart
```

### test/widgets/
```
calendar_style_event_editor_test.dart
planflow_action_buttons_test.dart
planflow_logo_test.dart
recurrence_selector_test.dart
reminder_offset_selector_test.dart
```

---

## supabase/ — 백엔드 데이터베이스 및 엣지 함수

### supabase/ (최상위)
```
calendar_sync_patch.sql
early_bird_planflow_patch.sql
feedback_reports_admin_policy_fix.sql
feedback_reports_patch.sql
in_project_backup.sql
pre_actions_source_patch.sql
schema.sql
user_settings_patch.sql
```

### supabase/functions/
```
naver-geocode/
  index.ts
naver-userinfo-proxy/
  index.ts
openai-proxy/
  index.ts
```

### supabase/migrations/
```
20260525000000_naver_caldav_mirror.sql
20260528000000_voice_correction_learning.sql
20260530000000_naver_caldav_columns_deprecate.sql
20260618000000_backfill_is_critical_from_pre_actions.sql
20260619000000_add_use_strong_alarm.sql
20260621000000_add_events_parent_event_id.sql
20260627113841_feedback_reports_web_support.sql
20260629000000_add_briefing_enabled.sql
20260629010000_add_use_24_hour_format.sql
20260629090000_group_invite_links.sql
20260629093000_group_invite_link_target_fix.sql
20260629114509_group_member_display_names.sql
20260629161352_allow_group_members_create_events.sql
20260629163725_link_personal_and_group_events.sql
20260701090000_group_event_comments.sql
20260704120000_group_leave.sql
20260704140000_group_event_creator_can_modify.sql
20260704160000_group_event_owner_only_modify.sql
```

---

## assets/
```
naver_app_password/
```

---

## docs/ — 문서

### docs/ (최상위)
```
account-deletion.html
checklist-1-supabase-schema.md
checklist-2-env-setup.md
current_codebase_status.md
database-backup-runbook.md
debug-filledbutton-row-layout-crash.md
final-setup-checklist.md
launch-strategy.md
maintenance-data-structure.md
naver-supabase-custom-provider.md
planflow-signing.md
play-console-data-safety.md
play-console-submission.md
play-store-listing.md
post-verification-next-steps.md
privacy-policy.html
privacy-policy.md
project_analysis.md
release-console-checklist.md
supabase-auth-backup-setup.md
whats-new-1.1.0.md
```

### docs/analysis/
```
codebase_audit.md
project_context.md
```

### docs/planflow-v2/
```
01-team-erd-draft.md
02-team-screen-flow.md
03-team-permission-policy.md
04-team-v2-mvp-scope.md
05-v2-product-structure.md
06-v2-role-and-visibility-pipeline.md
09-v2-final-master-design.md
10-v2-open-decisions-final.md
11-v2-erd-draft.md
12-v2-rls-policy-design.md
13-v2-schema-sql-draft.md
14-v2-flutter-module-plan.md
15-v2-erd-review.md
16-v2-schema-sql-final-draft.md
17-v2-db-implementation-review.md
18-v2-e2e-qa-checklist.md
19-v2-supabase-deployment-plan.md
20-v2-supabase-verification-sql.md
21-v2-existing-supabase-apply-plan.md
22-v2-real-device-smoke-test.md
23-main-tracking-overlay-policy.md
24-v2-deploy-status-check.md
README.md
team-v2-plan.md
```

### docs/screenshots/
```
(스크린샷 이미지 디렉토리)
```

### docs/widget-previews/
```
(위젯 미리보기 이미지 디렉토리)
```

---

## scripts/ — 빌드/배포 스크립트
```
_scan_patterns.py
adb-install-update.ps1
build-internal-aab.ps1
bump-version-code.ps1
deploy-play-internal.ps1
flutter-local.ps1
gsd-context-hygiene.mjs
planflow-db-backup.ps1
planflow-release-bootstrap.ps1
register-planflow-db-backup-task.ps1
restore-planflow-signing.ps1
send-telegram.ps1
```

---

## 기타 디렉토리

### android/
Flutter Android 네이티브 프로젝트 (표준 구조)

### ios/
Flutter iOS 네이티브 프로젝트 (표준 구조)

### linux/
Flutter Linux 네이티브 프로젝트 (표준 구조)

### macos/
Flutter macOS 네이티브 프로젝트 (표준 구조)

### web/
Flutter 웹 프로젝트 (표준 구조)

### windows/
Flutter Windows 네이티브 프로젝트 (표준 구조)

### screenshots/
앱 스토어 스크린샷

### env/
환경 설정 관련 디렉토리

### .agents/
에이전트 설정

### .planning/
플래닝 문서

### .vscode/
VS Code 설정

---

## integration_test/

> ⚠️ `integration_test/` 디렉토리가 존재하지 않습니다. 통합 테스트가 아직 작성되지 않았습니다.

---

## 통계 요약

| 항목 | 개수 |
|---|---|
| lib/ Dart 파일 | ~150+ |
| test/ Dart 파일 | ~90+ |
| supabase 마이그레이션 | 18개 |
| supabase 엣지 함수 | 3개 |
| docs/ 문서 | 40+ |
| scripts/ 스크립트 | 12개 |
| integration_test/ | 없음 |
