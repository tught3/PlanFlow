import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as google_maps;
import 'package:url_launcher/url_launcher.dart';

import '../../core/env.dart';
import '../../core/theme.dart';
import '../../services/location_lookup_service.dart';

class LocationPickerScreen extends StatefulWidget {
  LocationPickerScreen({
    super.key,
    required this.initialQuery,
    this.initialResults = const <LocationLookupResult>[],
    this.initialMessage,
    LocationLookupService? locationLookupService,
    this.canUseInAppMapOverride,
    this.debugForceMapUnavailableTimeout = false,
  }) : locationLookupService = locationLookupService ?? LocationLookupService();

  final String initialQuery;
  final List<LocationLookupResult> initialResults;
  final String? initialMessage;
  final LocationLookupService locationLookupService;
  final bool? canUseInAppMapOverride;
  final bool debugForceMapUnavailableTimeout;

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  static const _defaultMapReadinessTimeout = Duration(seconds: 5);

  late final TextEditingController _queryController;
  late List<LocationLookupResult> _results;
  LocationLookupResult? _selected;
  NaverMapController? _mapController;
  google_maps.GoogleMapController? _googleMapController;
  bool _isSearching = false;
  String? _message;
  String? _mapLoadMessage;
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

  bool get _canShowInAppMapBody =>
      _canUseInAppMap && _mapRenderState == _MapRenderState.ready;

  NLatLng get _initialTarget {
    final selected = _selected;
    if (selected != null) {
      return NLatLng(selected.latitude, selected.longitude);
    }
    return const NLatLng(37.5666, 126.979);
  }

  google_maps.LatLng get _googleInitialTarget {
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
    _results = List<LocationLookupResult>.of(widget.initialResults);
    _message = widget.initialMessage;
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
    if (_results.isEmpty && widget.initialQuery.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _watchMapReadiness());
  }

  @override
  void dispose() {
    _queryController.dispose();
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
      final results = await widget.locationLookupService.search(query);
      if (!mounted) {
        return;
      }
      setState(() {
        _results = results;
        _selected = results.isEmpty ? _selected : results.first;
        _message = results.isEmpty
            ? (_canUseInAppMap
                ? '검색 결과가 없어요. 지도에서 직접 위치를 눌러 지정할 수 있습니다.'
                : '검색 결과가 없어요. 장소명을 더 구체적으로 입력하거나 외부 지도에서 먼저 확인해 주세요.')
            : null;
      });
      final selected = _selected;
      if (selected != null) {
        await _moveMapTo(selected);
      }
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(
        title: const Text('지도에서 장소 선택'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _queryController,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => _search(),
                          decoration: const InputDecoration(
                            hintText: '장소명을 입력해 주세요',
                            prefixIcon: Icon(Icons.search),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _isSearching ? null : _search,
                        child: _isSearching
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('검색'),
                      ),
                    ],
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _message!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: switch (_mapRenderState) {
                      _MapRenderState.loading => const _MapLoadingPanel(),
                      _MapRenderState.unavailable => _MapUnavailablePanel(
                          message: _mapLoadMessage ??
                              (_canUseInAppMap
                                  ? _mapUnavailableTimeoutMessage
                                  : _missingMapMessage),
                          query: _queryController.text,
                        ),
                      _MapRenderState.ready => _canUseNaverMap
                          ? NaverMap(
                              forceGesture: true,
                              options: NaverMapViewOptions(
                                initialCameraPosition: NCameraPosition(
                                  target: _initialTarget,
                                  zoom: 15,
                                ),
                                locationButtonEnable: false,
                                compassEnable: true,
                                contentPadding:
                                    const EdgeInsets.only(bottom: 160),
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
                                if (selected != null) {
                                  await _moveMapTo(selected);
                                }
                              },
                              onMapTapped: (_, latLng) =>
                                  _selectMapPoint(latLng),
                              onMapLongTapped: (_, latLng) => _selectMapPoint(
                                latLng,
                                longPressed: true,
                              ),
                            )
                          : google_maps.GoogleMap(
                              initialCameraPosition: google_maps.CameraPosition(
                                target: _googleInitialTarget,
                                zoom: 15,
                              ),
                              myLocationButtonEnabled: false,
                              myLocationEnabled: false,
                              markers: {
                                if (_selected != null)
                                  google_maps.Marker(
                                    markerId:
                                        const google_maps.MarkerId('selected'),
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
                                if (selected != null) {
                                  await _moveGoogleMapTo(selected);
                                }
                              },
                              onTap: (latLng) => _selectMapPoint(
                                NLatLng(latLng.latitude, latLng.longitude),
                              ),
                              onLongPress: (latLng) => _selectMapPoint(
                                NLatLng(latLng.latitude, latLng.longitude),
                                longPressed: true,
                              ),
                            ),
                    },
                  ),
                  if (_canShowInAppMapBody)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 16,
                      child: _MapGestureHint(
                        hasSelectedLocation: _selected != null,
                      ),
                    ),
                  if (_canShowInAppMapBody && _mapLoadMessage != null)
                    Positioned(
                      left: 16,
                      right: 16,
                      top: 16,
                      child: _MapLoadFallbackBanner(
                        message: _mapLoadMessage!,
                        query: _queryController.text,
                        results: _results,
                        onSelect: _selectResult,
                      ),
                    ),
                ],
              ),
            ),
            _BottomSelectionPanel(
              results: _results,
              selected: _selected,
              onSelect: _selectResult,
              onConfirm: _confirm,
            ),
          ],
        ),
      ),
    );
  }
}

