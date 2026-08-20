import 'package:flutter/material.dart';

import '../core/theme.dart';

const Key voiceConversationExamplesPanelKey =
    ValueKey('voiceConversationExamplesPanel');
const Key voiceConversationIntroTextKey =
    ValueKey('voiceConversationIntroText');
const Key voiceConversationAdStageListKey =
    ValueKey('voiceConversationAdStageList');
const Key voiceConversationAdDiagnosticKey =
    ValueKey('voiceConversationAdDiagnostic');
const Key voiceConversationAdRetryButtonKey =
    ValueKey('voiceConversationAdRetryButton');

/// 광고 진입을 진단할 때 사용자에게 보여 주는 단계.
///
/// 이 값은 광고 SDK의 원시 오류나 식별자를 포함하지 않는다. SDK 세부 오류는
/// 게이트가 이미 정제한 [VoiceConversationAdDialogAttemptResult.diagnosticDetail]
/// 로만 표시한다.
enum VoiceConversationAdDialogStage {
  entitlement,
  remoteConfig,
  consent,
  confirmation,
  initializing,
  loading,
  showing,
  rewardVerified,
  failed,
  cancelled,
}

typedef VoiceConversationAdDialogProgress = void Function(
  VoiceConversationAdDialogStage stage,
);

typedef VoiceConversationAdDialogAttempt
    = Future<VoiceConversationAdDialogAttemptResult> Function(
  VoiceConversationAdDialogProgress reportProgress,
  int attemptNumber,
);

/// 보상 완료 시에만 완료로 표시되는 정상 단계들이다. 실패/취소 terminal
/// 단계는 이전 시도의 원인을 숨기지 않도록 절대 완료 처리하지 않는다.
const voiceConversationAdRewardCompletedStages =
    <VoiceConversationAdDialogStage>[
  VoiceConversationAdDialogStage.entitlement,
  VoiceConversationAdDialogStage.remoteConfig,
  VoiceConversationAdDialogStage.consent,
  VoiceConversationAdDialogStage.confirmation,
  VoiceConversationAdDialogStage.initializing,
  VoiceConversationAdDialogStage.loading,
  VoiceConversationAdDialogStage.showing,
  VoiceConversationAdDialogStage.rewardVerified,
];

/// 게이트가 한 번의 광고 시도를 다이얼로그에 반환하는 결과.
///
/// `rewarded`가 일반적인 승인 경로다. `freePass`는 게이트의 기존 원격 설정
/// 예외를 표현할 때만 사용되며, 다이얼로그가 별도 우회 경로를 만들지 않는다.
class VoiceConversationAdDialogAttemptResult {
  const VoiceConversationAdDialogAttemptResult._({
    required this.isAllowed,
    required this.isRewarded,
    this.diagnosticCode,
    this.diagnosticDetail,
    this.terminalStage,
  });

  const VoiceConversationAdDialogAttemptResult.rewarded()
      : this._(isAllowed: true, isRewarded: true);

  const VoiceConversationAdDialogAttemptResult.freePass()
      : this._(isAllowed: true, isRewarded: false);

  const VoiceConversationAdDialogAttemptResult.failure({
    required String diagnosticCode,
    required String diagnosticDetail,
    VoiceConversationAdDialogStage terminalStage =
        VoiceConversationAdDialogStage.failed,
  }) : this._(
          isAllowed: false,
          isRewarded: false,
          diagnosticCode: diagnosticCode,
          diagnosticDetail: diagnosticDetail,
          terminalStage: terminalStage,
        );

  final bool isAllowed;
  final bool isRewarded;
  final String? diagnosticCode;
  final String? diagnosticDetail;
  final VoiceConversationAdDialogStage? terminalStage;
}

/// 다이얼로그가 닫힐 때 게이트로 반환하는 상태.
class VoiceConversationAdDialogResult {
  const VoiceConversationAdDialogResult._({
    required this.isAllowed,
    required this.isRewarded,
    this.diagnosticCode,
  });

  const VoiceConversationAdDialogResult.cancelled()
      : this._(isAllowed: false, isRewarded: false);

  const VoiceConversationAdDialogResult.allowed({required bool rewarded})
      : this._(isAllowed: true, isRewarded: rewarded);

  const VoiceConversationAdDialogResult.failed({required String diagnosticCode})
      : this._(
          isAllowed: false,
          isRewarded: false,
          diagnosticCode: diagnosticCode,
        );

  final bool isAllowed;
  final bool isRewarded;
  final String? diagnosticCode;
}

