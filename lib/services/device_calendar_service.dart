import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models/event_model.dart';
import '../data/repositories/event_repository.dart';

enum DeviceCalendarImportStatus {
  imported,
  permissionDenied,
  noCalendars,
  noNaverCalendars,
  noEvents,
  failed,
}

class DeviceCalendarImportResult {
  const DeviceCalendarImportResult({
    required this.status,
    required this.message,
    this.importedCount = 0,
    this.calendars = const <DeviceCalendarInfo>[],
    this.error,
  });

  final DeviceCalendarImportStatus status;
  final String message;
  final int importedCount;
  final List<DeviceCalendarInfo> calendars;
  final Object? error;

  bool get isSuccess => status == DeviceCalendarImportStatus.imported;
}

class DeviceCalendarInfo {
  const DeviceCalendarInfo({
    required this.id,
    this.name,
    this.displayName,
    this.accountName,
    this.accountType,
    this.ownerAccount,
    this.isPrimary,
    this.visible,
    this.syncEvents,
  });

  factory DeviceCalendarInfo.fromMap(Map<Object?, Object?> map) {
    return DeviceCalendarInfo(
      id: _stringValue(map['id']),
      name: _nullableString(map['name']),
      displayName: _nullableString(map['displayName']),
      accountName: _nullableString(map['accountName']),
      accountType: _nullableString(map['accountType']),
      ownerAccount: _nullableString(map['ownerAccount']),
      isPrimary: _boolValue(map['isPrimary']),
      visible: _boolValue(map['visible']),
      syncEvents: _boolValue(map['syncEvents']),
    );
  }

  final String id;
  final String? name;
  final String? displayName;
  final String? accountName;
  final String? accountType;
  final String? ownerAccount;
  final bool? isPrimary;
  final bool? visible;
  final bool? syncEvents;

  String get label {
    final candidates = <String?>[displayName, name, accountName, accountType];
    return candidates.firstWhere(
      (value) => value != null && value.trim().isNotEmpty,
      orElse: () => '기기 캘린더 $id',
    )!;
  }

  bool get isNaverCandidate {
    final haystack = <String?>[
      name,
      displayName,
      accountName,
      accountType,
      ownerAccount,
    ].whereType<String>().join(' ').toLowerCase();
    return haystack.contains('naver') || haystack.contains('네이버');
  }
}

class DeviceCalendarEvent {
  const DeviceCalendarEvent({
    required this.eventId,
    required this.calendarId,
    required this.begin,
    this.end,
    this.title,
    this.description,
    this.location,
    this.allDay,
    this.externalUpdatedAt,
  });

  factory DeviceCalendarEvent.fromMap(Map<Object?, Object?> map) {
    return DeviceCalendarEvent(
      eventId: _stringValue(map['eventId']),
      calendarId: _stringValue(map['calendarId']),
      title: _nullableString(map['title']),
      description: _nullableString(map['description']),
      location: _nullableString(map['location']),
      begin: _dateTimeFromMillis(map['beginMillis']) ??
          _dateTimeFromMillis(map['dtstartMillis']) ??
          DateTime.now().toUtc(),
      end: _dateTimeFromMillis(map['endMillis']) ??
          _dateTimeFromMillis(map['dtendMillis']),
      allDay: _boolValue(map['allDay']),
      externalUpdatedAt: _dateTimeFromMillis(map['lastDateMillis']),
    );
  }

  final String eventId;
  final String calendarId;
  final String? title;
  final String? description;
  final String? location;
  final DateTime begin;
  final DateTime? end;
  final bool? allDay;
  final DateTime? externalUpdatedAt;

  EventModel toEventModel({
    required String userId,
    required DateTime importedAt,
  }) {
    final normalizedTitle = title?.trim();
    return EventModel(
      id: '',
      userId: userId,
      title: normalizedTitle == null || normalizedTitle.isEmpty
          ? '휴대폰 내부 캘린더 일정'
          : normalizedTitle,
      startAt: begin.toUtc(),
      endAt: end?.toUtc(),
      location: _blankToNull(location),
      memo: _blankToNull(description),
      supplies: const <String>[],
      suppliesChecked: const <String>[],
      isCritical: false,
      source: 'naver_device',
      externalId: 'android:$calendarId:$eventId',
      externalCalendarId: 'android:$calendarId',
      externalUpdatedAt: externalUpdatedAt?.toUtc() ?? importedAt,
      lastSyncedAt: importedAt,
    );
  }
}

abstract class DeviceCalendarGateway {
  Future<bool> checkCalendarPermission();

  Future<bool> requestCalendarPermission();

  Future<List<Map<Object?, Object?>>> listDeviceCalendars();

  Future<List<Map<Object?, Object?>>> listDeviceCalendarEvents({
    required List<String> calendarIds,
    required DateTime startAt,
    required DateTime endAt,
  });

  Future<bool> upsertDeviceCalendarEvent(EventModel event);
}

class MethodChannelDeviceCalendarGateway implements DeviceCalendarGateway {
  const MethodChannelDeviceCalendarGateway();

