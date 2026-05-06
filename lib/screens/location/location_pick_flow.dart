import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/env.dart';
import '../../core/theme.dart';
import '../../services/location_lookup_service.dart';
import 'location_picker_screen.dart';

Future<LocationLookupResult?> pickLocationFromQuery({
  required BuildContext context,
  required String query,
  LocationLookupService? locationLookupService,
}) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) {
    await showLocationMessage(context, '장소를 먼저 입력해 주세요.');
    return null;
  }

  final service = locationLookupService ?? LocationLookupService();
  try {
    final results = await service.search(trimmed).timeout(
          const Duration(seconds: 12),
        );
    if (!context.mounted) {
      return null;
    }

    if (results.isEmpty) {
      await showExternalMapOptions(
        context,
        trimmed,
        message: '앱 안에서 장소 후보를 찾지 못했어요. 외부 지도에서 먼저 확인해 보세요.',
      );
      return null;
    }

    if (AppEnv.isNaverMapReady || AppEnv.googleMapsApiKey.trim().isNotEmpty) {
      return Navigator.of(context).push<LocationLookupResult>(
        MaterialPageRoute(
          builder: (_) => LocationPickerScreen(
            initialQuery: trimmed,
            initialResults: results,
            locationLookupService: service,
          ),
        ),
      );
    }

    return showLocationCandidateSheet(context, trimmed, results);
  } on LocationLookupException catch (error) {
    if (!context.mounted) {
      return null;
    }
    final provider = error.provider.providerLabel;
    await showExternalMapOptions(
      context,
      trimmed,
      message: '$provider 장소 검색 인증에 실패했어요. 해당 API 권한과 키 제한을 확인해 주세요.',
    );
    return null;
  } catch (error) {
    if (!context.mounted) {
      return null;
    }
    debugPrint('Location pick flow failed: $error');
    await showExternalMapOptions(
      context,
      trimmed,
      message: '장소 검색이 오래 걸리거나 실패했어요. 외부 지도에서 먼저 확인해 보세요.',
    );
    return null;
  }
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
  final selected = await showModalBottomSheet<_ExternalMapTarget>(
    context: context,
    showDragHandle: true,
    builder: (context) => _ExternalMapSheet(query: query, message: message),
  );
  if (!context.mounted || selected == null) {
    return;
  }
  final launched = await launchUrl(
    selected.uri(query),
    mode: LaunchMode.externalApplication,
  );
  if (!launched && context.mounted) {
    await showLocationMessage(
      context,
      '${selected.label}를 열지 못했어요. 앱 설치 또는 브라우저 연결을 확인해 주세요.',
    );
  }
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
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
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
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final target in _ExternalMapTarget.values)
                  ActionChip(
                    avatar: const Icon(Icons.map_outlined, size: 18),
                    label: Text(target.label),
                    onPressed: () => Navigator.of(context).pop(target),
                  ),
              ],
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
