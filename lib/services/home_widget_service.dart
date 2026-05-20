import 'home_widget_platform.dart';
import 'travel_time_buffer_service.dart';

class HomeWidgetNextEventData {
  const HomeWidgetNextEventData({
    required this.title,
    this.eventId,
    this.startAt,
    this.location,
    this.travelBufferMinutes,
    this.isCritical = false,
  });

  final String title;
  final String? eventId;
  final DateTime? startAt;
  final String? location;
  final int? travelBufferMinutes;
  final bool isCritical;
}

class HomeWidgetListEventData {
  const HomeWidgetListEventData({
    required this.title,
    this.startAt,
    this.location,
    this.isCritical = false,
  });

  final String title;
  final DateTime? startAt;
  final String? location;
  final bool isCritical;
}

class HomeWidgetMonthDayData {
  const HomeWidgetMonthDayData({
    required this.day,
    required this.summary,
    this.eventCount,
    this.hasCritical = false,
  });

  final int day;
  final String summary;
  final int? eventCount;
  final bool hasCritical;
}

class HomeWidgetWeekDayData {
  const HomeWidgetWeekDayData({
    required this.date,
    this.summary,
    this.events = const <HomeWidgetListEventData>[],
    this.eventCount,
    this.hasCritical = false,
  });

  final DateTime date;
  final String? summary;
  final List<HomeWidgetListEventData> events;
  final int? eventCount;
  final bool hasCritical;
}

class HomeWidgetService {
  HomeWidgetService({
    HomeWidgetPlatform? platform,
    TravelTimeBufferService? travelTimeBufferService,
    this.iOSAppGroupId,
  })  : _platform = platform ?? createHomeWidgetPlatform(),
        _travelTimeBufferService =
            travelTimeBufferService ?? TravelTimeBufferService();

  static const String defaultWidgetName = 'PlanFlowHomeWidgetProvider';
  static const List<String> defaultAndroidWidgetNames = <String>[
    'PlanFlowHomeWidgetProvider',
    'PlanFlowMonthlyWidgetProvider',
    'PlanFlowVerticalScheduleWidgetProvider',
    'PlanFlowWeeklyWidgetProvider',
    'PlanFlowMicWidgetProvider',
  ];

  final HomeWidgetPlatform _platform;
  final TravelTimeBufferService _travelTimeBufferService;
  final String? iOSAppGroupId;

  bool get isSupported => _platform.isSupported;