/// 음성 대화 모드 진입 전 사용자에게 광고 시청 동의를 받는 다이얼로그.
///
/// [onStartAttempt]가 없으면 기존 확인 다이얼로그처럼 동작한다. 게이트가
/// 콜백을 전달하면, 확인·초기화·로딩·표시·보상 검증과 실패 진단을 같은
/// 다이얼로그에 유지하며 재시도는 새 콜백 호출로만 수행한다.
Future<VoiceConversationAdDialogResult> showVoiceConversationAdDialog(
  BuildContext context, {
  Set<VoiceConversationAdDialogStage> initialCompletedStages =
      const <VoiceConversationAdDialogStage>{},
  VoiceConversationAdDialogAttempt? onStartAttempt,
}) async {
  final result = await showDialog<VoiceConversationAdDialogResult>(
    context: context,
    // 시도 중에는 모달 바깥 탭이 광고 결과를 잃게 만들 수 있으므로 바깥
    // 탭으로 닫지 않는다. 명시적인 취소 버튼과 PopScope가 닫힘을 관리한다.
    barrierDismissible: false,
    builder: (dialogContext) => _VoiceConversationAdDialog(
      initialCompletedStages: initialCompletedStages,
      onStartAttempt: onStartAttempt,
    ),
  );
  return result ?? const VoiceConversationAdDialogResult.cancelled();
}

class _VoiceConversationAdDialog extends StatefulWidget {
  const _VoiceConversationAdDialog({
    required this.initialCompletedStages,
    required this.onStartAttempt,
  });

  final Set<VoiceConversationAdDialogStage> initialCompletedStages;
  final VoiceConversationAdDialogAttempt? onStartAttempt;

  @override
  State<_VoiceConversationAdDialog> createState() =>
      _VoiceConversationAdDialogState();
}

