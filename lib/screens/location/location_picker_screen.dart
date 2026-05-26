import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as google_maps;
import 'package:url_launcher/url_launcher.dart';

import '../../core/env.dart';
import '../../core/theme.dart';
import '../../services/app_permission_service.dart';
import '../../services/location_lookup_service.dart';

class LocationPickerScreen extends StatefulWidget {
  LocationPickerScreen({
    super.key,
    required this.initialQuery,
    this.initialResults = const <LocationLookupResult>[],
    this.initialFallbackQueries = const <String>[],
    this.initialMessage,
    this.initialMapCenter,
    this.initialMapCenterFuture,
    LocationLookupService? locationLookupService,
    this.preferredInAppMapProvider,
    this.canUseInAppMapOverride,
    this.debugForceMapUnavailableTimeout = false,
  }) : locationLookupService = locationLookupService ?? LocationLookupService();

  final String initialQuery;
  final List<LocationLookupResult> initialResults;
  final List<String> initialFallbackQueries;
  final String? initialMessage;
  final GeoPoint? initialMapCenter;
  final Future<GeoPoint?>? initialMapCenterFuture;
  final LocationLookupService locationLookupService;
  final LocationPickerInAppMapProvider? preferredInAppMapProvider;
  final bool? canUseInAppMapOverride;
  final bool debugForceMapUnavailableTimeout;

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  static const _defaultMapReadinessTimeout = Duration(seconds: 5);
  static const _candidateScrollStep = 240.0;
  static const _candidateScrollAnimationDuration = Duration(milliseconds: 220);

  late final TextEditingController _queryController;
  late final ScrollController _candidateScrollController;
  late List<LocationLookupResult> _results;
  late List<String> _fallbackQueries;
  LocationLookupResult? _selected;
  NaverMapController? _mapController;
  google_maps.GoogleMapController? _googleMapController;
  bool _isSearching = false;
  bool _hasUserChosenMapTarget = false;
  String? _message;
  String? _mapLoadMessage;
  GeoPoint? _resolvedInitialMapCenter;
  _MapRenderState _mapRenderState = _MapRenderState.unavailable;

  bool get _canUseNaverMap {
    if (widget.canUseInAppMapOverride == false) {
      return false;
    }
    return AppEnv.isNaverMapReady;
  }

  bool get _canUseGoogleMap {
    if (widget.canUseInAppMapOverride == false) {
      return false;
    }
    return AppEnv.googleMapsApiKey.trim().isNotEmpty;
  }

  bool get _canUseInAppMap => widget.canUseInAppMapOverride == false
      ? false
      : (_canUseNaverMap || _canUseGoogleMap);

  bool get _shouldUseNaverMap {
    if (widget.preferredInAppMapProvider ==
        LocationPickerInAppMapProvider.google) {
      return _canUseNaverMap && !_canUseGoogleMap;
    }
    if (widget.preferredInAppMapProvider ==
        LocationPickerInAppMapProvider.naver) {
      return _canUseNaverMap;
    }
    return _canUseNaverMap;
  }

  NLatLng get _initialTarget {
    final initialMapCenter = _resolvedInitialMapCenter;
    if (initialMapCenter != null) {
      return NLatLng(initialMapCenter.latitude, initialMapCenter.longitude);
    }
    final selected = _selected;
    if (selected != null) {
      return NLatLng(selected.latitude, selected.longitude);
    }
    return const NLatLng(37.5666, 126.979);
  }

