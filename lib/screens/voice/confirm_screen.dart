import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/gpt_service.dart';
import '../../services/home_widget_service.dart';
import '../../services/location_lookup_service.dart';
import '../../services/map_service.dart';
import '../../services/notification_service.dart';
import '../../services/travel_time_buffer_service.dart';

class ConfirmScreen extends StatefulWidget {
  ConfirmScreen({
    super.key,
    this.parsedSchedule = const <String, dynamic>{},
    this.userId,
    this.eventRepository,
    GptService? gptService,
    ConfirmScreenBackend? backend,
    NotificationService? notificationService,
    HomeWidgetService? homeWidgetService,
    LocationLookupService? locationLookupService,
  })  : backend = backend ?? const SupabaseConfirmScreenBackend(),
        gptService = gptService ?? GptService(),
        notificationService = notificationService ?? NotificationService(),
        homeWidgetService = homeWidgetService ?? HomeWidgetService(),
        locationLookupService =
            locationLookupService ?? LocationLookupService();

  final Map<String, dynamic> parsedSchedule;
  final String? userId;
  final EventRepository? eventRepository;
  final GptService gptService;
  final ConfirmScreenBackend backend;
  final NotificationService notificationService;
  final HomeWidgetService homeWidgetService;
  final LocationLookupService locationLookupService;

  @override
  State<ConfirmScreen> createState() => _ConfirmScreenState();
}

abstract class ConfirmScreenBackend {
  const ConfirmScreenBackend();

  Future<List<String>> fetchPastSupplies({
    required String userId,
    required String location,
  });

  Future<void> insertPreActions(List<Map<String, dynamic>> payloads);

  Future<void> insertReminders(List<Map<String, dynamic>> payloads);

  Future<void> insertLocationHistory(Map<String, dynamic> payload);

  Future<void> insertVoiceLog(Map<String, dynamic> payload);
}

class SupabaseConfirmScreenBackend extends ConfirmScreenBackend {
  const SupabaseConfirmScreenBackend();

  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<List<String>> fetchPastSupplies({
    required String userId,
    required String location,
  }) async {
    final response = await _client
        .from('location_history')
        .select('supplies, visited_at')
        .eq('user_id', userId)
        .eq('location', location)
        .order('visited_at', ascending: false)
        .limit(10);

    final supplies = <String>[];
    final seen = <String>{};

    for (final row in response as List<dynamic>) {
      final rowMap = Map<String, dynamic>.from(row as Map);
      final rowSupplies = rowMap['supplies'];
      if (rowSupplies is! List) {
        continue;
      }

      for (final item in rowSupplies) {
        final supply = item.toString().trim();
        if (supply.isEmpty || seen.contains(supply)) {
          continue;
        }
        seen.add(supply);
        supplies.add(supply);
      }
    }

    return supplies;
  }

  @override
  Future<void> insertPreActions(List<Map<String, dynamic>> payloads) async {
    if (payloads.isEmpty) {
      return;
    }
    await _client.from('pre_actions').insert(payloads);
  }

  @override
  Future<void> insertReminders(List<Map<String, dynamic>> payloads) async {
    if (payloads.isEmpty) {
      return;
    }
    await _client.from('reminders').insert(payloads);
  }

  @override
  Future<void> insertLocationHistory(Map<String, dynamic> payload) async {
    await _client.from('location_history').insert(payload);
  }

  @override
  Future<void> insertVoiceLog(Map<String, dynamic> payload) async {
    await _client.from('voice_logs').insert(payload);
  }
}

