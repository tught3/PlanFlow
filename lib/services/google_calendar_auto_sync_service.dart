import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/diag_logger.dart';
import '../core/env.dart';
import '../core/log_text.dart';
import '../providers/auth_provider.dart';
import 'calendar_sync_service.dart';
import 'event_refresh_bus.dart';

class GoogleCalendarAutoSyncService {
  GoogleCalendarAutoSyncService({
    CalendarSyncService? calendarSyncService,
    Duration throttle = const Duration(minutes: 15),
    DateTime Function()? now,
  })  : _calendarSyncService = calendarSyncService,
        _throttle = throttle,
        _now = now ?? DateTime.now;

  final CalendarSyncService? _calendarSyncService;
  final Duration _throttle;
  final DateTime Function() _now;

  DateTime? _lastAttemptAt;
  bool _isSyncing = false;

  Future<void> syncIfAllowed({String reason = 'app_lifecycle'}) async {
    DiagLogger.log(
      'DIAG',
      'googleAutoSync enter reason=${logSafeText(reason)} '
          'currentUser=${logSafeText(Supabase.instance.client.auth.currentUser?.id)}',
    );
    if (_isSyncing || !AppEnv.isSupabaseReady || !authProvider.isSignedIn) {
      return;
    }

    final now = _now();
    final lastAttemptAt = _lastAttemptAt;
    if (lastAttemptAt != null && now.difference(lastAttemptAt) < _throttle) {
      return;
    }

    _lastAttemptAt = now;
    _isSyncing = true;
    try {
      final service = _calendarSyncService ??
          CalendarSyncService(
            googleClientId: kIsWeb ? AppEnv.googleWebClientId : null,
            googleServerClientId: kIsWeb ? null : AppEnv.googleServerClientId,
          );
      DiagLogger.log(
        'DIAG',
        'googleAutoSync calling syncGoogleCalendar(interactive:false) '
            'currentUser=${logSafeText(Supabase.instance.client.auth.currentUser?.id)}',
      );
      final result = await service.syncGoogleCalendar(interactive: false);
      if (result.status == CalendarIntegrationStatus.synced ||
          result.status == CalendarIntegrationStatus.ready) {
        EventRefreshBus.instance.notifyChanged(
          reason: 'google_calendar_auto_sync:$reason',
        );
      }
      debugPrint(
        'Google Calendar auto sync result: ${result.status} ${result.syncedItems}',
      );
    } catch (error, stackTrace) {
      debugPrint('Google Calendar auto sync skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      _isSyncing = false;
    }
  }
}
