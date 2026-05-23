import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/env.dart';
import 'calendar_auto_sync_service.dart';
import 'calendar_sync_service.dart';
import 'naver_caldav_service.dart';

class ExternalCalendarSyncGuideService {
  ExternalCalendarSyncGuideService({
    SharedPreferences? preferences,
    CalendarSyncService? calendarSyncService,
    CalendarAutoSyncService? calendarAutoSyncService,
    NaverCalDavService? naverCalDavService,
  })  : _preferences = preferences,
        _calendarSyncService = calendarSyncService,
        _calendarAutoSyncService = calendarAutoSyncService,
        _naverCalDavService = naverCalDavService;

  final SharedPreferences? _preferences;
  final CalendarSyncService? _calendarSyncService;
  final CalendarAutoSyncService? _calendarAutoSyncService;
  final NaverCalDavService? _naverCalDavService;

  static String guideSeenKey(String userId) {
    return 'external_calendar_sync_guide_seen:$userId';
  }

  Future<bool> shouldShowForUser(String userId) async {
    final trimmedUserId = userId.trim();
    if (trimmedUserId.isEmpty) {
      return false;
    }

    final preferences = await _prefs();
    if (preferences.getBool(guideSeenKey(trimmedUserId)) ?? false) {
      return false;
    }

    final alreadyConfigured = await hasAnyConfiguredCalendarSync();
    if (alreadyConfigured) {
      await markSeen(trimmedUserId);
      return false;
    }

    return true;
  }

  Future<void> markSeen(String userId) async {
    final trimmedUserId = userId.trim();
    if (trimmedUserId.isEmpty) {
      return;
    }
    final preferences = await _prefs();
    await preferences.setBool(guideSeenKey(trimmedUserId), true);
  }

  Future<bool> hasAnyConfiguredCalendarSync() async {
    try {
      if (await _hasGoogleConnection()) {
        return true;
      }
      if (await _hasNaverCalDavCredentials()) {
        return true;
      }
      if (await _hasHealthyAutoSyncProvider()) {
        return true;
      }
    } catch (error, stackTrace) {
      debugPrint('External calendar sync guide check skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    return false;
  }

  Future<bool> _hasGoogleConnection() async {
    final service = _calendarSyncService ??
        CalendarSyncService(
          googleClientId: kIsWeb ? AppEnv.googleWebClientId : null,
          googleServerClientId: kIsWeb ? null : AppEnv.googleServerClientId,
        );
    final result = await service.getGoogleStatus();
    return switch (result.status) {
      CalendarIntegrationStatus.ready ||
      CalendarIntegrationStatus.syncing ||
      CalendarIntegrationStatus.synced ||
      CalendarIntegrationStatus.reauthRequired =>
        true,
      CalendarIntegrationStatus.signedOut ||
      CalendarIntegrationStatus.notConfigured ||
      CalendarIntegrationStatus.unsupported ||
      CalendarIntegrationStatus.failed =>
        false,
    };
  }

  Future<bool> _hasNaverCalDavCredentials() async {
    if (!AppEnv.isSupabaseReady && _naverCalDavService == null) {
      return false;
    }

    final service = _naverCalDavService ?? NaverCalDavService();
    try {
      return await service.hasCredentials();
    } finally {
      if (_naverCalDavService == null) {
        await service.dispose();
      }
    }
  }

  Future<bool> _hasHealthyAutoSyncProvider() async {
    final snapshot =
        await (_calendarAutoSyncService ?? CalendarAutoSyncService())
            .loadSnapshot();
    return snapshot.providers.any((provider) {
      return provider.isHealthy || provider.lastSuccessAt != null;
    });
  }

  Future<SharedPreferences> _prefs() async {
    final preferences = _preferences;
    if (preferences != null) {
      return preferences;
    }
    return SharedPreferences.getInstance();
  }
}
