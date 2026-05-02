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
  });

  final String title;
  final DateTime? startAt;
  final String? location;
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
    success = await _saveUpcomingEvents(upcomingEvents) && success;

    final refreshed = await _platform.updateWidget(
      name: widgetName,
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

  Future<bool> _saveUpcomingEvents(List<HomeWidgetListEventData> events) async {
    var success = true;
    final slots = events.take(3).toList(growable: false);

    for (var index = 0; index < 3; index += 1) {
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
