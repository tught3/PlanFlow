import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/env.dart';
import '../../core/theme.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/auth_provider.dart';
import '../../services/app_permission_service.dart';
import '../../services/location_lookup_service.dart';
import 'location_picker_screen.dart';

Future<LocationLookupResult?> pickLocationFromQuery({
  required BuildContext context,
  required String query,
  LocationLookupService? locationLookupService,
  AppPermissionService? appPermissionService,
  String? preferredMapProvider,
  bool? canUseInAppMapOverride,
  // 이미 좌표가 고정된 경우 검색 없이 해당 결과로 바로 지도 열기
  LocationLookupResult? lockedResult,
}) async {
  final trimmed = query.trim();

  final service = locationLookupService ?? LocationLookupService();
  final permissionService = _createPermissionService(appPermissionService);
  final resolvedMapProvider =
      _normalizePreferredMapProvider(preferredMapProvider) ??
          await _loadPreferredMapProvider();
  if (!context.mounted) {
    return null;
  }
  final inAppMapProvider = _inAppMapProviderFor(resolvedMapProvider);
  final permissionMessage = await _ensureLocationPermissionForMap(
    context,
    permissionService,
  );
  if (!context.mounted) {
    return null;
  }

  // 좌표 고정 상태: 검색 없이 현재 위치를 지도에서 바로 표시
  if (lockedResult != null) {
    return Navigator.of(context).push<LocationLookupResult>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialQuery: trimmed,
          initialResults: [lockedResult],
          initialMapCenter: GeoPoint(
            latitude: lockedResult.latitude,
            longitude: lockedResult.longitude,
          ),
          locationLookupService: service,
          preferredInAppMapProvider: inAppMapProvider,
          canUseInAppMapOverride: canUseInAppMapOverride,
        ),
      ),
    );
  }

  final origin = permissionMessage == null
      ? await permissionService?.getLastKnownLocation()
      : null;
  if (!context.mounted) {
    return null;
  }
  final lookupFuture = trimmed.isEmpty
      ? null
      : service
          .searchWithFallback(
            trimmed,
            origin: origin,
            preferredProvider:
                _lookupProviderForPreference(resolvedMapProvider),
          )
          .timeout(const Duration(seconds: 12));
  final initialMapCenterFuture = permissionMessage == null
      ? _startInitialMapCenterLoad(permissionService)
      : null;
  if (trimmed.isEmpty) {
    if (!context.mounted) {
      return null;
    }
    return Navigator.of(context).push<LocationLookupResult>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialQuery: '',
          initialMessage: permissionMessage,
          initialMapCenterFuture: initialMapCenterFuture,
          locationLookupService: service,
          preferredInAppMapProvider: inAppMapProvider,
          canUseInAppMapOverride: canUseInAppMapOverride,
        ),
      ),
    );
  }

  try {
    final lookup = await lookupFuture!;
    final results = lookup.results;
    if (!context.mounted) {
      return null;
    }

    if (results.isEmpty) {
      return Navigator.of(context).push<LocationLookupResult>(
        MaterialPageRoute(
          builder: (_) => LocationPickerScreen(
            initialQuery: trimmed,
            initialResults: const <LocationLookupResult>[],
            initialFallbackQueries: lookup.fallbackQueries.take(4).toList(),
            initialMessage: _joinLocationMessages(
              permissionMessage,
              '검색 결과가 없어요. 지도에서 직접 위치를 선택해 주세요.',
            ),
            initialMapCenterFuture: initialMapCenterFuture,
            locationLookupService: service,
            preferredInAppMapProvider: inAppMapProvider,
            canUseInAppMapOverride: canUseInAppMapOverride,
          ),
        ),
      );
    }

    return Navigator.of(context).push<LocationLookupResult>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialQuery: trimmed,
          initialResults: results,
          initialMessage: permissionMessage,
          initialMapCenterFuture: initialMapCenterFuture,
          locationLookupService: service,
          preferredInAppMapProvider: inAppMapProvider,
          canUseInAppMapOverride: canUseInAppMapOverride,
        ),
      ),
    );
  } on LocationLookupException catch (error) {
    if (!context.mounted) {
      return null;
    }
    final provider = error.provider.providerLabel;
    return Navigator.of(context).push<LocationLookupResult>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialQuery: trimmed,
          initialMessage: _joinLocationMessages(
            permissionMessage,
            '$provider 장소 검색 인증에 실패했어요. 지도에서 직접 위치를 선택해 주세요.',
          ),
          initialMapCenterFuture: initialMapCenterFuture,
          locationLookupService: service,
          preferredInAppMapProvider: inAppMapProvider,
          canUseInAppMapOverride: canUseInAppMapOverride,
        ),
      ),
    );
  } catch (error) {
    if (!context.mounted) {
      return null;
    }
    debugPrint('Location pick flow failed: $error');
    return Navigator.of(context).push<LocationLookupResult>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialQuery: trimmed,
          initialMessage: _joinLocationMessages(
            permissionMessage,
            '장소 검색이 오래 걸리거나 실패했어요. 지도에서 직접 위치를 선택해 주세요.',
          ),
          initialMapCenterFuture: initialMapCenterFuture,
          locationLookupService: service,
          preferredInAppMapProvider: inAppMapProvider,
          canUseInAppMapOverride: canUseInAppMapOverride,
        ),
      ),
    );
  }
}

