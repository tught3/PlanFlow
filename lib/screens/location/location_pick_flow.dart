import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../services/location_lookup_service.dart';
import 'location_picker_screen.dart';

Future<LocationLookupResult?> pickLocationFromQuery({
  required BuildContext context,
  required String query,
  LocationLookupService? locationLookupService,
}) async {
  final trimmed = query.trim();

  final service = locationLookupService ?? LocationLookupService();
  if (trimmed.isEmpty) {
    return Navigator.of(context).push<LocationLookupResult>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialQuery: '',
          locationLookupService: service,
        ),
      ),
    );
  }

  try {
    final results = await service.search(trimmed).timeout(
          const Duration(seconds: 12),
        );
    if (!context.mounted) {
      return null;
    }

    if (results.isEmpty) {
      return Navigator.of(context).push<LocationLookupResult>(
        MaterialPageRoute(
          builder: (_) => LocationPickerScreen(
            initialQuery: trimmed,
            initialResults: const <LocationLookupResult>[],
            initialMessage: '검색 결과가 없어요. 지도에서 직접 위치를 선택해 주세요.',
            locationLookupService: service,
          ),
        ),
      );
    }

    return Navigator.of(context).push<LocationLookupResult>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialQuery: trimmed,
          initialResults: results,
          locationLookupService: service,
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
          initialMessage: '$provider 장소 검색 인증에 실패했어요. 지도에서 직접 위치를 선택해 주세요.',
          locationLookupService: service,
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
          initialMessage: '장소 검색이 오래 걸리거나 실패했어요. 지도에서 직접 위치를 선택해 주세요.',
          locationLookupService: service,
        ),
      ),
    );
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