  google_maps.LatLng get _googleInitialTarget {
    final initialMapCenter = _resolvedInitialMapCenter;
    if (initialMapCenter != null) {
      return google_maps.LatLng(
        initialMapCenter.latitude,
        initialMapCenter.longitude,
      );
    }
    final selected = _selected;
    if (selected != null) {
      return google_maps.LatLng(selected.latitude, selected.longitude);
    }
    return const google_maps.LatLng(37.5666, 126.979);
  }

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: widget.initialQuery);
    _candidateScrollController = ScrollController();
    _results = List<LocationLookupResult>.of(widget.initialResults);
    _fallbackQueries = List<String>.of(widget.initialFallbackQueries);
    _message = widget.initialMessage;
    _resolvedInitialMapCenter = widget.initialMapCenter;
    if (_results.isNotEmpty) {
      _selected = _results.first;
    }
    if (widget.debugForceMapUnavailableTimeout) {
      _mapLoadMessage = _mapUnavailableTimeoutMessage;
      _mapRenderState = _MapRenderState.unavailable;
    } else {
      _mapRenderState = _canUseInAppMap
          ? _MapRenderState.loading
          : _MapRenderState.unavailable;
    }
    if (_results.isEmpty &&
        widget.initialQuery.trim().isNotEmpty &&
        _message == null &&
        _fallbackQueries.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _watchMapReadiness());
    unawaited(_watchInitialMapCenter());
  }

  @override
  void dispose() {
    _queryController.dispose();
    _candidateScrollController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _message = '검색할 장소를 입력해 주세요.';
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _message = null;
    });

    try {
      final searchResult =
          await widget.locationLookupService.searchWithFallback(
        query,
        origin: _resolvedInitialMapCenter,
      );
      final results = searchResult.results;
      if (!mounted) {
        return;
      }
      setState(() {
        _results = results;
        _fallbackQueries = results.isEmpty
            ? searchResult.fallbackQueries.take(4).toList()
            : const <String>[];
        _selected = results.isEmpty ? _selected : results.first;
        _message = results.isEmpty
            ? (_canUseInAppMap
                ? '검색 결과가 없어요. 지도에서 직접 위치를 눌러 지정할 수 있습니다.'
                : '검색 결과가 없어요. 장소명을 더 구체적으로 입력하거나 외부 지도에서 먼저 확인해 주세요.')
            : null;
      });
      if (_candidateScrollController.hasClients) {
        _candidateScrollController.jumpTo(0);
      }
      final selected = _selected;
      if (selected != null) {
        _hasUserChosenMapTarget = true;
        await _moveMapTo(selected);
      }
    } on LocationLookupException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _fallbackQueries = const <String>[];
        _message = error.message;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = _canUseInAppMap
            ? '장소 검색에 실패했어요. 지도에서 직접 위치를 눌러 지정해 주세요.'
            : '장소 검색에 실패했어요. API 키와 네트워크를 확인하거나 외부 지도에서 먼저 확인해 주세요.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  void _submitSearch() {
    FocusScope.of(context).unfocus();
    unawaited(_search());
  }

  void _scrollCandidates(int direction) {
    final controller = _candidateScrollController;
    if (!controller.hasClients) {
      return;
    }
    final maxExtent = controller.position.maxScrollExtent;
    final current = controller.offset;
    final step = _candidateScrollStep;
    final target = (current + direction * step).clamp(0.0, maxExtent);
    controller.animateTo(
      target,
      duration: _candidateScrollAnimationDuration,
      curve: Curves.easeInOut,
    );
  }

  void _searchFallbackQuery(String query) {
    _queryController.text = query;
    _submitSearch();
  }

  Future<void> _moveMapTo(LocationLookupResult result) async {
    await _moveNaverMapTo(result);
    await _moveGoogleMapTo(result);
  }

  Future<void> _moveNaverMapTo(LocationLookupResult result) async {
    final controller = _mapController;
    if (controller == null) {
      return;
    }
    final position = NLatLng(result.latitude, result.longitude);
    await controller.clearOverlays(type: NOverlayType.marker);
    await controller.addOverlay(
      NMarker(
        id: 'selected-location',
        position: position,
        caption: NOverlayCaption(text: result.name),
      ),
    );
    await controller.updateCamera(
      NCameraUpdate.scrollAndZoomTo(target: position, zoom: 15),
    );
  }

  Future<void> _moveGoogleMapTo(LocationLookupResult result) async {
    final controller = _googleMapController;
    if (controller == null) {
      return;
    }
    await controller.animateCamera(
      google_maps.CameraUpdate.newLatLngZoom(
        google_maps.LatLng(result.latitude, result.longitude),
        15,
      ),
    );
  }

  Future<void> _selectResult(LocationLookupResult result) async {
    setState(() {
      _selected = result;
      _queryController.text = result.name;
      _hasUserChosenMapTarget = true;
    });
    await _moveMapTo(result);
  }

  Future<void> _selectMapPoint(
    NLatLng latLng, {
    bool longPressed = false,
  }) async {
    final query = _queryController.text.trim();
    final result = LocationLookupResult(
      name: query.isEmpty ? '지도에서 선택한 위치' : query,
      address: longPressed ? '지도에서 길게 눌러 지정한 위치' : '지도에서 직접 선택한 위치',
      latitude: latLng.latitude,
      longitude: latLng.longitude,
      provider: LocationLookupProvider.manual,
    );
    setState(() {
      _selected = result;
      _hasUserChosenMapTarget = true;
      _message = longPressed
          ? '길게 누른 위치로 바꿨어요. 아래 버튼으로 확정해 주세요.'
          : '지도에서 위치를 선택했어요. 아래 버튼으로 확정해 주세요.';
    });
    await _moveMapTo(result);
  }

  void _confirm() {
    final selected = _selected;
    if (selected == null) {
      setState(() {
        _message = _canUseInAppMap
            ? '먼저 지도에서 위치를 선택해 주세요.'
            : '먼저 장소 후보를 선택하거나 외부 지도에서 확인한 뒤 다시 검색해 주세요.';
      });
      return;
    }
    Navigator.of(context).pop(selected);
  }

  Future<void> _watchMapReadiness() async {
    if (!_canUseInAppMap || widget.debugForceMapUnavailableTimeout) {
      return;
    }
    await Future<void>.delayed(_defaultMapReadinessTimeout);
    if (!mounted) {
      return;
    }
    if (_mapRenderState != _MapRenderState.loading) {
      return;
    }
    final hasController =
        _mapController != null || _googleMapController != null;
    if (!hasController) {
      setState(() {
        _mapLoadMessage =
            '지도 화면이 아직 열리지 않았어요. API 키 제한을 확인하거나 아래 장소 후보를 선택해 주세요.';
        _mapRenderState = _MapRenderState.unavailable;
      });
    }
  }

  Future<void> _watchInitialMapCenter() async {
    final future = widget.initialMapCenterFuture;
    if (future == null || widget.initialMapCenter != null) {
      return;
    }
    try {
      final point = await future;
      if (!mounted || point == null || _hasUserChosenMapTarget) {
        return;
      }
      setState(() {
        _resolvedInitialMapCenter = point;
      });
      await _moveMapCenterTo(point);
    } catch (error) {
      debugPrint('Initial map center update skipped: $error');
    }
  }

  Future<void> _moveMapCenterTo(GeoPoint point) async {
    final naverController = _mapController;
    if (naverController != null) {
      await naverController.updateCamera(
        NCameraUpdate.scrollAndZoomTo(
          target: NLatLng(point.latitude, point.longitude),
          zoom: 15,
        ),
      );
    }
    final googleController = _googleMapController;
    if (googleController != null) {
      await googleController.animateCamera(
        google_maps.CameraUpdate.newLatLngZoom(
          google_maps.LatLng(point.latitude, point.longitude),
          15,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // TLHC 네이티브 뷰는 body 영역을 덮지만 AppBar/bottomNavigationBar는 보임.
    // AppBar 없이 body만 있으면 엣지-투-엣지로 bottomNav까지 덮힘.
    // → 검색 UI는 AppBar 하단에 고정하고, bottomNavigationBar는 후보/확정만 담당.
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: PlanFlowColors.background,
        appBar: AppBar(
          title: const Text('지도에서 장소 선택'),
          backgroundColor: PlanFlowColors.background,
          bottom: _MapSearchHeader(
            queryController: _queryController,
            isSearching: _isSearching,
            isMapLoading:
                _mapRenderState == _MapRenderState.loading && _canUseInAppMap,
            message: _mapLoadMessage ?? _message,
            onSearch: _submitSearch,
          ),
        ),
        body: _buildBody(),
        bottomNavigationBar: _MapControlSheet(
          results: _results,
          fallbackQueries: _fallbackQueries,
          selected: _selected,
          candidateScrollController: _candidateScrollController,
          showCandidateScrollControls: _results.length > 1,
          onScrollCandidatesLeft: () => _scrollCandidates(-1),
          onScrollCandidatesRight: () => _scrollCandidates(1),
          onSelectFallbackQuery: _searchFallbackQuery,
          onSelect: _selectResult,
          onConfirm: _confirm,
        ),
      ),
    );
  }

  Widget _buildBody() {
    // 지도 사용 불가 상태: 순수 Flutter 패널 (PlatformView 없음)
    if (!_canUseInAppMap || _mapRenderState == _MapRenderState.unavailable) {
      return _MapUnavailablePanel(
        message: _mapLoadMessage ??
            (_canUseInAppMap
                ? _mapUnavailableTimeoutMessage
                : _missingMapMessage),
        query: _queryController.text,
      );
    }

    // 네이버 지도 (loading → ready 모두 NaverMap 위젯 유지)
    if (_shouldUseNaverMap) {
      return NaverMap(
        forceGesture: true,
        // ignore: invalid_use_of_visible_for_testing_member
        forceHybridComposition: true,
        options: NaverMapViewOptions(
          initialCameraPosition: NCameraPosition(
            target: _initialTarget,
            zoom: 15,
          ),
          locationButtonEnable: false,
          compassEnable: true,
          contentPadding: EdgeInsets.zero,
        ),
        onMapReady: (controller) async {
          _mapController = controller;
          if (mounted) {
            setState(() {
              _mapLoadMessage = null;
              _mapRenderState = _MapRenderState.ready;
            });
          }
          final selected = _selected;
          if (selected != null && _resolvedInitialMapCenter == null) {
            await _moveMapTo(selected);
          }
        },
        onMapTapped: (_, latLng) => _selectMapPoint(latLng),
        onMapLongTapped: (_, latLng) =>
            _selectMapPoint(latLng, longPressed: true),
      );
    }

    // 구글 지도 (loading → ready 모두 GoogleMap 위젯 유지)
    return google_maps.GoogleMap(
      initialCameraPosition: google_maps.CameraPosition(
        target: _googleInitialTarget,
        zoom: 15,
      ),
      myLocationButtonEnabled: false,
      myLocationEnabled: false,
      markers: {
        if (_selected != null)
          google_maps.Marker(
            markerId: const google_maps.MarkerId('selected'),
            position: google_maps.LatLng(
              _selected!.latitude,
              _selected!.longitude,
            ),
            infoWindow: google_maps.InfoWindow(
              title: _selected!.name,
              snippet: _selected!.address,
            ),
          ),
      },
      onMapCreated: (controller) async {
        _googleMapController = controller;
        if (mounted) {
          setState(() {
            _mapLoadMessage = null;
            _mapRenderState = _MapRenderState.ready;
          });
        }
        final selected = _selected;
        if (selected != null && _resolvedInitialMapCenter == null) {
          await _moveGoogleMapTo(selected);
        }
      },
      onTap: (latLng) =>
          _selectMapPoint(NLatLng(latLng.latitude, latLng.longitude)),
      onLongPress: (latLng) => _selectMapPoint(
          NLatLng(latLng.latitude, latLng.longitude),
          longPressed: true),
    );
  }
}