AppPermissionService? _createPermissionService(
  AppPermissionService? appPermissionService,
) {
  if (appPermissionService != null) {
    return appPermissionService;
  }
  try {
    return AppPermissionService();
  } catch (error) {
    debugPrint('Location permission service unavailable: $error');
    return null;
  }
}

Future<String?> _ensureLocationPermissionForMap(
  BuildContext context,
  AppPermissionService? permissions,
) async {
  if (permissions == null) {
    return '현재 위치 권한을 확인하지 못했어요. 지도에서 직접 위치를 선택해 주세요.';
  }

  try {
    if (await permissions.checkLocationPermission()) {
      return null;
    }
    final granted = await permissions.requestLocationPermission();
    if (granted || await permissions.checkLocationPermission()) {
      return null;
    }
  } catch (error) {
    debugPrint('Location permission request before map failed: $error');
  }

  if (context.mounted) {
    await _showLocationPermissionGuide(context, permissions);
  }
  return '현재 위치를 보려면 위치 권한이 필요해요. Android 설정에서 PlanFlow 위치 권한을 켜 주세요.';
}

Future<void> _showLocationPermissionGuide(
  BuildContext context,
  AppPermissionService permissions,
) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('위치 권한이 필요해요'),
        content: const Text(
          '지도를 현재 위치 기준으로 보여주려면 위치 권한이 필요합니다. 권한을 켜면 주변 장소를 더 빠르게 고를 수 있어요.',
        ),
        actions: [
          SizedBox(
            width: double.maxFinite,
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('계속 선택'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      await permissions.openAppSettings();
                      if (context.mounted) {
                        Navigator.of(context).pop();
                      }
                    },
                    child: const Text('설정 열기'),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

String _joinLocationMessages(String? first, String second) {
  if (first == null || first.trim().isEmpty) {
    return second;
  }
  return '$first\n$second';
}

Future<GeoPoint?> _loadInitialMapCenter(
    AppPermissionService permissions) async {
  try {
    return await permissions.getLastKnownLocation() ??
        await permissions.getCurrentLocation();
  } catch (error) {
    debugPrint('Initial map center load skipped: $error');
    return null;
  }
}

Future<GeoPoint?>? _startInitialMapCenterLoad(
  AppPermissionService? permissions,
) {
  return permissions == null ? null : _loadInitialMapCenter(permissions);
}

Future<String> _loadPreferredMapProvider() async {
  final userId = authProvider.userId;
  if (!AppEnv.isSupabaseReady || userId == null || userId.isEmpty) {
    return AppEnv.naverMapClientId.trim().isNotEmpty ? 'naver' : 'google';
  }
  try {
    final settings = await SettingsRepository.supabase().fetchSettings(userId);
    return _normalizePreferredMapProvider(settings?.preferredMapProvider) ??
        (AppEnv.naverMapClientId.trim().isNotEmpty ? 'naver' : 'google');
  } catch (error) {
    debugPrint('Preferred map provider load skipped: $error');
    return AppEnv.naverMapClientId.trim().isNotEmpty ? 'naver' : 'google';
  }
}

String? _normalizePreferredMapProvider(String? value) {
  final normalized = value?.trim().toLowerCase();
  return switch (normalized) {
    'google' || 'tmap' || 'naver' => normalized,
    _ => null,
  };
}

LocationPickerInAppMapProvider? _inAppMapProviderFor(String provider) {
  return switch (provider) {
    'google' => LocationPickerInAppMapProvider.google,
    'naver' => AppEnv.naverMapClientId.trim().isNotEmpty
        ? LocationPickerInAppMapProvider.naver
        : AppEnv.googleMapsApiKey.trim().isNotEmpty
            ? LocationPickerInAppMapProvider.google
            : LocationPickerInAppMapProvider.naver,
    'tmap' => AppEnv.naverMapClientId.trim().isNotEmpty
        ? LocationPickerInAppMapProvider.naver
        : AppEnv.googleMapsApiKey.trim().isNotEmpty
            ? LocationPickerInAppMapProvider.google
            : null,
    _ => null,
  };
}

LocationLookupProvider? _lookupProviderForPreference(String provider) {
  return switch (provider) {
    'tmap' => LocationLookupProvider.tmap,
    'naver' => LocationLookupProvider.naver,
    'google' => LocationLookupProvider.google,
    _ => null,
  };
}

Future<LocationLookupResult?> showLocationCandidateSheet(
  BuildContext context,
  String query,
  List<LocationLookupResult> results,
) {
  return showModalBottomSheet<LocationLookupResult>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '장소 후보 선택',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: PlanFlowColors.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '"$query"로 찾은 후보입니다. 정확한 장소를 선택해 주세요.',
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
                    return ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: const BorderSide(
                          color: PlanFlowColors.primaryFaint,
                        ),
                      ),
                      title: Text(result.name),
                      subtitle:
                          Text('${result.providerLabel} · ${result.label}'),
                      onTap: () => Navigator.of(context).pop(result),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Future<void> showExternalMapOptions(
  BuildContext context,
  String query, {
  String? message,
}) async {
  final selected = await showDialog<_ExternalMapTarget>(
    context: context,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: _ExternalMapSheet(query: query, message: message),
    ),
  );
  if (!context.mounted || selected == null) {
    return;
  }
  await _openExternalMapTarget(
    context,
    selected,
    query,
    failureMessage: '${selected.label}를 열지 못했어요. 앱 설치 또는 브라우저 연결을 확인해 주세요.',
  );
}

Future<bool> _openExternalMapTarget(
  BuildContext context,
  _ExternalMapTarget target,
  String query, {
  required String failureMessage,
}) async {
  final launched = await launchUrl(
    target.uri(query),
    mode: LaunchMode.externalApplication,
  );
  if (!launched && context.mounted) {
    await showLocationMessage(context, failureMessage);
  }
  return launched;
}

Future<void> showLocationMessage(BuildContext context, String message) async {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(message)),
  );
}