  static const MethodChannel _channel =
      MethodChannel('planflow/android_permissions');

  @override
  Future<bool> checkCalendarPermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    return await _channel.invokeMethod<bool>('checkCalendarPermission') ??
        false;
  }

  @override
  Future<bool> requestCalendarPermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    return await _channel.invokeMethod<bool>('requestCalendarPermission') ??
        false;
  }

  @override
  Future<List<Map<Object?, Object?>>> listDeviceCalendars() async {
    final result = await _channel.invokeMethod<List<Object?>>(
      'listDeviceCalendars',
    );
    return _mapListResult(result);
  }

  @override
  Future<List<Map<Object?, Object?>>> listDeviceCalendarEvents({
    required List<String> calendarIds,
    required DateTime startAt,
    required DateTime endAt,
  }) async {
    final result = await _channel.invokeMethod<List<Object?>>(
      'listDeviceCalendarEvents',
      <String, Object?>{
        'calendarIds': calendarIds,
        'startMillis': startAt.millisecondsSinceEpoch,
        'endMillis': endAt.millisecondsSinceEpoch,
      },
    );
    return _mapListResult(result);
  }

  @override
  Future<bool> upsertDeviceCalendarEvent(EventModel event) async {
    final startAt = event.startAt;
    if (startAt == null ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    final result = await _channel.invokeMethod<bool>(
      'upsertDeviceCalendarEvent',
      <String, Object?>{
        'eventKey': 'planflow:${event.id}',
        'title': event.title,
        'description': event.memo,
        'location': event.location,
        'startMillis': startAt.millisecondsSinceEpoch,
        'endMillis': (event.endAt ?? startAt.add(const Duration(minutes: 30)))
            .millisecondsSinceEpoch,
        'allDay': false,
      },
    );
    return result ?? false;
  }

  List<Map<Object?, Object?>> _mapListResult(List<Object?>? result) {
    return (result ?? const <Object?>[])
        .whereType<Map>()
        .map((row) => Map<Object?, Object?>.from(row))
        .toList(growable: false);
  }
}

class DeviceCalendarService {
  DeviceCalendarService({
    DeviceCalendarGateway? gateway,
    EventRepository? eventRepository,
    SupabaseClient? client,
    String? currentUserId,
  })  : _gateway = gateway ?? const MethodChannelDeviceCalendarGateway(),
        _eventRepositoryOverride = eventRepository,
        _client = client,
        _currentUserId = currentUserId;

  final DeviceCalendarGateway _gateway;
  final EventRepository? _eventRepositoryOverride;
  final SupabaseClient? _client;
  final String? _currentUserId;

  EventRepository get _eventRepository =>
      _eventRepositoryOverride ?? EventRepository.supabase();

  Future<bool> checkCalendarPermission() {
    return _gateway.checkCalendarPermission();
  }

  Future<bool> requestCalendarPermission() {
    return _gateway.requestCalendarPermission();
  }

  Future<List<DeviceCalendarInfo>> listCalendars() async {
    final rows = await _gateway.listDeviceCalendars();
    _throwIfNativeError(rows);
    return rows
        .map(DeviceCalendarInfo.fromMap)
        .where((calendar) => calendar.id.trim().isNotEmpty)
        .toList(growable: false);
  }

  List<DeviceCalendarInfo> findNaverCalendars(
    List<DeviceCalendarInfo> calendars,
  ) {
    return calendars
        .where((calendar) => calendar.isNaverCandidate)
        .toList(growable: false);
  }

