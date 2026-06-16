import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/local_time.dart';
import '../data/models/event_model.dart';
import '../data/repositories/event_repository.dart'
    show EventRepository, SupabaseEventRepository;
import 'external_event_import_classifier.dart';
import 'naver_caldav_service.dart'
    show
        NaverCalDavSyncDiagnostics,
        NaverCalDavSyncMode,
        NaverCalDavSyncProgress,
        NaverCalDavSyncResult,
        NaverCalDavSyncStage,
        NaverCalDavProgressCallback;
import 'naver_calendar_permission_service.dart';

/// Naver Open API(OAuth) 기반 캘린더 import 서비스.
///
/// CalDAV 방식의 앱 비밀번호 대신 네이버 로그인 OAuth 토큰을 사용합니다.
/// [NaverCalDavSyncResult] / [NaverCalDavSyncProgress] 등 CalDAV 타입을
/// 그대로 재사용하므로 settings_screen UI 변경이 최소화됩니다.
class NaverOpenApiCalendarService {
  NaverOpenApiCalendarService({
    http.Client? httpClient,
    EventRepository? eventRepository,
    SupabaseClient? supabaseClient,
    String? currentUserId,
    NaverCalendarPermissionService? permissionService,
    NaverAccessTokenProvider? accessTokenProvider,
    Uri? findSchedulesUri,
    Duration timeout = const Duration(seconds: 12),
  })  : _httpClient = httpClient ?? http.Client(),
        _eventRepositoryOverride = eventRepository,
        _supabaseClientOverride = supabaseClient,
        _currentUserIdOverride = currentUserId,
        _permissionServiceOverride = permissionService,
        _accessTokenProviderOverride = accessTokenProvider,
        _findSchedulesUri = findSchedulesUri ??
            Uri.parse(
              'https://openapi.naver.com/calendar/findSchedules.json',
            ),
        _timeout = timeout;

  final http.Client _httpClient;
  final EventRepository? _eventRepositoryOverride;
  final SupabaseClient? _supabaseClientOverride;
  final String? _currentUserIdOverride;
  final NaverCalendarPermissionService? _permissionServiceOverride;
  final NaverAccessTokenProvider? _accessTokenProviderOverride;
  final Uri _findSchedulesUri;
  final Duration _timeout;

  static const String _logTag = 'PlanFlowNaverCalendar';

  void _log(String message) {
    debugPrint('[$_logTag] openApi $message');
  }