enum _ExternalMapTarget {
  google('Google 지도'),
  naver('네이버 지도'),
  tmap('TMAP');

  const _ExternalMapTarget(this.label);

  final String label;

  Uri uri(String query) {
    final encoded = Uri.encodeComponent(query.trim());
    return switch (this) {
      _ExternalMapTarget.google => Uri.https(
          'www.google.com',
          '/maps/search/',
          <String, String>{'api': '1', 'query': query.trim()},
        ),
      _ExternalMapTarget.naver =>
        Uri.parse('https://map.naver.com/p/search/$encoded'),
      _ExternalMapTarget.tmap => Uri.parse('tmap://search?name=$encoded'),
    };
  }
}

class _ExternalMapSheet extends StatelessWidget {
  const _ExternalMapSheet({required this.query, this.message});

  final String query;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget mapButton(_ExternalMapTarget target) {
      return SizedBox(
        height: 46,
        child: FilledButton.tonalIcon(
          onPressed: () => Navigator.of(context).pop(target),
          style: FilledButton.styleFrom(
            backgroundColor: PlanFlowColors.primaryFaint,
            foregroundColor: PlanFlowColors.primary,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: Size.zero,
          ),
          icon: const Icon(Icons.map_outlined, size: 18),
          label: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              target.label,
              maxLines: 1,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '외부 지도에서 확인',
            style: theme.textTheme.titleMedium?.copyWith(
              color: PlanFlowColors.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message ?? '"$query"를 외부 지도에서 검색합니다.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: mapButton(_ExternalMapTarget.google)),
              const SizedBox(width: 8),
              Expanded(child: mapButton(_ExternalMapTarget.naver)),
              const SizedBox(width: 8),
              Expanded(child: mapButton(_ExternalMapTarget.tmap)),
            ],
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }
}