class _ConfirmScreenState extends State<ConfirmScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _locationController;
  late final TextEditingController _memoController;
  late final TextEditingController _newSupplyController;
  final ScrollController _scrollController = ScrollController(
    keepScrollOffset: false,
  );
  final FocusNode _newSupplyFocusNode = FocusNode();
  final GlobalKey _suppliesKey = GlobalKey();
  final GlobalKey _preActionsKey = GlobalKey();
  late final List<_SupplyDraft> _supplies;
  late final List<_PreActionDraft> _preActions;
  late DateTime _startAt;
  DateTime? _endAt;
  double? _locationLat;
  double? _locationLng;
  late bool _isCritical;
  bool _isSaving = false;
  bool _isLoadingPastSupplies = false;
  bool _isLookingUpLocation = false;
  bool _isHydratingParsedSchedule = false;
  List<String> _pastSupplies = const <String>[];
  Timer? _locationDebounce;
  bool _hasFollowUpFailures = false;
  String? _supplyErrorText;
  String? _hydrateMessage;

  bool get _parseFailed => widget.parsedSchedule['parse_failed'] == true;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: _stringValue(widget.parsedSchedule['title']) ?? '',
    );
    _locationController = TextEditingController(
      text: _stringValue(widget.parsedSchedule['location']) ?? '',
    );
    _memoController = TextEditingController(
      text: _stringValue(widget.parsedSchedule['memo']) ??
          _stringValue(widget.parsedSchedule['raw_text']),
    );
    _newSupplyController = TextEditingController();
    _supplies = _stringListValue(widget.parsedSchedule['supplies'])
        .map(_SupplyDraft.new)
        .toList(growable: true);
    _preActions = _initialPreActions();
    _startAt = _safeStartAt(widget.parsedSchedule['start_at']);
    _endAt = _safeEndAt(widget.parsedSchedule['end_at'], _startAt);
    _locationLat = _doubleValue(widget.parsedSchedule['location_lat']);
    _locationLng = _doubleValue(widget.parsedSchedule['location_lng']);
    _isCritical = widget.parsedSchedule['is_critical'] == true;
    _locationController.addListener(_schedulePastSupplyLookup);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPastSupplies();
      _maybeHydrateParsedSchedule();
    });
  }

  @override
  void dispose() {
    _locationDebounce?.cancel();
    _locationController.removeListener(_schedulePastSupplyLookup);
    _titleController.dispose();
    _locationController.dispose();
    _memoController.dispose();
    _newSupplyController.dispose();
    _scrollController.dispose();
    _newSupplyFocusNode.dispose();
    for (final draft in _supplies) {
      draft.dispose();
    }
    for (final draft in _preActions) {
      draft.dispose();
    }
    super.dispose();
  }

  void _schedulePastSupplyLookup() {
    _locationDebounce?.cancel();
    _locationDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        _loadPastSupplies();
      }
    });
  }

  Future<void> _loadPastSupplies() async {
    final location = _locationController.text.trim();
    final userId = _resolveUserId();
    if (location.isEmpty || userId == null) {
      if (mounted) {
        setState(() {
          _pastSupplies = const <String>[];
          _isLoadingPastSupplies = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isLoadingPastSupplies = true;
      });
    }

    try {
      final pastSupplies = await widget.backend.fetchPastSupplies(
        userId: userId,
        location: location,
      );
      if (!mounted || location != _locationController.text.trim()) {
        return;
      }
      setState(() {
        _pastSupplies = pastSupplies;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _pastSupplies = const <String>[];
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingPastSupplies = false;
        });
      }
    }
  }

  Future<void> _lookupLocation() async {
    final query = _locationController.text.trim();
    if (query.isEmpty) {
      _showMessage('장소를 먼저 입력해 주세요.');
      return;
    }

    if (_isLookingUpLocation) {
      return;
    }

    setState(() {
      _isLookingUpLocation = true;
    });

    try {
      final results = await widget.locationLookupService.search(query);
      if (!mounted) {
        return;
      }

      if (results.isEmpty) {
        await _showExternalMapOptions(
          query,
          message: '앱 안에서 장소를 찾지 못했어요. 외부 지도에서 직접 확인해 보세요.',
        );
        return;
      }

      final selected = await showModalBottomSheet<LocationLookupResult>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => _LocationLookupSheet(
          initialQuery: query,
          results: results,
        ),
      );

      if (!mounted || selected == null) {
        return;
      }

      setState(() {
        _locationController.text = selected.label;
        _locationLat = selected.latitude;
        _locationLng = selected.longitude;
      });
      _showMessage('정확한 위치를 선택했어요.');
    } catch (_) {
      if (mounted) {
        await _showExternalMapOptions(
          query,
          message: '위치 검색에 실패했어요. 외부 지도에서 직접 확인해 보세요.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLookingUpLocation = false;
        });
      }
    }
  }

  Future<void> _showExternalMapOptions(
    String query, {
    String? message,
  }) async {
    if (!mounted) {
      return;
    }

    final selected = await showModalBottomSheet<_MapSearchTarget>(
      context: context,
      showDragHandle: true,
      builder: (context) => _ExternalMapSearchSheet(
        query: query,
        message: message,
      ),
    );
    if (!mounted || selected == null) {
      return;
    }

    await _launchMapSearch(query, selected);
  }

  Future<void> _launchMapSearch(
    String query,
    _MapSearchTarget target,
  ) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      _showMessage('장소를 먼저 입력해 주세요.');
      return;
    }

    final uri = target == _MapSearchTarget.google
        ? Uri.https(
            'www.google.com',
            '/maps/search/',
            <String, String>{'api': '1', 'query': trimmed},
          )
        : Uri.parse(
            'https://map.naver.com/p/search/${Uri.encodeComponent(trimmed)}',
          );

    final launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!launched && mounted) {
      _showMessage('지도를 열지 못했어요. 장소명을 수정해서 다시 시도해 주세요.');
    }
  }

  void _maybeHydrateParsedSchedule() {
    final rawText = _stringValue(widget.parsedSchedule['raw_text']);
    final shouldHydrate = widget.parsedSchedule['parse_pending'] == true ||
        widget.parsedSchedule['parse_failed'] == true ||
        (_titleController.text.trim().isEmpty &&
            rawText != null &&
            rawText.isNotEmpty);
    if (!shouldHydrate || rawText == null || rawText.isEmpty) {
      return;
    }
    _hydrateParsedSchedule(rawText);
  }

  Future<void> _hydrateParsedSchedule(String rawText) async {
    if (_isHydratingParsedSchedule) {
      return;
    }

    setState(() {
      _isHydratingParsedSchedule = true;
      _hydrateMessage = null;
    });

    try {
      final parsed = await widget.gptService.parseSchedule(rawText);
      if (!mounted) {
        return;
      }

      setState(() {
        final title = _stringValue(parsed['title']);
        if (title != null && title.isNotEmpty) {
          _titleController.text = title;
        }

        final location = _stringValue(parsed['location']);
        if (location != null && location.isNotEmpty) {
          _locationController.text = location;
        }
        _locationLat = _doubleValue(parsed['location_lat']) ?? _locationLat;
        _locationLng = _doubleValue(parsed['location_lng']) ?? _locationLng;

        final memo = _stringValue(parsed['memo']);
        if (memo != null && memo.isNotEmpty) {
          _memoController.text = memo;
        } else if (_memoController.text.trim().isEmpty) {
          _memoController.text = rawText;
        }

        final supplies = _stringListValue(parsed['supplies']);
        if (supplies.isNotEmpty && _supplies.isEmpty) {
          _supplies.addAll(supplies.map(_SupplyDraft.new));
        }

        final parsedPreActions = _preActionsFromValue(parsed['pre_actions']);
        if (parsedPreActions.isNotEmpty && _preActions.isEmpty) {
          _preActions.addAll(parsedPreActions);
        }

        _startAt = _safeStartAt(parsed['start_at'] ?? _startAt);
        _endAt = _safeEndAt(parsed['end_at'], _startAt);
        if (parsed['is_critical'] == true) {
          _isCritical = true;
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _hydrateMessage = '일정을 바로 정리하지 못했어요. 필요한 내용만 직접 수정해 주세요.';
        });
      }
      debugPrint('ConfirmScreen hydration failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isHydratingParsedSchedule = false;
        });
      }
    }
  }

  String? _resolveUserId() {
    final userId =
        widget.userId ?? Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.trim().isEmpty) {
      return null;
    }
    return userId.trim();
  }

  EventRepository? _resolveEventRepository() {
    if (widget.eventRepository != null) {
      return widget.eventRepository;
    }
    if (!AppEnv.isSupabaseReady) {
      return null;
    }
    return EventRepository.supabase();
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      _showMessage('제목을 입력해 주세요.');
      return;
    }

    final userId = _resolveUserId();
    if (userId == null) {
      _showMessage('로그인이 필요합니다.');
      return;
    }

    final repository = _resolveEventRepository();
    if (repository == null) {
      _showMessage('Supabase 환경이 설정되지 않아 저장할 수 없어요.');
      if (mounted) {
        context.go(AppRoutes.home);
      }
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final savedEvent = await repository.createEvent(
        EventModel(
          id: '',
          userId: userId,
          title: title,
          startAt: _startAt,
          endAt: _endAt,
          location: _emptyToNull(_locationController.text),
          locationLat: _locationLat,
          locationLng: _locationLng,
          memo: _emptyToNull(_memoController.text),
          supplies: List<String>.unmodifiable(
            _supplies
                .map((draft) => draft.titleController.text.trim())
                .where((item) => item.isNotEmpty),
          ),
          isCritical: _isCritical,
        ),
      );

      await _saveRelatedRecords(
        userId: userId,
        event: savedEvent,
      );
      await _updateHomeWidget(repository, savedEvent);

      if (mounted) {
        _showMessage(
          _hasFollowUpFailures
              ? '일정은 저장됐지만 알림/준비 기록 중 일부를 저장하지 못했어요. 설정과 권한을 확인해 주세요.'
              : '일정을 저장했어요.',
        );
        EventRefreshBus.instance.notifyChanged(
          reason: 'confirm_saved',
          eventId: savedEvent.id,
          startAt: savedEvent.startAt,
        );
        context.go(AppRoutes.home);
      }
    } catch (_) {
      if (mounted) {
        _showMessage('저장하지 못했어요. 로그인과 Supabase 설정을 확인해 주세요.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _saveRelatedRecords({
    required String userId,
    required EventModel event,
  }) async {
    _hasFollowUpFailures = false;
    final eventStartAt = event.startAt ?? _startAt;
    final preActionPayloads = _buildPreActionPayloads(
      userId: userId,
      eventId: event.id,
      eventStartAt: eventStartAt,
    );
    final reminderPayloads = _buildReminderPayloads(
      userId: userId,
      eventId: event.id,
      eventStartAt: eventStartAt,
    );

    await _tryFollowUp(
      () => widget.backend.insertPreActions(preActionPayloads),
      label: 'pre_actions',
    );
    await _tryFollowUp(
      () => widget.backend.insertReminders(reminderPayloads),
      label: 'reminders',
    );

    final location = _emptyToNull(_locationController.text);
    if (location != null) {
      await _tryFollowUp(
        () => widget.backend.insertLocationHistory(<String, dynamic>{
          'user_id': userId,
          'event_id': event.id,
          'location': location,
          'supplies': event.supplies,
        }),
        label: 'location_history',
      );
    }

    final rawText = _stringValue(widget.parsedSchedule['raw_text']);
    if (rawText != null) {
      await _tryFollowUp(
        () => widget.backend.insertVoiceLog(<String, dynamic>{
          'user_id': userId,
          'event_id': event.id,
          'raw_text': rawText,
          'parsed_json': widget.parsedSchedule,
        }),
        label: 'voice_logs',
      );
    }

    final eventReminderNotifyAt =
        eventStartAt.subtract(await _resolveReminderBuffer(event));
    final criticalAlarmNotifyAt =
        eventStartAt.subtract(const Duration(minutes: 60));
    await _tryFollowUp(
      () => widget.notificationService.scheduleEventReminder(
        id: widget.notificationService.notificationIdFor('${event.id}:push'),
        title: event.title,
        body: '이벤트 시작: ${event.title}',
        notifyAt: eventReminderNotifyAt,
      ),
      label: 'local_event_reminder',
    );

    if (_isCritical) {
      await _tryFollowUp(
        () => widget.notificationService.scheduleCriticalAlarm(
          id: widget.notificationService
              .notificationIdFor('${event.id}:critical'),
          title: event.title,
          notifyAt: criticalAlarmNotifyAt,
          body: '중요 일정이 곧 시작됩니다.',
        ),
        label: 'critical_alarm',
      );
    }
  }

  Future<Duration> _resolveReminderBuffer(EventModel event) async {
    final destination = event.location?.trim() ?? '';
    if (destination.isEmpty) {
      return const Duration(minutes: 60);
    }

    final travelOrigin = _resolveTravelOrigin();
    final service = TravelTimeBufferService();
    final originLat = _doubleValue(widget.parsedSchedule['travel_origin_lat']);
    final originLng = _doubleValue(widget.parsedSchedule['travel_origin_lng']);
    final canUseMapApis = originLat != null &&
        originLng != null &&
        event.locationLat != null &&
        event.locationLng != null;
    if (canUseMapApis) {
      final mapEstimate = await service.estimateWithMapApis(
        originLat: originLat,
        originLng: originLng,
        destinationLat: event.locationLat!,
        destinationLng: event.locationLng!,
        mode: await _resolveTravelMode(event.userId),
        locationText: destination,
      );
      if (mapEstimate.source == TravelTimeBufferSource.tmap ||
          mapEstimate.source == TravelTimeBufferSource.naverMap) {
        return Duration(minutes: mapEstimate.minutes + 10);
      }
    }

    final travelMinutes = travelOrigin == null
        ? service.estimateMinutes(locationText: destination)
        : await service.estimateMinutesWithGoogleMaps(
            origin: travelOrigin,
            destination: destination,
            locationText: destination,
          );
    return Duration(minutes: travelMinutes + 10);
  }

  Future<MapTravelMode> _resolveTravelMode(String userId) async {
    final parsedTravelMode = _stringValue(widget.parsedSchedule['travel_mode']);
    if (parsedTravelMode == 'transit') {
      return MapTravelMode.transit;
    }

    if (!AppEnv.isSupabaseReady) {
      return MapTravelMode.car;
    }

    try {
      final response = await Supabase.instance.client
          .from('user_settings')
          .select('travel_mode')
          .eq('user_id', userId)
          .maybeSingle();
      final travelMode = _stringValue(response?['travel_mode']);
      return travelMode == 'transit'
          ? MapTravelMode.transit
          : MapTravelMode.car;
    } catch (_) {
      return MapTravelMode.car;
    }
  }

  Future<void> _tryFollowUp(
    Future<void> Function() action, {
    required String label,
  }) async {
    try {
      await action();
    } catch (error, stackTrace) {
      _hasFollowUpFailures = true;
      debugPrint('ConfirmScreen follow-up save failed ($label): $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  List<Map<String, dynamic>> _buildPreActionPayloads({
    required String userId,
    required String eventId,
    required DateTime eventStartAt,
  }) {
    return _preActions
        .map((draft) {
          final title = draft.titleController.text.trim();
          if (title.isEmpty) {
            return null;
          }

          final offsetHours =
              int.tryParse(draft.offsetController.text.trim()) ?? 1;
          final notifyAt = eventStartAt.subtract(
            Duration(hours: offsetHours < 0 ? 0 : offsetHours),
          );

          return <String, dynamic>{
            'event_id': eventId,
            'user_id': userId,
            'title': title,
            'notify_at': notifyAt.toIso8601String(),
            'is_done': false,
          };
        })
        .whereType<Map<String, dynamic>>()
        .toList(growable: true);
  }

  List<Map<String, dynamic>> _buildReminderPayloads({
    required String userId,
    required String eventId,
    required DateTime eventStartAt,
  }) {
    final now = DateTime.now();
    final pushNotifyAt = eventStartAt.subtract(const Duration(minutes: 60));
    final payloads = <Map<String, dynamic>>[
      if (pushNotifyAt.isAfter(now))
        _reminderPayload(
          userId: userId,
          eventId: eventId,
          type: 'push',
          notifyAt: pushNotifyAt,
        ),
    ];

    final criticalNotifyAt = eventStartAt.subtract(const Duration(minutes: 30));
    if (_isCritical && criticalNotifyAt.isAfter(now)) {
      payloads.add(
        _reminderPayload(
          userId: userId,
          eventId: eventId,
          type: 'system_alarm',
          notifyAt: criticalNotifyAt,
        ),
      );
    }

    return payloads;
  }

  Future<void> _updateHomeWidget(
    EventRepository repository,
    EventModel fallbackEvent,
  ) async {
    try {
      final nextEvent = await _resolveNextEvent(repository) ?? fallbackEvent;
      final upcomingEvents = await _resolveUpcomingEvents(repository);
      await widget.homeWidgetService.updateNextEvent(
        title: nextEvent.title,
        eventId: nextEvent.id,
        startAt: nextEvent.startAt,
        location: nextEvent.location,
        travelOrigin: _resolveTravelOrigin(),
        isCritical: nextEvent.isCritical,
        upcomingEvents: upcomingEvents
            .map(
              (event) => HomeWidgetListEventData(
                title: event.title,
                startAt: event.startAt,
                location: event.location,
              ),
            )
            .toList(growable: false),
      );
    } catch (_) {}
  }

  Future<EventModel?> _resolveNextEvent(EventRepository repository) async {
    final userId = _resolveUserId();
    if (userId == null) {
      return null;
    }

    final now = DateTime.now();
    final events = await repository.listEvents(userId: userId);
    final remainingToday = events.where((event) {
      final startAt = event.startAt;
      if (startAt == null) {
        return false;
      }
      return startAt.year == now.year &&
          startAt.month == now.month &&
          startAt.day == now.day &&
          !startAt.isBefore(now);
    }).toList(growable: false)
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));

    if (remainingToday.isEmpty) {
      return null;
    }
    return remainingToday.first;
  }

  Future<List<EventModel>> _resolveUpcomingEvents(
    EventRepository repository,
  ) async {
    final userId = _resolveUserId();
    if (userId == null) {
      return const <EventModel>[];
    }

    final now = DateTime.now();
    final events = await repository.listEvents(userId: userId);
    return events.where((event) {
      final startAt = event.startAt;
      return startAt != null && !startAt.isBefore(now);
    }).toList(growable: false)
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
  }

  String? _resolveTravelOrigin() {
    const keys = <String>[
      'travel_origin',
      'origin_location',
      'origin',
      'departure_location',
    ];
    for (final key in keys) {
      final value = _stringValue(widget.parsedSchedule[key]);
      if (value != null) {
        return value;
      }
    }
    return null;
  }

  Future<void> _addSupplyFromInput() async {
    final supply = _newSupplyController.text.trim();
    if (supply.isEmpty) {
      setState(() {
        _supplyErrorText = '추가할 준비물을 먼저 입력해 주세요.';
      });
      _newSupplyFocusNode.requestFocus();
      return;
    }

    late final bool wasAdded;
    setState(() {
      wasAdded = _addSupply(supply);
      _newSupplyController.clear();
      _supplyErrorText = wasAdded ? null : '이미 추가된 준비물이에요.';
    });
    _showMessage(wasAdded ? '$supply 준비물을 추가했어요.' : '이미 추가된 준비물이에요.');
    if (wasAdded) {
      _scrollToKey(_suppliesKey);
    } else {
      _newSupplyFocusNode.requestFocus();
    }
  }

  bool _addSupply(String supply) {
    if (_supplies.any((draft) => draft.titleController.text.trim() == supply)) {
      return false;
    }
    _supplies.add(_SupplyDraft(supply));
    return true;
  }

  void _removeSupply(_SupplyDraft draft) {
    setState(() {
      _supplies.remove(draft);
      draft.dispose();
    });
  }

  void _addPreAction() {
    final draft = _PreActionDraft.manual();
    setState(() {
      _preActions.add(draft);
    });
    _showMessage('선행행동을 추가했어요. 내용을 바로 입력해 주세요.');
    _focusNewPreAction(draft);
  }

  void _removePreAction(_PreActionDraft draft) {
    setState(() {
      _preActions.remove(draft);
      draft.dispose();
    });
  }

  void _applyPastSupply(String supply) {
    late final bool wasAdded;
    setState(() {
      wasAdded = _addSupply(supply);
    });
    _showMessage(wasAdded ? '$supply 준비물을 추가했어요.' : '이미 추가된 준비물이에요.');
    _scrollToKey(_suppliesKey);
  }

  List<_PreActionDraft> _initialPreActions() {
    return _preActionsFromValue(widget.parsedSchedule['pre_actions']);
  }

  List<_PreActionDraft> _preActionsFromValue(Object? rawPreActions) {
    if (rawPreActions is! List) {
      return <_PreActionDraft>[];
    }

    return rawPreActions
        .whereType<Map>()
        .map(
          (item) => _PreActionDraft.auto(
            title: _stringValue(item['title']),
            offsetHours: _intValue(item['offset_hours']) ?? 1,
          ),
        )
        .toList(growable: true);
  }

  Map<String, dynamic> _reminderPayload({
    required String userId,
    required String eventId,
    required String type,
    required DateTime notifyAt,
  }) {
    return <String, dynamic>{
      'event_id': eventId,
      'user_id': userId,
      'type': type,
      'notify_at': notifyAt.toIso8601String(),
      'is_sent': false,
    };
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _scrollToKey(GlobalKey key, {FocusNode? focusNode}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final targetContext = key.currentContext;
      if (!mounted || targetContext == null) {
        return;
      }
      Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0.1,
      );
      focusNode?.requestFocus();
    });
  }

  void _focusNewPreAction(_PreActionDraft draft) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final targetContext = draft.key.currentContext;
      if (targetContext != null) {
        Scrollable.ensureVisible(
          targetContext,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          alignment: 0.2,
        );
      }
      draft.titleFocusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final location = _locationController.text.trim();

    return Scaffold(
      appBar: AppBar(title: const Text('일정 확인')),
      bottomNavigationBar: _ConfirmBottomNavigation(
        onHome: () => context.go(AppRoutes.home),
        onCalendar: () => context.go(AppRoutes.calendar),
        onSettings: () => context.go(AppRoutes.settings),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.all(AppConstants.defaultPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: PlanFlowColors.briefing,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        'GPT가 정리한 내용을 확인하고 바로 저장할 수 있어요. 필요한 항목은 지금 수정해도 됩니다.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                    ),
                    if (_isHydratingParsedSchedule ||
                        _hydrateMessage != null) ...[
                      const SizedBox(height: AppConstants.sectionSpacing),
                      Card(
                        color: const Color(0xFFF7F9FF),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: const BorderSide(
                            color: PlanFlowColors.primaryFaint,
                            width: 0.5,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              if (_isHydratingParsedSchedule)
                                const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else
                                const Icon(
                                  Icons.info_outline,
                                  color: PlanFlowColors.primaryMid,
                                ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _hydrateMessage ??
                                      '음성 내용을 정리하는 중이에요. 화면은 바로 열렸고, 아래 항목은 곧 채워집니다.',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: PlanFlowColors.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: AppConstants.sectionSpacing),
                    if (_parseFailed)
                      Card(
                        color: theme.colorScheme.errorContainer,
                        child: const Padding(
                          padding: EdgeInsets.all(AppConstants.defaultPadding),
                          child: Text(
                            '자동 파싱에 실패했어요. 내용을 확인하고 직접 입력해 주세요.',
                          ),
                        ),
                      ),
                    const SizedBox(height: AppConstants.sectionSpacing),
                    TextField(
                      controller: _titleController,
                      decoration: const InputDecoration(
                        labelText: '제목',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: AppConstants.sectionSpacing),
                    TextField(
                      controller: _locationController,
                      decoration: InputDecoration(
                        labelText: '장소',
                        helperText: '같은 장소의 과거 준비물을 아래에서 다시 쓸 수 있어요.',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: '장소 찾기',
                          onPressed:
                              _isLookingUpLocation ? null : _lookupLocation,
                          icon: _isLookingUpLocation
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.map_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppConstants.sectionSpacing),
                    if (_isLoadingPastSupplies)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: LinearProgressIndicator(),
                      )
                    else if (_pastSupplies.isNotEmpty &&
                        location.isNotEmpty) ...[
                      _SuggestionsCard(
                        title: '같은 장소의 준비물',
                        subtitle: '이전 일정에서 자주 쓰던 준비물을 눌러 바로 추가할 수 있어요.',
                        chips: _pastSupplies
                            .map(
                              (supply) => ActionChip(
                                label: Text(supply),
                                onPressed: () => _applyPastSupply(supply),
                              ),
                            )
                            .toList(growable: false),
                      ),
                      const SizedBox(height: AppConstants.sectionSpacing),
                    ],
                    KeyedSubtree(
                      key: _suppliesKey,
                      child: _SuppliesEditor(
                        supplies: _supplies,
                        newSupplyController: _newSupplyController,
                        newSupplyFocusNode: _newSupplyFocusNode,
                        errorText: _supplyErrorText,
                        onAdd: _addSupplyFromInput,
                        onRemove: _removeSupply,
                      ),
                    ),
                    const SizedBox(height: AppConstants.sectionSpacing),
                    KeyedSubtree(
                      key: _preActionsKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _SectionHeader(
                            title: '선행행동',
                            actionLabel: '추가',
                            onAction: _addPreAction,
                          ),
                          const SizedBox(height: 8),
                          if (_preActions.isEmpty)
                            _EmptyInlineHint(
                              message:
                                  '선행행동이 없어요. 추가 버튼을 누르면 바로 아래에 입력 카드가 생겨요.',
                              actionLabel: '선행행동 추가',
                              onAction: _addPreAction,
                            )
                          else
                            ..._preActions.asMap().entries.map(
                                  (entry) => Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: KeyedSubtree(
                                      key: entry.value.key,
                                      child: _PreActionEditorCard(
                                        draft: entry.value,
                                        index: entry.key + 1,
                                        onDelete: () =>
                                            _removePreAction(entry.value),
                                      ),
                                    ),
                                  ),
                                ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppConstants.sectionSpacing),
                    _DateTimeTile(
                      label: '시작 시간',
                      value: _startAt,
                      onTap: () async {
                        final picked = await _pickDateTime(_startAt);
                        if (picked != null) {
                          setState(() {
                            _startAt = picked;
                            if (_endAt != null && _endAt!.isBefore(_startAt)) {
                              _endAt = null;
                            }
                          });
                        }
                      },
                    ),
                    const SizedBox(height: AppConstants.sectionSpacing),
                    _DateTimeTile(
                      label: '종료 시간',
                      value: _endAt,
                      emptyLabel: '종료 시간 없음',
                      onTap: () async {
                        final picked = await _pickDateTime(_endAt ?? _startAt);
                        if (picked != null) {
                          setState(() {
                            _endAt = picked;
                          });
                        }
                      },
                      trailing: _endAt == null
                          ? null
                          : IconButton(
                              tooltip: '종료 시간 지우기',
                              onPressed: () {
                                setState(() {
                                  _endAt = null;
                                });
                              },
                              icon: const Icon(Icons.clear),
                            ),
                    ),
                    const SizedBox(height: AppConstants.sectionSpacing),
                    TextField(
                      controller: _memoController,
                      decoration: const InputDecoration(
                        labelText: '메모',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 3,
                    ),
                    const SizedBox(height: AppConstants.sectionSpacing),
                    SwitchListTile(
                      value: _isCritical,
                      onChanged: (value) {
                        setState(() {
                          _isCritical = value;
                        });
                      },
                      title: const Text('중요 알림'),
                      subtitle: const Text('중요 일정이면 더 강한 알림에 함께 등록돼요.'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _isSaving ? null : _save,
                      icon: _isSaving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save),
                      label: Text(_isSaving ? '저장 중' : '일정 저장'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _stringValue(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return text;
  }

  String? _emptyToNull(String value) {
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  List<String> _stringListValue(Object? value) {
    if (value is List) {
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: true);
    }
    return const <String>[];
  }

  DateTime? _dateTimeValue(Object? value) {
    final text = _stringValue(value);
    if (text == null) {
      return null;
    }
    return DateTime.tryParse(text);
  }

  DateTime _safeStartAt(Object? value) {
    final now = DateTime.now();
    final parsed = _dateTimeValue(value);
    if (parsed == null) {
      return now;
    }
    if (parsed.isBefore(now.subtract(const Duration(days: 1)))) {
      return now;
    }
    return parsed;
  }

  DateTime? _safeEndAt(Object? value, DateTime startAt) {
    final parsed = _dateTimeValue(value);
    if (parsed == null || parsed.isBefore(startAt)) {
      return null;
    }
    return parsed;
  }

  int? _intValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value.toString());
  }

  double? _doubleValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value.toString());
  }

  Future<DateTime?> _pickDateTime(DateTime initialValue) async {
    return showDialog<DateTime>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _DateTimePickerDialog(initialValue: initialValue),
    );
  }
}

class _ConfirmBottomNavigation extends StatelessWidget {
  const _ConfirmBottomNavigation({
    required this.onHome,
    required this.onCalendar,
    required this.onSettings,
  });

  final VoidCallback onHome;
  final VoidCallback onCalendar;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: 1,
      onDestinationSelected: (index) {
        switch (index) {
          case 0:
            onHome();
            break;
          case 1:
            onCalendar();
            break;
          case 2:
            onSettings();
            break;
        }
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: '홈',
        ),
        NavigationDestination(
          icon: Icon(Icons.event_note_outlined),
          selectedIcon: Icon(Icons.event_note),
          label: '일정',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: '설정',
        ),
      ],
    );
  }
}

class _PreActionDraft {
  _PreActionDraft.auto({
    String? title,
    int? offsetHours,
  })  : isAuto = true,
        key = GlobalKey(),
        titleController = TextEditingController(text: title ?? ''),
        offsetController = TextEditingController(
          text: (offsetHours ?? 1).toString(),
        ),
        titleFocusNode = FocusNode();

  _PreActionDraft.manual()
      : isAuto = false,
        key = GlobalKey(),
        titleController = TextEditingController(),
        offsetController = TextEditingController(text: '1'),
        titleFocusNode = FocusNode();

  final bool isAuto;
  final GlobalKey key;
  final TextEditingController titleController;
  final TextEditingController offsetController;
  final FocusNode titleFocusNode;

  void dispose() {
    titleController.dispose();
    offsetController.dispose();
    titleFocusNode.dispose();
  }
}

class _SupplyDraft {
  _SupplyDraft(String title)
      : key = GlobalKey(),
        titleController = TextEditingController(text: title),
        focusNode = FocusNode();

  final GlobalKey key;
  final TextEditingController titleController;
  final FocusNode focusNode;

  void dispose() {
    titleController.dispose();
    focusNode.dispose();
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.actionLabel,
    required this.onAction,
  });

  final String title;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              color: PlanFlowColors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        TextButton.icon(
          onPressed: onAction,
          icon: const Icon(Icons.add, size: 18),
          label: Text(actionLabel),
        ),
      ],
    );
  }
}