  Future<bool> updateNextEvent({
    required String title,
    String? eventId,
    DateTime? startAt,
    String? location,
    String? travelOrigin,
    double? latitude,
    double? longitude,
    int? travelBufferMinutes,
    bool isCritical = false,
    List<HomeWidgetListEventData> upcomingEvents =
        const <HomeWidgetListEventData>[],
    String widgetName = defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    final resolvedBufferMinutes = travelBufferMinutes ??
        await _resolveTravelBufferMinutes(
          travelOrigin: travelOrigin,
          destination: location,
          latitude: latitude,
          longitude: longitude,
        );

    return updateNextEventData(
      HomeWidgetNextEventData(
        title: title,
        eventId: eventId,
        startAt: startAt,
        location: location,
        travelBufferMinutes: resolvedBufferMinutes,
        isCritical: isCritical,
      ),
      widgetName: widgetName,
      androidName: androidName,
      iOSName: iOSName,
      qualifiedAndroidName: qualifiedAndroidName,
      upcomingEvents: upcomingEvents,
    );
  }

  Future<bool> updateNextEventData(
    HomeWidgetNextEventData data, {
    String widgetName = defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
    List<HomeWidgetListEventData> upcomingEvents =
        const <HomeWidgetListEventData>[],
  }) async {
    if (!isSupported) {
      return false;
    }

    if (!await _ensureConfigured()) {
      return false;
    }

    var success = true;
    success =
        await _saveValue('next_event_title', data.title.trim()) && success;
    success =
        await _saveOptionalValue('next_event_id', data.eventId) && success;
    success = await _saveOptionalValue(
            'next_event_start_at', data.startAt?.toUtc().toIso8601String()) &&
        success;
    success = await _saveOptionalValue('next_event_location', data.location) &&
        success;
    success = await _saveOptionalValue(
          'next_event_travel_buffer_minutes',
          data.travelBufferMinutes,
        ) &&
        success;
    success =
        await _saveValue('next_event_is_critical', data.isCritical) && success;
    success = await _saveTodayEvents(upcomingEvents) && success;

    final refreshed = await _refreshWidgets(
      widgetName: widgetName,
      androidName: androidName,
      iOSName: iOSName,
      qualifiedAndroidName: qualifiedAndroidName,
    );

    return success && refreshed;
  }

  Future<bool> updateScheduleData({
    required HomeWidgetNextEventData nextEvent,
    List<HomeWidgetListEventData> todayEvents =
        const <HomeWidgetListEventData>[],
    DateTime? month,
    List<HomeWidgetMonthDayData> monthDays = const <HomeWidgetMonthDayData>[],
    List<HomeWidgetWeekDayData> weekDays = const <HomeWidgetWeekDayData>[],
    String widgetName = defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    if (!isSupported) {
      return false;
    }

    if (!await _ensureConfigured()) {
      return false;
    }

    var success = true;
    success =
        await _saveValue('next_event_title', nextEvent.title.trim()) && success;
    success =
        await _saveOptionalValue('next_event_id', nextEvent.eventId) && success;
    success = await _saveOptionalValue(
          'next_event_start_at',
          nextEvent.startAt?.toUtc().toIso8601String(),
        ) &&
        success;
    success =
        await _saveOptionalValue('next_event_location', nextEvent.location) &&
            success;
    success = await _saveOptionalValue(
          'next_event_travel_buffer_minutes',
          nextEvent.travelBufferMinutes,
        ) &&
        success;
    success = await _saveValue(
          'next_event_is_critical',
          nextEvent.isCritical,
        ) &&
        success;
    success = await _saveTodayEvents(todayEvents) && success;
    success = await _saveMonthData(month: month, days: monthDays) && success;
    success = await _saveWeekData(weekDays) && success;

    final refreshed = await _refreshWidgets(
      widgetName: widgetName,
      androidName: androidName,
      iOSName: iOSName,
      qualifiedAndroidName: qualifiedAndroidName,
    );

    return success && refreshed;
  }

  Future<int> _resolveTravelBufferMinutes({
    required String? travelOrigin,
    required String? destination,
    double? latitude,
    double? longitude,
  }) async {
    final normalizedOrigin = travelOrigin?.trim() ?? '';
    final normalizedDestination = destination?.trim() ?? '';
    if (normalizedOrigin.isNotEmpty && normalizedDestination.isNotEmpty) {
      return _travelTimeBufferService.estimateMinutesWithGoogleMaps(
        origin: normalizedOrigin,
        destination: normalizedDestination,
        latitude: latitude,
        longitude: longitude,
        locationText: destination,
      );
    }

    return _travelTimeBufferService.estimateMinutes(
      latitude: latitude,
      longitude: longitude,
      locationText: destination,
    );
  }

  Future<bool> _saveTodayEvents(List<HomeWidgetListEventData> events) async {
    var success = true;
    final slots = events.take(6).toList(growable: false);

    success = await _saveValue('today_event_count', slots.length) && success;

    for (var index = 0; index < 6; index += 1) {
      final event = index < slots.length ? slots[index] : null;
      final slot = index + 1;
      success = await _saveOptionalValue(
            'event_list_${slot}_title',
            event?.title,
          ) &&
          success;
      success = await _saveOptionalValue(
            'event_list_${slot}_time',
            event?.startAt?.toUtc().toIso8601String(),
          ) &&
          success;
      success = await _saveOptionalValue(
            'event_list_${slot}_location',
            event?.location,
          ) &&
          success;
      success = await _saveValue(
            'event_list_${slot}_is_critical',
            event?.isCritical ?? false,
          ) &&
          success;
    }

    return success;
  }

  Future<bool> _saveMonthData({
    required DateTime? month,
    required List<HomeWidgetMonthDayData> days,
  }) async {
    var success = true;
    final resolvedMonth = month ?? DateTime.now();
    success = await _saveValue(
          'month_title',
          '${resolvedMonth.year}년 ${resolvedMonth.month}월',
        ) &&
        success;

    final summaries = <int, String>{};
    for (final day in days) {
      if (day.day >= 1 && day.day <= 31) {
        summaries[day.day] = day.summary.trim();
      }
    }

    for (var day = 1; day <= 31; day += 1) {
      HomeWidgetMonthDayData? sourceDay;
      for (final candidate in days) {
        if (candidate.day == day) {
          sourceDay = candidate;
          break;
        }
      }
      success = await _saveOptionalValue(
            'month_day_${day}_summary',
            summaries[day],
          ) &&
          success;
      success = await _saveOptionalValue(
            'month_day_${day}_count',
            sourceDay?.eventCount,
          ) &&
          success;
      success = await _saveValue(
            'month_day_${day}_has_critical',
            sourceDay?.hasCritical ?? false,
          ) &&
          success;
    }

    return success;
  }

  Future<bool> _saveWeekData(List<HomeWidgetWeekDayData> days) async {
    var success = true;
    final slots = days.take(7).toList(growable: false);

    for (var index = 0; index < 7; index += 1) {
      final day = index < slots.length ? slots[index] : null;
      final slot = index + 1;
      success = await _saveOptionalValue(
            'week_day_${slot}_date',
            day?.date.toUtc().toIso8601String(),
          ) &&
          success;
      success = await _saveOptionalValue(
            'week_day_${slot}_summary',
            day?.summary,
          ) &&
          success;
      success = await _saveOptionalValue(
            'week_day_${slot}_count',
            day?.eventCount ?? day?.events.length,
          ) &&
          success;
      success = await _saveValue(
            'week_day_${slot}_has_critical',
            day?.hasCritical ?? day?.events.any((event) => event.isCritical) ?? false,
          ) &&
          success;

      final events = day?.events.take(2).toList(growable: false) ??
          const <HomeWidgetListEventData>[];
      for (var eventIndex = 0; eventIndex < 2; eventIndex += 1) {
        final event = eventIndex < events.length ? events[eventIndex] : null;
        final eventSlot = eventIndex + 1;
        success = await _saveOptionalValue(
              'week_day_${slot}_event_${eventSlot}_title',
              event?.title,
            ) &&
            success;
        success = await _saveOptionalValue(
              'week_day_${slot}_event_${eventSlot}_time',
              event?.startAt?.toUtc().toIso8601String(),
            ) &&
            success;
        success = await _saveValue(
              'week_day_${slot}_event_${eventSlot}_is_critical',
              event?.isCritical ?? false,
            ) &&
            success;
      }
    }

    return success;
  }

  Future<bool> _refreshWidgets({
    required String widgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    if (widgetName != defaultWidgetName ||
        androidName != null ||
        iOSName != null ||
        qualifiedAndroidName != null) {
      return _platform.updateWidget(
        name: widgetName,
        androidName: androidName,
        iOSName: iOSName,
        qualifiedAndroidName: qualifiedAndroidName,
      );
    }

    var success = true;
    for (final defaultName in defaultAndroidWidgetNames) {
      success = await _platform.updateWidget(name: defaultName) && success;
    }

    return success;
  }

  Future<bool> _ensureConfigured() async {
    if (iOSAppGroupId == null || iOSAppGroupId!.trim().isEmpty) {
      return true;
    }

    return _platform.setAppGroupId(iOSAppGroupId!.trim());
  }

  Future<bool> _saveValue(String key, Object? value) async {
    try {
      return await _platform.saveWidgetData(key, value);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _saveOptionalValue(String key, Object? value) async {
    if (value == null) {
      return _saveValue(key, null);
    }

    if (value is String && value.trim().isEmpty) {
      return _saveValue(key, '');
    }

    return _saveValue(key, value);
  }
}