/// 지도 화면 하단 컨트롤 시트.
/// TLHC PlatformView가 AppBar까지 덮는 문제로 인해
/// 검색바는 AppBar 하단에 두고, bottomNavigationBar에는 후보 목록과 확인 버튼만 둔다.
class _MapSearchHeader extends StatelessWidget implements PreferredSizeWidget {
  const _MapSearchHeader({
    required this.queryController,
    required this.isSearching,
    required this.isMapLoading,
    required this.message,
    required this.onSearch,
  });

  static const double _baseHeight = 76;
  static const double _messageHeight = 112;

  final TextEditingController queryController;
  final bool isSearching;
  final bool isMapLoading;
  final String? message;
  final VoidCallback onSearch;

  @override
  Size get preferredSize =>
      Size.fromHeight(message == null ? _baseHeight : _messageHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: PlanFlowColors.background,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        decoration: const BoxDecoration(
          color: PlanFlowColors.background,
          border:
              Border(bottom: BorderSide(color: PlanFlowColors.primaryFaint)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('location-search-field'),
                    controller: queryController,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => onSearch(),
                    decoration: const InputDecoration(
                      hintText: '장소명을 입력해 주세요',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('location-search-button'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(64, 48),
                  ),
                  onPressed: isSearching ? null : onSearch,
                  child: isSearching
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('검색'),
                ),
                if (isMapLoading) ...[
                  const SizedBox(width: 8),
                  const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: PlanFlowColors.primaryLight,
                    ),
                  ),
                ],
              ],
            ),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: PlanFlowColors.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MapControlSheet extends StatelessWidget {
  const _MapControlSheet({
    required this.results,
    required this.fallbackQueries,
    required this.selected,
    required this.candidateScrollController,
    required this.showCandidateScrollControls,
    required this.onScrollCandidatesLeft,
    required this.onScrollCandidatesRight,
    required this.onSelectFallbackQuery,
    required this.onSelect,
    required this.onConfirm,
  });

  final List<LocationLookupResult> results;
  final List<String> fallbackQueries;
  final LocationLookupResult? selected;
  final ScrollController candidateScrollController;
  final bool showCandidateScrollControls;
  final VoidCallback onScrollCandidatesLeft;
  final VoidCallback onScrollCandidatesRight;
  final ValueChanged<String> onSelectFallbackQuery;
  final ValueChanged<LocationLookupResult> onSelect;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(16, 10, 16, bottomPadding + 12),
      decoration: const BoxDecoration(
        color: PlanFlowColors.surface,
        border: Border(top: BorderSide(color: PlanFlowColors.primaryFaint)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 선택된 장소 정보
          if (selected != null) ...[
            Text(
              selected!.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              selected!.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
          ],
          // 후보 목록 칩
          if (results.isNotEmpty) ...[
            if (showCandidateScrollControls) ...[
              Text(
                '후보가 여러 개예요. 좌우로 넘겨서 확인해 보세요.',
                key: const ValueKey('location-candidates-hint'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
            ],
            SizedBox(
              height: 36,
              child: Row(
                children: [
                  if (showCandidateScrollControls)
                    IconButton(
                      key: const ValueKey('location-candidates-scroll-left'),
                      icon: const Icon(Icons.chevron_left),
                      color: PlanFlowColors.primary,
                      visualDensity: VisualDensity.compact,
                      onPressed: onScrollCandidatesLeft,
                    ),
                  Expanded(
                    child: ListView.separated(
                      controller: candidateScrollController,
                      scrollDirection: Axis.horizontal,
                      itemCount: results.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final r = results[i];
                        final isSel = r == selected;
                        return ChoiceChip(
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                r.providerLabel,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: isSel
                                      ? PlanFlowColors.surface
                                      : PlanFlowColors.textSecondary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  r.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          selected: isSel,
                          onSelected: (_) => onSelect(r),
                        );
                      },
                    ),
                  ),
                  if (showCandidateScrollControls)
                    IconButton(
                      key: const ValueKey('location-candidates-scroll-right'),
                      icon: const Icon(Icons.chevron_right),
                      color: PlanFlowColors.primary,
                      visualDensity: VisualDensity.compact,
                      onPressed: onScrollCandidatesRight,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (results.isEmpty) ...[
            if (fallbackQueries.isNotEmpty) ...[
              Text(
                '이런 검색어로 다시 찾아볼까요?',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final query in fallbackQueries)
                    ActionChip(
                      label: Text(query),
                      onPressed: () => onSelectFallbackQuery(query),
                    ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            Text(
              '현재 검색된 후보가 없어요. 검색어를 바꿔보거나 지도에서 직접 선택해 주세요.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: PlanFlowColors.textSecondary),
            ),
            const SizedBox(height: 8),
          ],
          // 확인 버튼
          FilledButton.icon(
            onPressed: selected == null ? null : onConfirm,
            icon: const Icon(Icons.check),
            label: const Text('이 위치 사용'),
          ),
        ],
      ),
    );
  }
}

enum LocationPickerInAppMapProvider {
  naver,
  google,
}

class _MapUnavailablePanel extends StatelessWidget {
  const _MapUnavailablePanel({
    required this.message,
    required this.query,
  });

  final String message;
  final String query;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 14),
            _ExternalMapButtons(query: query),
          ],
        ),
      ),
    );
  }
}

const String _missingMapMessage =
    '앱 안 지도를 열 수 없습니다.\n지도 API 키, 패키지명 제한, 인증 상태를 확인해 주세요.\n아래 장소 후보를 선택하거나 외부 지도에서 먼저 확인할 수 있어요.';

const String _mapUnavailableTimeoutMessage =
    '지도 화면이 아직 열리지 않았어요. SDK/키/권한 설정을 확인하고 아래 버튼으로 계속 진행해 주세요.';

enum _MapRenderState {
  loading,
  ready,
  unavailable,
}

enum _ExternalMapTarget {
  google('Google 지도'),
  naver('네이버 지도'),
  tmap('TMAP');

  const _ExternalMapTarget(this.label);

  final String label;

  Uri uri(String query) {
    final trimmed = query.trim();
    final encoded = Uri.encodeComponent(trimmed);
    return switch (this) {
      _ExternalMapTarget.google => Uri.https(
          'www.google.com',
          '/maps/search/',
          <String, String>{'api': '1', 'query': trimmed},
        ),
      _ExternalMapTarget.naver =>
        Uri.parse('https://map.naver.com/p/search/$encoded'),
      _ExternalMapTarget.tmap => Uri.parse('tmap://search?name=$encoded'),
    };
  }
}

class _ExternalMapButtons extends StatelessWidget {
  const _ExternalMapButtons({required this.query});

  final String query;

  Future<void> _open(BuildContext context, _ExternalMapTarget target) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('외부 지도에서 검색할 장소명을 먼저 입력해 주세요.')),
      );
      return;
    }
    final opened = await launchUrl(
      target.uri(trimmed),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('${target.label}를 열지 못했어요.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget button(_ExternalMapTarget target) {
      return Expanded(
        child: SizedBox(
          height: 42,
          child: FilledButton.tonalIcon(
            onPressed: () => _open(context, target),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(target.label),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        button(_ExternalMapTarget.google),
        const SizedBox(width: 6),
        button(_ExternalMapTarget.naver),
        const SizedBox(width: 6),
        button(_ExternalMapTarget.tmap),
      ],
    );
  }
}