  Future<DeviceCalendarImportResult> importNaverEvents({
    String? userId,
    DateTime? startAt,
    DateTime? endAt,
  }) async {
    final resolvedUserId = userId ??
        _currentUserId ??
        _client?.auth.currentSession?.user.id ??
        _client?.auth.currentUser?.id;
    if (resolvedUserId == null || resolvedUserId.isEmpty) {
      return const DeviceCalendarImportResult(
        status: DeviceCalendarImportStatus.failed,
        message: '먼저 PlanFlow에 로그인해 주세요.',
      );
    }

    final hasPermission = await _gateway.checkCalendarPermission() ||
        await _gateway.requestCalendarPermission();
    if (!hasPermission) {
      return const DeviceCalendarImportResult(
        status: DeviceCalendarImportStatus.permissionDenied,
        message: '기기 캘린더 권한이 필요합니다. Android 앱 설정에서 캘린더 권한을 허용해 주세요.',
      );
    }

    try {
      final calendars = await listCalendars();
      if (calendars.isEmpty) {
        return const DeviceCalendarImportResult(
          status: DeviceCalendarImportStatus.noCalendars,
          message: '휴대폰에서 읽을 수 있는 캘린더가 없습니다.',
        );
      }

      final naverCalendars = findNaverCalendars(calendars);
      debugPrint(
        'Device calendars: ${calendars.map((calendar) => '${calendar.id}:${calendar.label}:${calendar.accountName ?? ''}').join(', ')}',
      );
      debugPrint(
        'Naver device calendar candidates: ${naverCalendars.map((calendar) => '${calendar.id}:${calendar.label}:${calendar.accountName ?? ''}').join(', ')}',
      );
      if (naverCalendars.isEmpty) {
        return DeviceCalendarImportResult(
          status: DeviceCalendarImportStatus.noNaverCalendars,
          message:
              '휴대폰 캘린더 저장소에서 내부 캘린더를 찾지 못했습니다. 네이버 캘린더 앱 또는 삼성 캘린더에서 기기 동기화가 켜져 있는지 확인해 주세요.',
          calendars: calendars,
        );
      }

      final now = DateTime.now().toUtc();
      final rows = await _gateway.listDeviceCalendarEvents(
        calendarIds: naverCalendars.map((calendar) => calendar.id).toList(),
        startAt: startAt ?? now.subtract(const Duration(days: 1)),
        endAt: endAt ?? now.add(const Duration(days: 365)),
      );
      _throwIfNativeError(rows);
      debugPrint(
        'Naver device calendar event rows: ${rows.length} from calendars ${naverCalendars.map((calendar) => calendar.id).join(',')}',
      );

      final events = rows
          .map(DeviceCalendarEvent.fromMap)
          .where(
            (event) =>
                event.eventId.trim().isNotEmpty &&
                event.calendarId.trim().isNotEmpty,
          )
          .toList(growable: false);
      if (events.isEmpty) {
        final labels = naverCalendars
            .map(
              (calendar) =>
                  '${calendar.label}(${calendar.accountName ?? calendar.id})',
            )
            .join(', ');
        return DeviceCalendarImportResult(
          status: DeviceCalendarImportStatus.noEvents,
          message:
              '휴대폰 내부 캘린더는 보이지만 가져올 일정이 없습니다. 확인된 캘린더: $labels. 네이버 캘린더 앱에서 휴대폰/삼성 캘린더 동기화가 켜져 있는지 확인해 주세요.',
          calendars: naverCalendars,
        );
      }

      var imported = 0;
      var skipped = 0;
      for (final event in events) {
        final eventModel = event.toEventModel(
          userId: resolvedUserId,
          importedAt: now,
        );
        final duplicate = await _eventRepository.findEventByTitleAndStart(
          title: eventModel.title,
          startAt: eventModel.startAt!,
          userId: resolvedUserId,
          excludedSources: const <String>{'device_calendar', 'naver_device'},
        );
        if (duplicate != null) {
          skipped += 1;
          debugPrint(
            'Device calendar import duplicate skipped by title/start: '
            'incoming="${eventModel.title}" ${eventModel.startAt} '
            'existing=${duplicate.id} source=${duplicate.source}',
          );
          continue;
        }
        await _eventRepository.upsertEventBySourceExternalId(
          eventModel,
        );
        imported += 1;
      }

      return DeviceCalendarImportResult(
        status: DeviceCalendarImportStatus.imported,
        message: skipped > 0
            ? '휴대폰 내부 캘린더 일정 $imported개를 가져오고, 중복 $skipped개는 건너뛰었습니다.'
            : '휴대폰 내부 캘린더 일정 $imported개를 PlanFlow로 가져왔습니다.',
        importedCount: imported,
        calendars: naverCalendars,
      );
    } catch (error, stackTrace) {
      debugPrint('Device calendar import failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return DeviceCalendarImportResult(
        status: DeviceCalendarImportStatus.failed,
        message: '휴대폰 내부 캘린더 일정 가져오기에 실패했습니다. 권한과 캘린더 동기화 상태를 확인해 주세요.',
        error: error,
      );
    }
  }

  Future<bool> exportEvent(EventModel event) async {
    if (event.source == 'google' ||
        event.source == 'naver' ||
        event.source == 'naver_caldav' ||
        event.source == 'naver_device' ||
        event.source == 'device_calendar') {
      return true;
    }
    try {
      return await _gateway.upsertDeviceCalendarEvent(event);
    } catch (error, stackTrace) {
      debugPrint('Device calendar export failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  void _throwIfNativeError(List<Map<Object?, Object?>> rows) {
    final errors = rows
        .map((row) => row['error'])
        .whereType<Object>()
        .map((value) => value.toString())
        .where((value) => value.trim().isNotEmpty)
        .toList(growable: false);
    if (errors.isNotEmpty) {
      throw StateError(errors.first);
    }
  }
}

String _stringValue(Object? value) => value?.toString() ?? '';

String? _nullableString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

String? _blankToNull(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}

bool? _boolValue(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  final text = value?.toString().toLowerCase();
  if (text == 'true') {
    return true;
  }
  if (text == 'false') {
    return false;
  }
  return null;
}

DateTime? _dateTimeFromMillis(Object? value) {
  if (value == null) {
    return null;
  }
  final millis = value is num ? value.toInt() : int.tryParse(value.toString());
  if (millis == null || millis <= 0) {
    return null;
  }
  return DateTime.fromMillisecondsSinceEpoch(millis).toUtc();
}
