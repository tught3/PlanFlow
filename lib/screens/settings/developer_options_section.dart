import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme.dart';

/// 3개 토글(Developer Mode / Verbose Logging / Experimental Features)을 제공하는
/// 개발자 옵션 섹션 위젯.
///
/// settings_screen.dart의 private [_SectionCard]과 동일 시각 스타일을 유지하기 위해
/// 파일 내부에 [_DevSectionCard]를 별도 정의합니다.
class DeveloperOptionsSection extends StatefulWidget {
  const DeveloperOptionsSection({super.key});

  @override
  State<DeveloperOptionsSection> createState() => _DeveloperOptionsSectionState();
}

class _DeveloperOptionsSectionState extends State<DeveloperOptionsSection> {
  // ── SharedPreferences 키 ──────────────────────────────────────────────
  static const String _kDevModeEnabled = 'dev_mode_enabled';
  static const String _kVerboseLoggingEnabled = 'verbose_logging_enabled';
  static const String _kExperimentalFeaturesEnabled =
      'experimental_features_enabled';

  // ── 토글 상태 ──────────────────────────────────────────────────────────
  bool _devModeEnabled = false;
  bool _verboseLoggingEnabled = false;
  bool _experimentalFeaturesEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _devModeEnabled = prefs.getBool(_kDevModeEnabled) ?? false;
      _verboseLoggingEnabled = prefs.getBool(_kVerboseLoggingEnabled) ?? false;
      _experimentalFeaturesEnabled =
          prefs.getBool(_kExperimentalFeaturesEnabled) ?? false;
    });
  }

  Future<void> _onDevModeChanged(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDevModeEnabled, value);
    if (!mounted) return;
    setState(() => _devModeEnabled = value);
  }

  Future<void> _onVerboseLoggingChanged(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kVerboseLoggingEnabled, value);
    if (!mounted) return;
    setState(() => _verboseLoggingEnabled = value);
  }

  Future<void> _onExperimentalFeaturesChanged(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kExperimentalFeaturesEnabled, value);
    if (!mounted) return;
    setState(() => _experimentalFeaturesEnabled = value);
  }

  @override
  Widget build(BuildContext context) {
    return _DevSectionCard(
      title: '개발자 옵션',
      subtitle: '디버깅 및 실험적 기능을 제어합니다.',
      child: Column(
        children: [
          SwitchListTile.adaptive(
            key: const ValueKey('settings-dev-mode-enabled'),
            contentPadding: EdgeInsets.zero,
            value: _devModeEnabled,
            activeThumbColor: PlanFlowColors.primary,
            activeTrackColor: PlanFlowColors.primaryFaint,
            title: const Text('Developer Mode'),
            subtitle: const Text(
              '숨겨진 디버그 정보와 개발자 메뉴를 활성화합니다.',
            ),
            onChanged: _onDevModeChanged,
          ),
          const Divider(height: 1),
          SwitchListTile.adaptive(
            key: const ValueKey('settings-verbose-logging-enabled'),
            contentPadding: EdgeInsets.zero,
            value: _verboseLoggingEnabled,
            activeThumbColor: PlanFlowColors.primary,
            activeTrackColor: PlanFlowColors.primaryFaint,
            title: const Text('Verbose Logging'),
            subtitle: const Text(
              '모든 네트워크 요청과 내부 동작을 상세 로그에 기록합니다.',
            ),
            onChanged: _onVerboseLoggingChanged,
          ),
          const Divider(height: 1),
          SwitchListTile.adaptive(
            key: const ValueKey('settings-experimental-features-enabled'),
            contentPadding: EdgeInsets.zero,
            value: _experimentalFeaturesEnabled,
            activeThumbColor: PlanFlowColors.primary,
            activeTrackColor: PlanFlowColors.primaryFaint,
            title: const Text('Experimental Features'),
            subtitle: const Text(
              '아직 공개 전인 실험적 기능을 미리 사용할 수 있습니다.',
            ),
            onChanged: _onExperimentalFeaturesChanged,
          ),
        ],
      ),
    );
  }
}

// ── private 섹션 카드 ────────────────────────────────────────────────────
// settings_screen.dart의 private _SectionCard과 완전 동일한 시각 스타일.
class _DevSectionCard extends StatelessWidget {
  const _DevSectionCard({
    required this.title,
    required this.child,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;

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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                color: PlanFlowColors.primary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}