class _MapGestureHint extends StatelessWidget {
  const _MapGestureHint({required this.hasSelectedLocation});

  final bool hasSelectedLocation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.center,
      child: Material(
        elevation: 5,
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: PlanFlowColors.surface.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: PlanFlowColors.primaryFaint),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.touch_app_outlined,
                size: 18,
                color: PlanFlowColors.primary,
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  hasSelectedLocation
                      ? '다른 곳을 길게 누르면 위치를 바꿀 수 있어요'
                      : '지도에서 원하는 곳을 길게 눌러 위치를 지정하세요',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomSelectionPanel extends StatelessWidget {
  const _BottomSelectionPanel({
    required this.results,
    required this.selected,
    required this.onSelect,
    required this.onConfirm,
  });

  final List<LocationLookupResult> results;
  final LocationLookupResult? selected;
  final ValueChanged<LocationLookupResult> onSelect;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(
        color: PlanFlowColors.surface,
        border: Border(top: BorderSide(color: PlanFlowColors.primaryFaint)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
            const SizedBox(height: 10),
          ],
          if (results.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: results.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final result = results[index];
                  final isSelected = result == selected;
                  return ChoiceChip(
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          result.providerLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: isSelected
                                ? PlanFlowColors.surface
                                : PlanFlowColors.textSecondary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            result.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    selected: isSelected,
                    onSelected: (_) => onSelect(result),
                  );
                },
              ),
            ),
          if (results.isEmpty)
            Text(
              '현재 검색된 후보가 없어요. 검색어를 바꿔보거나 지도에서 직접 선택해 주세요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
          const SizedBox(height: 10),
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

class _MapLoadingPanel extends StatelessWidget {
  const _MapLoadingPanel();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(
              '인앱 지도를 불러오는 중이에요. 잠시만 기다려 주세요.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapLoadFallbackBanner extends StatelessWidget {
  const _MapLoadFallbackBanner({
    required this.message,
    required this.query,
    required this.results,
    required this.onSelect,
  });

  final String message;
  final String query;
  final List<LocationLookupResult> results;
  final ValueChanged<LocationLookupResult> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visibleResults = results.take(3).toList(growable: false);
    return Material(
      elevation: 6,
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: PlanFlowColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: PlanFlowColors.primaryFaint),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.map_outlined,
                  color: PlanFlowColors.primaryMid,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '지도 표시 확인 필요',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
                height: 1.35,
              ),
            ),
            if (visibleResults.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final result in visibleResults)
                    ActionChip(
                      label: Text(
                        result.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onPressed: () => onSelect(result),
                    ),
                ],
              ),
            ],
            if (query.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '"${query.trim()}" 검색 결과를 아래 후보에서 확정할 수 있어요.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 10),
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