class _SuppliesEditor extends StatelessWidget {
  const _SuppliesEditor({
    required this.supplies,
    required this.newSupplyController,
    required this.newSupplyFocusNode,
    required this.errorText,
    required this.onAdd,
    required this.onRemove,
  });

  final List<_SupplyDraft> supplies;
  final TextEditingController newSupplyController;
  final FocusNode newSupplyFocusNode;
  final String? errorText;
  final VoidCallback onAdd;
  final ValueChanged<_SupplyDraft> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(
          color: PlanFlowColors.primaryFaint,
          width: 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '준비물',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '일정에 필요한 준비물을 한 줄씩 정리해 주세요. 실제 체크는 일정 상세에서 할 수 있어요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            if (supplies.isEmpty)
              Text(
                '아직 준비물이 없어요. 아래에서 하나씩 추가해 보세요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
              )
            else ...[
              Column(
                children: supplies
                    .map(
                      (draft) => _SupplyInputRow(
                        draft: draft,
                        onDelete: () => onRemove(draft),
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: newSupplyController,
                    focusNode: newSupplyFocusNode,
                    decoration: InputDecoration(
                      labelText: '준비물 추가',
                      hintText: '예: 물, 여권, 충전기',
                      helperText: '입력 후 추가 버튼을 누르세요.',
                      border: const OutlineInputBorder(),
                      errorText: errorText,
                    ),
                    onSubmitted: (_) => onAdd(),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    onPressed: onAdd,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(72, 56),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    child: const Text('추가'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SupplyInputRow extends StatelessWidget {
  const _SupplyInputRow({
    required this.draft,
    required this.onDelete,
  });

  final _SupplyDraft draft;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: PlanFlowColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: PlanFlowColors.primaryFaint,
            width: 0.6,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(
              Icons.backpack_outlined,
              size: 18,
              color: PlanFlowColors.primaryMid,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: draft.titleController,
                focusNode: draft.focusNode,
                style: theme.textTheme.bodyMedium,
                decoration: const InputDecoration(
                  hintText: '준비물 입력',
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 6),
                ),
                maxLines: 1,
              ),
            ),
            IconButton(
              tooltip: '삭제',
              onPressed: onDelete,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionsCard extends StatelessWidget {
  const _SuggestionsCard({
    required this.title,
    required this.subtitle,
    required this.chips,
  });

  final String title;
  final String subtitle;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(
          color: PlanFlowColors.primaryFaint,
          width: 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: chips,
            ),
          ],
        ),
      ),
    );
  }
}

class _PreActionEditorCard extends StatelessWidget {
  const _PreActionEditorCard({
    required this.draft,
    required this.index,
    required this.onDelete,
  });

  final _PreActionDraft draft;
  final int index;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(
          color: PlanFlowColors.primaryFaint,
          width: 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Chip(
                  label: Text(draft.isAuto ? '자동' : '수동'),
                  visualDensity: VisualDensity.compact,
                  side: const BorderSide(
                    color: PlanFlowColors.primaryFaint,
                    width: 0.5,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('삭제'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '선행행동 $index',
              style: theme.textTheme.titleSmall?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: draft.titleController,
              focusNode: draft.titleFocusNode,
              decoration: const InputDecoration(
                labelText: '행동 이름',
                hintText: '예: 준비물 다시 확인',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: draft.offsetController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '몇 시간 전',
                helperText: '예: 2는 시작 2시간 전',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyInlineHint extends StatelessWidget {
  const _EmptyInlineHint({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: PlanFlowColors.primaryFaint,
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: onAction,
              icon: const Icon(Icons.add, size: 18),
              label: Text(actionLabel),
            ),
          ),
        ],
      ),
    );
  }
}

class _DateTimeTile extends StatelessWidget {
  const _DateTimeTile({
    required this.label,
    required this.value,
    required this.onTap,
    this.emptyLabel,
    this.trailing,
  });

  final String label;
  final DateTime? value;
  final String? emptyLabel;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text =
        value == null ? emptyLabel ?? '날짜를 선택해 주세요' : _formatKorean(value!);

    return ListTile(
      tileColor: PlanFlowColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      title: Text(label),
      subtitle: Text(text),
      trailing: trailing ??
          const Icon(Icons.edit_calendar, color: PlanFlowColors.primaryMid),
      onTap: onTap,
    );
  }

  String _formatKorean(DateTime value) {
    const weekdays = <int, String>{
      DateTime.monday: '월요일',
      DateTime.tuesday: '화요일',
      DateTime.wednesday: '수요일',
      DateTime.thursday: '목요일',
      DateTime.friday: '금요일',
      DateTime.saturday: '토요일',
      DateTime.sunday: '일요일',
    };
    final period = value.hour < 12 ? '오전' : '오후';
    final hour12 = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    final weekday = weekdays[value.weekday] ?? '';
    return '${value.year}년 ${value.month}월 ${value.day}일 $weekday $period $hour12:$minute';
  }
}

enum _DateTimePickerStep { date, time }

class _DateTimePickerDialog extends StatefulWidget {
  const _DateTimePickerDialog({required this.initialValue});

  final DateTime initialValue;

  @override
  State<_DateTimePickerDialog> createState() => _DateTimePickerDialogState();
}

class _DateTimePickerDialogState extends State<_DateTimePickerDialog> {
  late DateTime _selectedDate;
  late DateTime _visibleMonth;
  late final TextEditingController _hourController;
  late final TextEditingController _minuteController;
  _DateTimePickerStep _step = _DateTimePickerStep.date;

  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime(
      widget.initialValue.year,
      widget.initialValue.month,
      widget.initialValue.day,
      widget.initialValue.hour,
      widget.initialValue.minute,
    );
    _visibleMonth = DateTime(_selectedDate.year, _selectedDate.month);
    _hourController = TextEditingController(
      text: _selectedDate.hour.toString().padLeft(2, '0'),
    );
    _minuteController = TextEditingController(
      text: _selectedDate.minute.toString().padLeft(2, '0'),
    );
  }

  @override
  void dispose() {
    _hourController.dispose();
    _minuteController.dispose();
    super.dispose();
  }

  void _goToTime() => setState(() => _step = _DateTimePickerStep.time);
  void _goToDate() => setState(() => _step = _DateTimePickerStep.date);

  void _pickDay(DateTime day) {
    final sameDay = DateUtils.isSameDay(day, _selectedDate);
    setState(() {
      _selectedDate = DateTime(
        day.year,
        day.month,
        day.day,
        _selectedDate.hour,
        _selectedDate.minute,
      );
      _visibleMonth = DateTime(day.year, day.month);
    });
    if (sameDay) {
      _goToTime();
    }
  }

  void _changeMonth(int delta) {
    setState(() {
      _visibleMonth = DateTime(_visibleMonth.year, _visibleMonth.month + delta);
    });
  }

  int _parsePart(String value, int fallback, int min, int max) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null) {
      return fallback;
    }
    return parsed.clamp(min, max).toInt();
  }

