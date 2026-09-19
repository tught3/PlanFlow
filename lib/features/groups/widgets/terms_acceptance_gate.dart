import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/safe_prefs.dart';
import '../../../core/theme.dart';
import '../../../l10n/app_l10n.dart';

/// Google Play UGC 정책 대응: 그룹(UGC) 기능 사용 전 이용약관 동의 게이트.
/// 실제 존재하는 약관 페이지만 링크한다.
const String termsOfServiceUrl = 'https://fluxstudio.co.kr/terms';
const String termsAcceptedUrlKey = 'terms_accepted_url';
const String termsAcceptedAtKey = 'terms_accepted_at';

bool isTermsAccepted(SharedPreferences? prefs) {
  return prefs?.getString(termsAcceptedUrlKey) == termsOfServiceUrl;
}

Future<void> saveTermsAcceptance(SharedPreferences? prefs) async {
  final effective = prefs ?? await tryGetPrefs();
  if (effective == null) return;
  await effective.setString(termsAcceptedUrlKey, termsOfServiceUrl);
  await effective.setString(termsAcceptedAtKey, DateTime.now().toIso8601String());
}

/// 동의가 필요하면 바텀시트를 띄운다.
/// 반환값: true = 동의됨 또는 게이트 불필요, false = "나중에"(기능 진입 취소).
Future<bool> showTermsAcceptanceGate(
  BuildContext context, {
  SharedPreferences? preferences,
}) async {
  final prefs = preferences ?? await tryGetPrefs();
  // ponytail: prefs를 아예 못 읽는 일시적 환경에서는 fail-open(SafePrefs 방침 동일).
  if (prefs == null) return true;
  if (isTermsAccepted(prefs)) return true;
  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted) return false;
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => const TermsAcceptanceSheet(),
  );
  if (accepted == true) {
    await saveTermsAcceptance(prefs);
  }
  return accepted == true;
}

class TermsAcceptanceSheet extends StatelessWidget {
  const TermsAcceptanceSheet({super.key, this.launchUrlFn});

  final Future<bool> Function(Uri uri)? launchUrlFn;

  @override
  Widget build(BuildContext context) {
    final l10n = appL10n(context);
    final launcher = launchUrlFn ??
        (Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.termsGateTitle,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.termsGateBody,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('terms-gate-view-terms'),
                onPressed: () => launcher(Uri.parse(termsOfServiceUrl)),
                child: Text(l10n.termsGateViewTerms),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const ValueKey('terms-gate-accept'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.termsGateAccept),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const ValueKey('terms-gate-later'),
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.termsGateLater),
            ),
          ],
        ),
      ),
    );
  }
}