  static String _safeBodyExcerpt(String body) {
    final compact = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 500) {
      return compact;
    }
    return '${compact.substring(0, 500)}...';
  }

  // ---------------------------------------------------------------------------
  // 공개 API
  // ---------------------------------------------------------------------------

  /// CalDAV `syncAll`과 동일한 시그니처 → settings_screen 호출 스왑 비용 최소.
  Future<NaverCalDavSyncResult> syncAll({
    String? userId,
    DateTime? from,
    DateTime? to,
    NaverCalDavSyncMode mode = NaverCalDavSyncMode.custom,
    bool skipUnchanged = true,
    bool diagnosticImport = false,
    NaverCalDavProgressCallback? onProgress,
  }) async {
    final resolvedUserId =
        userId ?? _currentUserIdOverride ?? _currentSupabaseUserId();
    final range = _resolveSyncRange(mode: mode, from: from, to: to);
    final diagnostics = _MutableDiagnostics();

    _log(
      'syncAll start userPresent=${resolvedUserId?.isNotEmpty == true} '
      'mode=$mode from=${range.from?.toIso8601String() ?? "(null)"} '
      'to=${range.to?.toIso8601String() ?? "(null)"} '
      'skipUnchanged=$skipUnchanged diagnosticImport=$diagnosticImport',
    );

    if (resolvedUserId == null || resolvedUserId.isEmpty) {
      _log('syncAll blocked: no PlanFlow user');
      return NaverCalDavSyncResult(
        success: false,
        message: '먼저 PlanFlow에 로그인해 주세요.',
        mode: mode,
        from: range.from,
        to: range.to,
        diagnostics: diagnostics.freeze(),
      );
    }

    void emit(NaverCalDavSyncProgress progress) => onProgress?.call(progress);

    try {
      emit(NaverCalDavSyncProgress(
        mode: mode,
        stage: NaverCalDavSyncStage.preparing,
        message: '네이버 캘린더 연결을 확인하는 중입니다.',
      ));

      final accessToken = await _resolveAccessToken();
      _log(
          'syncAll accessTokenPresent=${accessToken?.trim().isNotEmpty == true}');
      if (accessToken == null || accessToken.trim().isEmpty) {
        return NaverCalDavSyncResult(
          success: false,
          message: '네이버 캘린더 권한이 연결되지 않았습니다. 설정에서 네이버 캘린더를 다시 연결해 주세요.',
          mode: mode,
          from: range.from,
          to: range.to,
          diagnostics: diagnostics.freeze(),
        );
      }

      emit(NaverCalDavSyncProgress(
        mode: mode,
        stage: NaverCalDavSyncStage.calendars,
        message: '네이버 캘린더 일정을 조회하는 중입니다.',
        totalCalendars: 1,
      ));

      final syncedAt = DateTime.now().toUtc();
      final schedules = await _fetchSchedules(
        accessToken: accessToken,
        from: range.from,
        to: range.to,
        diagnostics: diagnostics,
      );
      _log('syncAll fetched schedules count=${schedules.length}');

      emit(NaverCalDavSyncProgress(
        mode: mode,
        stage: NaverCalDavSyncStage.querying,
        message: '${schedules.length}개 일정을 확인했습니다.',
        currentCalendar: '기본 캘린더',
        currentCalendarIndex: 1,
        totalCalendars: 1,
        totalEvents: schedules.length,
      ));

      var savedCount = 0;
      var skippedCount = 0;
      var failedCount = 0;

      for (var i = 0; i < schedules.length; i++) {
        final schedule = schedules[i];
        final eventModel = _toEventModel(
          schedule,
          userId: resolvedUserId,
          syncedAt: syncedAt,
        );

        // PlanFlow에서 export한 일정 되가져오기 처리
        final planFlowOriginId =
            _planFlowEventIdFromNaverUid(schedule.uid ?? '');
        if (planFlowOriginId != null) {
          final planFlowOrigin = await _eventRepository.fetchEvent(
            planFlowOriginId,
            userId: resolvedUserId,
          );
          if (planFlowOrigin != null) {
            await _eventRepository.attachExternalSyncMetadataIfCompatible(
              existing: planFlowOrigin,
              incoming: eventModel,
            );
            skippedCount += 1;
            diagnostics.duplicateSkipped += 1;
            diagnostics.addSkipReason('PlanFlow 원본 일정 되가져오기');
            emit(_progress(
              mode: mode,
              message: 'PlanFlow에서 보낸 일정은 중복 저장하지 않는 중입니다.',
              index: i + 1,
              total: schedules.length,
              savedCount: savedCount,
              skippedCount: skippedCount,
              failedCount: failedCount,
            ));
            continue;
          }
        }

        // 같은 제목+시작시간 중복 감지
        if (!diagnosticImport) {
          final duplicate = await _findSameTitleStartDuplicate(eventModel);
          if (duplicate != null) {
            await _eventRepository.attachExternalSyncMetadataIfCompatible(
              existing: duplicate,
              incoming: eventModel,
            );
            skippedCount += 1;
            diagnostics.duplicateSkipped += 1;
            diagnostics.addSkipReason('같은 제목+시간 중복');
            emit(_progress(
              mode: mode,
              message: '이미 PlanFlow에 있는 일정은 건너뛰는 중입니다.',
              index: i + 1,
              total: schedules.length,
              savedCount: savedCount,
              skippedCount: skippedCount,
              failedCount: failedCount,
            ));
            continue;
          }
        }

        // skip-unchanged (externalUpdatedAt 기반)
        if (skipUnchanged) {
          final skipReason = await _skipUnchangedReason(eventModel);
          if (skipReason != null) {
            skippedCount += 1;
            diagnostics.unchangedSkipped += 1;
            diagnostics.addSkipReason(skipReason);
            emit(_progress(
              mode: mode,
              message: '이미 가져온 일정은 건너뛰는 중입니다.',
              index: i + 1,
              total: schedules.length,
              savedCount: savedCount,
              skippedCount: skippedCount,
              failedCount: failedCount,
            ));
            continue;
          }
        }

        // 저장
        diagnostics.saveCandidates += 1;
        try {
          await _eventRepository.upsertEventBySourceExternalId(eventModel);
          savedCount += 1;
          diagnostics.saved += 1;
        } catch (error, stackTrace) {
          failedCount += 1;
          diagnostics.failed += 1;
          diagnostics.addSkipReason('Supabase 저장 실패');
          debugPrint(
            'Naver Open API event save failed: '
            'uid="${schedule.uid}", title="${schedule.summary}", error=$error',
          );
          debugPrintStack(stackTrace: stackTrace);
        }

        emit(_progress(
          mode: mode,
          message: failedCount > 0 ? '일부 일정 저장에 실패했습니다.' : '일정을 저장하는 중입니다.',
          index: i + 1,
          total: schedules.length,
          savedCount: savedCount,
          skippedCount: skippedCount,
          failedCount: failedCount,
        ));
      }

      emit(NaverCalDavSyncProgress(
        mode: mode,
        stage: NaverCalDavSyncStage.completed,
        message: '네이버 캘린더 동기화를 마쳤습니다.',
        totalCalendars: 1,
        processedEvents: schedules.length,
        totalEvents: schedules.length,
        savedEvents: savedCount,
        skippedEvents: skippedCount,
        failedEvents: failedCount,
      ));

      final frozenDiagnostics = diagnostics.freeze();
      _log(
        'syncAll completed success=${failedCount == 0 || savedCount > 0 || skippedCount > 0} '
        'read=${schedules.length} saved=$savedCount skipped=$skippedCount '
        'failed=$failedCount diagnostics=${frozenDiagnostics.toSummaryMessage()}',
      );

      return NaverCalDavSyncResult(
        success: failedCount == 0 || savedCount > 0 || skippedCount > 0,
        message: _syncSuccessMessage(
          readCount: schedules.length,
          savedCount: savedCount,
          skippedCount: skippedCount,
          failedCount: failedCount,
          diagnostics: frozenDiagnostics,
        ),
        calendars: 1,
        events: schedules.length,
        createdOrUpdated: savedCount,
        skipped: skippedCount,
        failed: failedCount,
        mode: mode,
        from: range.from,
        to: range.to,
        diagnostics: frozenDiagnostics,
      );
    } catch (error, stackTrace) {
      _log(
        'syncAll failed type=${error.runtimeType} error=$error '
        'diagnostics=${diagnostics.freeze().toSummaryMessage()}',
      );
      debugPrintStack(stackTrace: stackTrace);
      return NaverCalDavSyncResult(
        success: false,
        message: _syncFailureMessage(error),
        mode: mode,
        from: range.from,
        to: range.to,
        error: error,
        diagnostics: diagnostics.freeze(),
      );
    }
  }

  /// OAuth 토큰 기반 캘린더 접근 가능 여부.
  Future<bool> hasCalendarAccess() async {
    try {
      _log('hasCalendarAccess start');
      final permission = await (_permissionServiceOverride ??
              NaverCalendarPermissionService(
                supabaseClient: _supabaseClientOverride,
                accessTokenProvider: _accessTokenProviderOverride,
              ))
          .refreshStatus();
      _log(
        'hasCalendarAccess result status=${permission.status.name} '
        'isGranted=${permission.isGranted} statusCode=${permission.statusCode} '
        'message=${permission.message} errorType=${permission.error?.runtimeType}',
      );
      return permission.isGranted;
    } catch (error, stackTrace) {
      _log('hasCalendarAccess failed type=${error.runtimeType} error=$error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  void dispose() {
    _httpClient.close();
  }

  // ---------------------------------------------------------------------------
  // 내부 — API fetch
  // ---------------------------------------------------------------------------

  /// 전체 기간을 3개월 윈도우로 나눠 페이지네이션 포함 fetch.
  Future<List<_NaverApiSchedule>> _fetchSchedules({
    required String accessToken,
    DateTime? from,
    DateTime? to,
    _MutableDiagnostics? diagnostics,
  }) async {
    final now = DateTime.now().toUtc();
    final effectiveFrom =
        from ?? DateTime.utc(now.year - 2, now.month, now.day);
    final effectiveTo = to ?? DateTime.utc(now.year + 1, now.month, now.day);

    // 3개월 윈도우로 분할
    final windows = <({DateTime from, DateTime to})>[];
    var windowStart = effectiveFrom;
    while (windowStart.isBefore(effectiveTo)) {
      final windowEnd = _addMonths(windowStart, 3);
      windows.add((
        from: windowStart,
        to: windowEnd.isBefore(effectiveTo) ? windowEnd : effectiveTo,
      ));
      windowStart = windowEnd;
    }

    _log(
      'fetchSchedules range from=${effectiveFrom.toIso8601String()} '
      'to=${effectiveTo.toIso8601String()} windows=${windows.length}',
    );
    final all = <_NaverApiSchedule>[];
    for (final window in windows) {
      final windowSchedules = await _fetchWindow(
        accessToken: accessToken,
        from: window.from,
        to: window.to,
        diagnostics: diagnostics,
      );
      _log(
        'fetchSchedules window from=${window.from.toIso8601String()} '
        'to=${window.to.toIso8601String()} count=${windowSchedules.length}',
      );
      all.addAll(windowSchedules);
    }
    _log('fetchSchedules total=${all.length}');
    return all;
  }

  /// 단일 윈도우에서 100건 단위 페이지네이션.
  Future<List<_NaverApiSchedule>> _fetchWindow({
    required String accessToken,
    required DateTime from,
    required DateTime to,
    _MutableDiagnostics? diagnostics,
  }) async {
    final schedules = <_NaverApiSchedule>[];
    var startIndex = 1;
    const pageSize = 100;

    while (true) {
      final uri = _findSchedulesUri.replace(
        queryParameters: <String, String>{
          'startDateTime': _formatNaverDateTime(from),
          'endDateTime': _formatNaverDateTime(to),
          'calendarId': 'defaultCalendarId',
          'startIndex': '$startIndex',
          'count': '$pageSize',
        },
      );

      _log(
        'fetchWindow request host=${uri.host} path=${uri.path} '
        'startIndex=$startIndex count=$pageSize '
        'from=${from.toIso8601String()} to=${to.toIso8601String()}',
      );
      late http.Response response;
      try {
        response = await _httpClient.get(
          uri,
          headers: <String, String>{
            HttpHeaders.authorizationHeader: 'Bearer $accessToken',
            HttpHeaders.acceptHeader: 'application/json',
          },
        ).timeout(_timeout);
      } on TimeoutException {
        throw const _NaverApiException(
          '네이버 캘린더 서버 응답 시간이 초과되었습니다.',
          isNetworkError: true,
        );
      } on SocketException {
        throw const _NaverApiException(
          '네트워크 연결을 확인해 주세요.',
          isNetworkError: true,
        );
      }
      _log(
        'fetchWindow response status=${response.statusCode} '
        'bodyLength=${response.body.length} startIndex=$startIndex',
      );

      if (response.statusCode == 401 || response.statusCode == 403) {
        _log(
          'fetchWindow permission error status=${response.statusCode} '
          'body=${_safeBodyExcerpt(response.body)}',
        );
        throw const _NaverApiException(
          '네이버 캘린더 권한이 연결되지 않았습니다. 설정에서 다시 연결해 주세요.',
          isPermissionError: true,
        );
      }
      if (response.statusCode >= 500) {
        _log(
          'fetchWindow server error status=${response.statusCode} '
          'body=${_safeBodyExcerpt(response.body)}',
        );
        throw _NaverApiException(
          '네이버 캘린더 서버 오류(${response.statusCode})가 발생했습니다. 잠시 후 다시 시도해 주세요.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 400) {
        _log(
          'fetchWindow api error status=${response.statusCode} '
          'body=${_safeBodyExcerpt(response.body)}',
        );
        throw _NaverApiException(
          '네이버 캘린더 API 오류(${response.statusCode})가 발생했습니다.',
        );
      }

      late Map<String, dynamic> body;
      try {
        body = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        _log(
          'fetchWindow json parse failed status=${response.statusCode} '
          'body=${_safeBodyExcerpt(response.body)}',
        );
        break;
      }

      // diagnostic 덤프: 첫 응답 구조 확인용
      if (startIndex == 1) {
        _log(
          'fetchWindow first page status=${response.statusCode} '
          'keys=${body.keys.toList()}',
        );
      }

      final scheduleList = _extractScheduleList(body);
      if (scheduleList == null) {
        // 응답 구조가 예상과 다를 경우 전체 응답 덤프
        _log(
          'fetchWindow unexpected response shape '
          'body=${_safeBodyExcerpt(response.body)}',
        );
        break;
      }
      _log(
        'fetchWindow scheduleListLength=${scheduleList.length} '
        'startIndex=$startIndex',
      );

      for (final item in scheduleList) {
        if (item is! Map<String, dynamic>) {
          diagnostics?.invalidEvents += 1;
          continue;
        }
        final schedule = _parseSchedule(item);
        if (schedule != null) {
          schedules.add(schedule);
          diagnostics?.parsedEvents += 1;
        } else {
          diagnostics?.invalidEvents += 1;
        }
      }
      diagnostics?.rawEvents += scheduleList.length;

      if (scheduleList.length < pageSize) {
        break; // 마지막 페이지
      }
      startIndex += pageSize;
    }

    return schedules;
  }

  /// Naver API 응답에서 일정 목록 추출.
  /// 실제 응답 구조가 확인되기 전까지 여러 키 패턴을 시도.
  List<dynamic>? _extractScheduleList(Map<String, dynamic> body) {
    // 패턴 1: result.calScheduleList
    final result = body['result'];
    if (result is Map<String, dynamic>) {
      final list = result['calScheduleList'];
      if (list is List) return list;
    }
    // 패턴 2: result가 직접 List
    if (result is List) return result;
    // 패턴 3: calScheduleList가 최상위
    final topList = body['calScheduleList'];
    if (topList is List) return topList;
    return null;
  }

  // ---------------------------------------------------------------------------
  // 내부 — 파싱 및 변환
  // ---------------------------------------------------------------------------

  _NaverApiSchedule? _parseSchedule(Map<String, dynamic> json) {
    try {
      // calId: 여러 키명 패턴 시도
      final calId = (json['calId'] ?? json['id'] ?? json['uid'])?.toString();

      // 제목
      final summary =
          (json['summary'] ?? json['title'] ?? '')?.toString() ?? '';

      // 시작/종료 시간 (여러 포맷 시도)
      final rawStart = (json['dtStart'] ??
              json['startDate'] ??
              json['start'] ??
              json['startDateTime'])
          ?.toString();
      final rawEnd = (json['dtEnd'] ??
              json['endDate'] ??
              json['end'] ??
              json['endDateTime'])
          ?.toString();

      var startAt = _parseNaverDateTime(rawStart);
      var endAt = _parseNaverDateTime(rawEnd);

      // 1970 플레이스홀더 방어: startAt이 의심스럽고 endAt이 정상이면 swap
      if (startAt != null && _isSuspiciousDate(startAt) && endAt != null) {
        debugPrint(
          'Naver Open API: recovered placeholder dtStart from dtEnd '
          'calId=$calId, rawStart=$rawStart, rawEnd=$rawEnd',
        );
        startAt = endAt;
        endAt = null;
      }

      if (startAt == null) {
        debugPrint(
          'Naver Open API: skip event with unparseable dtStart '
          'calId=$calId, rawStart=$rawStart',
        );
        return null;
      }

      if (_isSuspiciousDate(startAt)) {
        debugPrint(
          'Naver Open API: skip suspicious start date '
          'calId=$calId, startAt=$startAt',
        );
        return null;
      }

      final lastModified = _parseNaverDateTime(
        (json['lastModified'] ?? json['updatedAt'] ?? json['updated'])
            ?.toString(),
      );

      final isAllDay = json['isAllDay'] as bool? ??
          json['allDay'] as bool? ??
          rawStart?.contains('T') == false;

      final uid = (json['uid'] ?? json['icsUid'] ?? calId)?.toString();

      return _NaverApiSchedule(
        calId: calId ?? '',
        summary: summary,
        startAt: startAt,
        endAt: endAt,
        location: (json['location'] ?? json['place'])?.toString().nullIfBlank,
        description:
            (json['description'] ?? json['memo'])?.toString().nullIfBlank,
        lastModifiedAt: lastModified,
        isAllDay: isAllDay,
        uid: uid,
      );
    } catch (error, stackTrace) {
      debugPrint('Naver Open API schedule parse error: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  EventModel _toEventModel(
    _NaverApiSchedule schedule, {
    required String userId,
    required DateTime syncedAt,
  }) {
    final title = schedule.summary.trim().isEmpty
        ? '네이버 캘린더 일정'
        : schedule.summary.trim();
    return EventModel(
      id: '',
      userId: userId,
      title: title,
      startAt: schedule.startAt.toUtc(),
      endAt: schedule.endAt?.toUtc(),
      location: schedule.location,
      memo: schedule.description,
      supplies: const <String>[],
      suppliesChecked: const <String>[],
      isAllDay: schedule.isAllDay,
      isMultiDay: _isAllDayMultiDay(schedule),
      isCritical: ExternalEventImportClassifier.isCritical(
        title: schedule.summary,
        description: schedule.description,
        location: schedule.location,
        calendarPath: 'naver-api:defaultCalendarId',
        source: 'naver_api',
      ),
      source: 'naver_api',
      externalId:
          'naver-api:${schedule.calId.isNotEmpty ? schedule.calId : '${schedule.summary}_${schedule.startAt.millisecondsSinceEpoch}'}',
      externalCalendarId: 'naver-api:defaultCalendarId',
      externalEtag: null, // Open API에는 etag 없음
      externalUpdatedAt: schedule.lastModifiedAt?.toUtc() ?? syncedAt,
      lastSyncedAt: syncedAt,
    );
  }

  bool _isAllDayMultiDay(_NaverApiSchedule schedule) {
    if (!schedule.isAllDay) {
      return false;
    }
    final startAt = schedule.startAt;
    final endAt = schedule.endAt;
    if (endAt == null || !endAt.isAfter(startAt)) {
      return false;
    }
    var localEnd = planflowLocal(endAt);
    if (localEnd.hour == 0 &&
        localEnd.minute == 0 &&
        localEnd.second == 0 &&
        localEnd.millisecond == 0 &&
        localEnd.microsecond == 0) {
      localEnd = localEnd.subtract(const Duration(microseconds: 1));
    }
    return planflowLocalDay(localEnd).isAfter(planflowLocalDay(startAt));
  }

  // ---------------------------------------------------------------------------
  // 내부 — 중복/skip 로직 (CalDAV 패턴 그대로 포팅)
  // ---------------------------------------------------------------------------

  Future<String?> _skipUnchangedReason(EventModel event) async {
    final externalId = event.externalId;
    if (externalId == null || externalId.trim().isEmpty) return null;

    final existing = await _eventRepository.fetchEventBySourceExternalId(
      source: event.source,
      externalId: externalId,
      userId: event.userId,
    );
    if (existing == null) return null;

    // externalUpdatedAt 비교 (etag 없으므로)
    final incomingUpdatedAt = event.externalUpdatedAt;
    final existingUpdatedAt = existing.externalUpdatedAt;

    // 필드 변경 여부 우선 확인
    if (_hasMeaningfulDifference(event, existing)) return null;

    if (incomingUpdatedAt == null || existingUpdatedAt == null) return null;
    return !incomingUpdatedAt.toUtc().isAfter(existingUpdatedAt.toUtc())
        ? 'external_updated_at이 기존값보다 최신이 아님'
        : null;
  }

  bool _hasMeaningfulDifference(EventModel incoming, EventModel existing) {
    if (incoming.title.trim() != existing.title.trim()) return true;
    if (!_sameInstant(incoming.startAt, existing.startAt)) return true;
    if (!_sameInstant(incoming.endAt, existing.endAt)) return true;
    if ((incoming.location ?? '') != (existing.location ?? '')) return true;
    if ((incoming.memo ?? '') != (existing.memo ?? '')) return true;
    return false;
  }

  bool _sameInstant(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == null && b == null;
    return a.toUtc().isAtSameMomentAs(b.toUtc());
  }

  Future<EventModel?> _findSameTitleStartDuplicate(EventModel event) async {
    final startAt = event.startAt;
    if (startAt == null) return null;
    return _eventRepository.findEventByTitleAndStart(
      title: event.title,
      startAt: startAt,
      userId: event.userId,
      excludedSources: const <String>{'naver_api', 'naver_caldav'},
    );
  }

  String? _planFlowEventIdFromNaverUid(String uid) {
    const prefix = 'planflow-';
    const suffix = '@planflow';
    final normalized = uid.trim();
    if (!normalized.startsWith(prefix) || !normalized.endsWith(suffix)) {
      return null;
    }
    final id = normalized.substring(
      prefix.length,
      normalized.length - suffix.length,
    );
    return id.isEmpty ? null : id;
  }

  // ---------------------------------------------------------------------------
  // 내부 — 유틸리티
  // ---------------------------------------------------------------------------

  EventRepository get _eventRepository {
    if (_eventRepositoryOverride != null) return _eventRepositoryOverride;
    final client = _supabaseClientOrNull ?? Supabase.instance.client;
    return SupabaseEventRepository(client: client);
  }

  SupabaseClient? get _supabaseClientOrNull {
    if (_supabaseClientOverride != null) return _supabaseClientOverride;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  String? _currentSupabaseUserId() {
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _resolveAccessToken() async {
    if (_accessTokenProviderOverride != null) {
      _log('resolveAccessToken source=override');
      final token = await _accessTokenProviderOverride();
      _log(
          'resolveAccessToken override tokenPresent=${token?.trim().isNotEmpty == true}');
      return token;
    }
    final permService = _permissionServiceOverride ??
        NaverCalendarPermissionService(
          supabaseClient: _supabaseClientOrNull,
        );
    _log('resolveAccessToken source=permissionService');
    final token = await permService.resolveAccessTokenForCalendar();
    _log(
        'resolveAccessToken permissionService tokenPresent=${token?.trim().isNotEmpty == true}');
    return token;
  }

  ({DateTime? from, DateTime? to}) _resolveSyncRange({
    required NaverCalDavSyncMode mode,
    DateTime? from,
    DateTime? to,
  }) {
    if (mode == NaverCalDavSyncMode.all) {
      return (from: from?.toUtc(), to: to?.toUtc());
    }
    if (from != null || to != null) {
      return (from: from?.toUtc(), to: to?.toUtc());
    }
    final now = DateTime.now().toUtc();
    return (
      from: DateTime.utc(now.year, now.month - 3, now.day),
      to: DateTime.utc(now.year, now.month + 6, now.day),
    );
  }

  NaverCalDavSyncProgress _progress({
    required NaverCalDavSyncMode mode,
    required String message,
    required int index,
    required int total,
    required int savedCount,
    required int skippedCount,
    required int failedCount,
  }) {
    return NaverCalDavSyncProgress(
      mode: mode,
      stage: NaverCalDavSyncStage.saving,
      message: message,
      currentCalendar: '기본 캘린더',
      currentCalendarIndex: 1,
      totalCalendars: 1,
      processedEvents: index,
      totalEvents: total,
      savedEvents: savedCount,
      skippedEvents: skippedCount,
      failedEvents: failedCount,
    );
  }

  bool _isSuspiciousDate(DateTime value) => value.toUtc().year < 2000;

  /// Naver API datetime 파싱.
  /// 지원 포맷: ISO8601, YYYYMMDD, YYYYMMDDTHHmmss±HHmm 등 방어적으로 처리.
  DateTime? _parseNaverDateTime(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final s = raw.trim();

    // ISO 8601 표준 시도
    try {
      return DateTime.parse(s).toUtc();
    } catch (_) {}

    // YYYYMMDDTHHMMSS+0900 형식 시도
    final compact = RegExp(
      r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})([+-]\d{4})?$',
    );
    final m = compact.firstMatch(s);
    if (m != null) {
      try {
        final offsetStr = m.group(7) ?? '+0000';
        final offsetSign = offsetStr[0] == '-' ? -1 : 1;
        final offsetH = int.parse(offsetStr.substring(1, 3));
        final offsetMin = int.parse(offsetStr.substring(3, 5));
        final offset = Duration(
          hours: offsetH * offsetSign,
          minutes: offsetMin * offsetSign,
        );
        final naive = DateTime(
          int.parse(m.group(1)!),
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
          int.parse(m.group(4)!),
          int.parse(m.group(5)!),
          int.parse(m.group(6)!),
        );
        return naive.subtract(offset).toUtc();
      } catch (_) {}
    }

    // YYYYMMDD (all-day) 시도 — 서울 자정 UTC 기준
    final dateOnly = RegExp(r'^(\d{4})(\d{2})(\d{2})$');
    final dm = dateOnly.firstMatch(s);
    if (dm != null) {
      try {
        return planflowSeoulDateTimeToUtc(
          DateTime(
            int.parse(dm.group(1)!),
            int.parse(dm.group(2)!),
            int.parse(dm.group(3)!),
          ),
        );
      } catch (_) {}
    }

    debugPrint('Naver Open API: unable to parse datetime "$raw"');
    return null;
  }

  /// Naver API 쿼리용 날짜 포맷 — ISO 8601 UTC 형식.
  String _formatNaverDateTime(DateTime dt) {
    final utc = dt.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}'
        '${utc.month.toString().padLeft(2, '0')}'
        '${utc.day.toString().padLeft(2, '0')}'
        'T'
        '${utc.hour.toString().padLeft(2, '0')}'
        '${utc.minute.toString().padLeft(2, '0')}'
        '${utc.second.toString().padLeft(2, '0')}'
        '+0000';
  }

  DateTime _addMonths(DateTime dt, int months) {
    var year = dt.year;
    var month = dt.month + months;
    while (month > 12) {
      month -= 12;
      year += 1;
    }
    while (month < 1) {
      month += 12;
      year -= 1;
    }
    return DateTime.utc(year, month, dt.day);
  }

  String _syncSuccessMessage({
    required int readCount,
    required int savedCount,
    required int skippedCount,
    required int failedCount,
    NaverCalDavSyncDiagnostics? diagnostics,
  }) {
    if (savedCount > 0) {
      final parts = <String>[
        '네이버 캘린더 일정 $savedCount개를 PlanFlow로 가져왔습니다.',
        if (skippedCount > 0) '중복/변경 없음 $skippedCount개는 건너뛰었습니다.',
        if (failedCount > 0) '저장 실패 $failedCount개가 있습니다.',
      ];
      return parts.join(' ');
    }
    if (failedCount > 0) {
      return '네이버 캘린더에서 일정 $readCount개를 읽었지만 $failedCount개 저장에 실패했습니다.';
    }
    if (skippedCount > 0) {
      return '네이버 캘린더에서 일정 $readCount개를 읽었고, '
          '기존 일정 $skippedCount개는 중복 또는 변경 없음으로 건너뛰었습니다.';
    }
    if (readCount > 0) {
      return '네이버 캘린더에서 일정 $readCount개를 읽었지만 저장할 새 일정이 없습니다.';
    }
    return '네이버 캘린더 연결은 성공했지만 가져올 일정이 없습니다.';
  }

  String _syncFailureMessage(Object error) {
    if (error is _NaverApiException) {
      return error.message;
    }
    final text = error.toString();
    if (text.contains('권한') || text.contains('scope')) {
      return '네이버 캘린더 권한이 연결되지 않았습니다. 설정에서 다시 연결해 주세요.';
    }
    if (text.contains('TimeoutException') || text.contains('timeout')) {
      return '네이버 캘린더 서버 응답 시간이 초과되었습니다. 잠시 후 다시 시도해 주세요.';
    }
    if (text.contains('SocketException')) {
      return '네트워크 연결을 확인해 주세요.';
    }
    return '네이버 캘린더 일정 가져오기에 실패했습니다. 네트워크와 계정 설정을 확인해 주세요.';
  }
}

// ---------------------------------------------------------------------------
// 내부 데이터 모델
// ---------------------------------------------------------------------------

class _NaverApiSchedule {
  const _NaverApiSchedule({
    required this.calId,
    required this.summary,
    required this.startAt,
    this.endAt,
    this.location,
    this.description,
    this.lastModifiedAt,
    this.isAllDay = false,
    this.uid,
  });

  final String calId;
  final String summary;
  final DateTime startAt;
  final DateTime? endAt;
  final String? location;
  final String? description;
  final DateTime? lastModifiedAt;
  final bool isAllDay;
  final String? uid; // ICS UID (PlanFlow 원본 필터링용)
}

class _NaverApiException implements Exception {
  const _NaverApiException(
    this.message, {
    this.isPermissionError = false,
    this.isNetworkError = false,
  });

  final String message;
  final bool isPermissionError;
  final bool isNetworkError;

  @override
  String toString() => message;
}

extension on String {
  String? get nullIfBlank => trim().isEmpty ? null : trim();
}

// ---------------------------------------------------------------------------
// 내부 — mutable diagnostics 빌더
// ---------------------------------------------------------------------------

class _MutableDiagnostics {
  int rawEvents = 0;
  int parsedEvents = 0;
  int invalidEvents = 0;
  int saveCandidates = 0;
  int duplicateSkipped = 0;
  int unchangedSkipped = 0;
  int saved = 0;
  int failed = 0;
  final Map<String, int> skipReasons = <String, int>{};

  void addSkipReason(String reason) {
    skipReasons.update(reason, (c) => c + 1, ifAbsent: () => 1);
  }

  NaverCalDavSyncDiagnostics freeze() => NaverCalDavSyncDiagnostics(
        rawEvents: rawEvents,
        parsedEvents: parsedEvents,
        invalidEvents: invalidEvents,
        saveCandidates: saveCandidates,
        duplicateSkipped: duplicateSkipped,
        unchangedSkipped: unchangedSkipped,
        saved: saved,
        failed: failed,
        skipReasons: Map<String, int>.unmodifiable(skipReasons),
      );
}