  void _confirm() {
    final hour = _parsePart(_hourController.text, _selectedDate.hour, 0, 23);
    final minute =
        _parsePart(_minuteController.text, _selectedDate.minute, 0, 59);
    Navigator.of(context).pop(
      DateTime(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
        hour,
        minute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 420,
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _step == _DateTimePickerStep.date
                  ? _buildDateStep(context)
                  : _buildTimeStep(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDateStep(BuildContext context) {
    final theme = Theme.of(context);
    final firstDay = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
    final leadingBlanks = (firstDay.weekday + 6) % 7;
    final daysInMonth =
        DateUtils.getDaysInMonth(_visibleMonth.year, _visibleMonth.month);
    final totalCells = leadingBlanks + daysInMonth;
    final monthTitle = '${_visibleMonth.year}년 ${_visibleMonth.month}월';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '날짜 선택',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
                onPressed: () => _changeMonth(-1),
                icon: const Icon(Icons.chevron_left)),
            Text(monthTitle),
            IconButton(
                onPressed: () => _changeMonth(1),
                icon: const Icon(Icons.chevron_right)),
          ],
        ),
        const SizedBox(height: 12),
        const Row(
          children: [
            Expanded(child: Center(child: Text('월'))),
            Expanded(child: Center(child: Text('화'))),
            Expanded(child: Center(child: Text('수'))),
            Expanded(child: Center(child: Text('목'))),
            Expanded(child: Center(child: Text('금'))),
            Expanded(child: Center(child: Text('토'))),
            Expanded(child: Center(child: Text('일'))),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 280,
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
            ),
            itemCount: totalCells,
            itemBuilder: (context, index) {
              if (index < leadingBlanks) {
                return const SizedBox.shrink();
              }
              final day = index - leadingBlanks + 1;
              final date =
                  DateTime(_visibleMonth.year, _visibleMonth.month, day);
              final selected = DateUtils.isSameDay(date, _selectedDate);
              final today = DateUtils.isSameDay(date, DateTime.now());
              return _DateCell(
                day: day,
                selected: selected,
                today: today,
                onTap: () => _pickDay(date),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '같은 날짜를 다시 누르면 시간 설정으로 넘어갑니다.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: PlanFlowColors.textSecondary),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('취소')),
            const Spacer(),
            OutlinedButton(onPressed: _goToTime, child: const Text('시간 입력')),
          ],
        ),
      ],
    );
  }