class _VoiceConversationAdDialogState
    extends State<_VoiceConversationAdDialog> {
  late final Set<VoiceConversationAdDialogStage> _completedStages =
      <VoiceConversationAdDialogStage>{...widget.initialCompletedStages};
  VoiceConversationAdDialogStage _activeStage =
      VoiceConversationAdDialogStage.confirmation;
  String? _diagnosticCode;
  String? _diagnosticDetail;
  bool _attemptInFlight = false;
  int _attemptNumber = 0;

  static const _stages = <VoiceConversationAdDialogStage>[
    VoiceConversationAdDialogStage.entitlement,
    VoiceConversationAdDialogStage.remoteConfig,
    VoiceConversationAdDialogStage.consent,
    VoiceConversationAdDialogStage.confirmation,
    VoiceConversationAdDialogStage.initializing,
    VoiceConversationAdDialogStage.loading,
    VoiceConversationAdDialogStage.showing,
    VoiceConversationAdDialogStage.rewardVerified,
    VoiceConversationAdDialogStage.failed,
    VoiceConversationAdDialogStage.cancelled,
  ];

  Future<void> _startAttempt() async {
    final attempt = widget.onStartAttempt;
    if (attempt == null || _attemptInFlight) return;

    setState(() {
      _attemptInFlight = true;
      _diagnosticCode = null;
      _diagnosticDetail = null;
      _completedStages.add(VoiceConversationAdDialogStage.confirmation);
      _activeStage = VoiceConversationAdDialogStage.remoteConfig;
    });

    final result = await attempt(_reportProgress, ++_attemptNumber);
    if (!mounted) return;

    if (result.isAllowed) {
      setState(() {
        _attemptInFlight = false;
        if (result.isRewarded) {
          _completedStages.addAll(voiceConversationAdRewardCompletedStages);
          _activeStage = VoiceConversationAdDialogStage.rewardVerified;
        }
      });
      await Future<void>.delayed(Duration.zero);
      if (mounted) {
        Navigator.of(context).pop(
          VoiceConversationAdDialogResult.allowed(rewarded: result.isRewarded),
        );
      }
      return;
    }

    setState(() {
      _attemptInFlight = false;
      _activeStage =
          result.terminalStage ?? VoiceConversationAdDialogStage.failed;
      _diagnosticCode = result.diagnosticCode;
      _diagnosticDetail = result.diagnosticDetail;
    });
  }

  void _reportProgress(VoiceConversationAdDialogStage stage) {
    if (!mounted) return;
    setState(() {
      if (_activeStage != stage) _completedStages.add(_activeStage);
      _activeStage = stage;
    });
  }

  void _dismiss() {
    final code = _diagnosticCode;
    Navigator.of(context).pop(
      code == null
          ? const VoiceConversationAdDialogResult.cancelled()
          : VoiceConversationAdDialogResult.failed(diagnosticCode: code),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const examples = <String>[
      '내일 오후 2시에 팀 회의 추가해줘',
      '다음 주 금요일 일정 보여줘',
      '내일 일정 오후 5시 반으로 미뤄줘',
      '첫 번째 일정 장소를 본관 3층으로 바꿔줘',
      '첫 번째 일정 삭제해줘',
      '매주 월요일 오전 9시에 운동 일정 추가해줘',
    ];

    final diagnosticVisible = _diagnosticCode != null;
    final startLabel = diagnosticVisible ? '다시 시도' : '광고 보고 시작하기';

    return PopScope(
      canPop: !_attemptInFlight,
      child: AlertDialog(
        icon: Icon(
          Icons.record_voice_over_outlined,
          color: PlanFlowColors.primaryMid,
          size: 32,
        ),
        title: const Text('대화 모드'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '짧은 광고를 시청하면 AI와 대화하며 일정을 관리할 수 있어요.',
                key: voiceConversationIntroTextKey,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: PlanFlowColors.textSecondary,
                  fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) + 2,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                key: voiceConversationExamplesPanelKey,
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: PlanFlowColors.primaryFaint,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '이렇게 말해보세요',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.primaryMid,
                        fontSize:
                            (theme.textTheme.bodySmall?.fontSize ?? 12) + 2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final example in examples) ...[
                      Text(
                        '• $example',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: PlanFlowColors.primaryMid,
                          fontSize:
                              (theme.textTheme.bodySmall?.fontSize ?? 12) + 2,
                        ),
                      ),
                      if (example != examples.last) const SizedBox(height: 4),
                    ],
                  ],
                ),
              ),
              if (widget.onStartAttempt != null) ...[
                const SizedBox(height: 16),
                _buildStageList(theme),
              ],
              if (diagnosticVisible) ...[
                const SizedBox(height: 12),
                Container(
                  key: voiceConversationAdDiagnosticKey,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '실패 원인: $_diagnosticCode\n${_diagnosticDetail ?? ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _attemptInFlight ? null : _dismiss,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: PlanFlowColors.textSecondary,
                    side: const BorderSide(color: PlanFlowColors.primaryFaint),
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: const Text('취소'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  key: diagnosticVisible
                      ? voiceConversationAdRetryButtonKey
                      : null,
                  onPressed: widget.onStartAttempt == null
                      ? () => Navigator.of(context).pop(
                            const VoiceConversationAdDialogResult.allowed(
                              rewarded: false,
                            ),
                          )
                      : (_attemptInFlight ? null : _startAttempt),
                  icon: _attemptInFlight
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_circle_outline, size: 18),
                  label: Text(startLabel),
                  style: FilledButton.styleFrom(
                    backgroundColor: PlanFlowColors.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(44),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStageList(ThemeData theme) {
    return Column(
      key: voiceConversationAdStageListKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('광고 진단 단계', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        for (final stage in _stages)
          _buildStageRow(theme, stage, _stageLabel(stage)),
      ],
    );
  }

  Widget _buildStageRow(
    ThemeData theme,
    VoiceConversationAdDialogStage stage,
    String label,
  ) {
    final completed = _completedStages.contains(stage);
    final active = _activeStage == stage;
    final color = completed || active
        ? PlanFlowColors.primaryMid
        : PlanFlowColors.textSecondary;
    return Padding(
      key: ValueKey('voiceConversationAdStage-${stage.name}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            completed
                ? Icons.check_circle
                : active
                    ? Icons.pending_outlined
                    : Icons.radio_button_unchecked,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(label, style: theme.textTheme.bodySmall?.copyWith(color: color)),
        ],
      ),
    );
  }
}

String _stageLabel(VoiceConversationAdDialogStage stage) {
  switch (stage) {
    case VoiceConversationAdDialogStage.entitlement:
      return '무료 사용 권한 확인';
    case VoiceConversationAdDialogStage.remoteConfig:
      return '광고 설정 확인';
    case VoiceConversationAdDialogStage.consent:
      return '광고 동의 확인';
    case VoiceConversationAdDialogStage.confirmation:
      return '광고 시청 확인';
    case VoiceConversationAdDialogStage.initializing:
      return '광고 초기화';
    case VoiceConversationAdDialogStage.loading:
      return '광고 불러오기';
    case VoiceConversationAdDialogStage.showing:
      return '광고 표시';
    case VoiceConversationAdDialogStage.rewardVerified:
      return '보상 확인';
    case VoiceConversationAdDialogStage.failed:
      return '광고 처리 실패';
    case VoiceConversationAdDialogStage.cancelled:
      return '광고 시청 취소';
  }
}