  Widget _buildTimeStep(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '시간 입력',
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          _formatKorean(_selectedDate),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: PlanFlowColors.textSecondary),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _TimeField(
                label: '시',
                controller: _hourController,
                onTapSelectAll: true,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _TimeField(
                label: '분',
                controller: _minuteController,
                onTapSelectAll: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '시와 분을 눌러 바로 수정할 수 있어요.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: PlanFlowColors.textSecondary),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            TextButton(onPressed: _goToDate, child: const Text('달력으로')),
            const Spacer(),
            OutlinedButton(onPressed: _confirm, child: const Text('확인')),
          ],
        ),
      ],
    );
  }

  String _formatKorean(DateTime value) {
    const weekdays = <int, String>{
      DateTime.monday: '월요일',
      DateTime.tuesday: '화요일',
      DateTime.wednesday: '수요일',
      DateTime.thursday: '목요일',
      DateTime.friday: '금요일',
      DateTime.saturday: '토요일',
      DateTime.sunday: '일요일',
    };
    final period = value.hour < 12 ? '오전' : '오후';
    final hour12 = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    final weekday = weekdays[value.weekday] ?? '';
    return '${value.year}년 ${value.month}월 ${value.day}일 $weekday $period $hour12:$minute';
  }
}

class _DateCell extends StatelessWidget {
  const _DateCell({
    required this.day,
    required this.selected,
    required this.today,
    required this.onTap,
  });

  final int day;
  final bool selected;
  final bool today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final background = selected ? PlanFlowColors.primary : Colors.transparent;
    final foreground =
        selected ? Colors.white : Theme.of(context).colorScheme.onSurface;
    final borderColor = selected
        ? PlanFlowColors.primary
        : today
            ? PlanFlowColors.primaryMid
            : PlanFlowColors.primaryFaint;

    return Material(
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: borderColor, width: 0.8),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Center(
          child: Text(
            '$day',
            style: TextStyle(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.label,
    required this.controller,
    required this.onTapSelectAll,
  });

  final String label;
  final TextEditingController controller;
  final bool onTapSelectAll;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(2),
      ],
      onTap: onTapSelectAll
          ? () {
              controller.selection = TextSelection(
                baseOffset: 0,
                extentOffset: controller.text.length,
              );
            }
          : null,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

class _LocationLookupSheet extends StatelessWidget {
  const _LocationLookupSheet({
    required this.initialQuery,
    required this.results,
  });

  final String initialQuery;
  final List<LocationLookupResult> results;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '정확한 위치 선택',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '검색어: $initialQuery',
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: results.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final result = results[index];
                  return Card(
                    elevation: 0,
                    color: PlanFlowColors.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: const BorderSide(
                        color: PlanFlowColors.primaryFaint,
                        width: 0.5,
                      ),
                    ),
                    child: ListTile(
                      title: Text(result.name),
                      subtitle: Text(
                        '${result.label}\n위도 ${result.latitude.toStringAsFixed(6)}, 경도 ${result.longitude.toStringAsFixed(6)}',
                      ),
                      isThreeLine: true,
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).pop(result),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('닫기'),
            ),
          ],
        ),
      ),
    );
  }
}

enum _MapSearchTarget { google, naver }

class _ExternalMapSearchSheet extends StatelessWidget {
  const _ExternalMapSearchSheet({
    required this.query,
    this.message,
  });

  final String query;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '지도에서 장소 찾기',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: PlanFlowColors.primary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message ?? '외부 지도에서 "$query"를 검색해 정확한 장소를 확인해 보세요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () =>
                  Navigator.of(context).pop(_MapSearchTarget.google),
              icon: const Icon(Icons.map_outlined),
              label: const Text('Google 지도에서 찾기'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () =>
                  Navigator.of(context).pop(_MapSearchTarget.naver),
              icon: const Icon(Icons.place_outlined),
              label: const Text('네이버 지도에서 찾기'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('닫기'),
            ),
          ],
        ),
      ),
    );
  }
}
