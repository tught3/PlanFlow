import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../data/repositories/feedback_repository.dart';
import '../../providers/auth_provider.dart';
import '../../services/briefing_scheduler_service.dart';
import '../settings/beta_survey_sheet.dart';

class BriefingLaunchScreen extends StatefulWidget {
  const BriefingLaunchScreen({
    super.key,
    required this.isMorning,
    this.briefingSchedulerService,
    this.authProviderOverride,
  });

  final bool isMorning;
  final BriefingSchedulerService? briefingSchedulerService;
  final AuthProvider? authProviderOverride;

  @override
  State<BriefingLaunchScreen> createState() => _BriefingLaunchScreenState();
}

class _BriefingLaunchScreenState extends State<BriefingLaunchScreen> {
  late final BriefingSchedulerService _briefingSchedulerService;
  late final AuthProvider _authProvider;
  BriefingExecutionResult? _result;
  String? _errorMessage;
  bool _isCheckingSession = true;
  bool _showSurveyButton = false;

  static const String _surveyCompletedKey = 'beta_survey_completed';

  @override
  void initState() {
    super.initState();
    _briefingSchedulerService =
        widget.briefingSchedulerService ?? BriefingSchedulerService();
    _authProvider = widget.authProviderOverride ?? authProvider;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runBriefing();
    });
  }

  Future<void> _runBriefing() async {
    try {
      final userId = await _resolveUserIdForBriefing();
      if (!mounted) {
        return;
      }
      final requiresAuth =
          AppEnv.isSupabaseReady || widget.authProviderOverride != null;
      if (requiresAuth && (userId == null || userId.isEmpty)) {
        setState(() {
          _isCheckingSession = false;
          _errorMessage = '로그인 세션을 다시 확인해야 브리핑을 실행할 수 있습니다.';
        });
        return;
      }
      setState(() {
        _isCheckingSession = false;
      });
      final result = await _briefingSchedulerService.executeBriefing(
        isMorning: widget.isMorning,
        userId: userId,
        isManualTrigger: true,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _result = result;
      });
      if (!widget.isMorning && result.delivered) {
        await _checkShouldShowSurvey();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isCheckingSession = false;
        _errorMessage = '브리핑을 시작하지 못했습니다. 잠시 후 다시 시도해 주세요.';
      });
    }
  }

  Future<void> _checkShouldShowSurvey() async {
    final prefs = await SharedPreferences.getInstance();
    final completed = prefs.getBool(_surveyCompletedKey) ?? false;
    if (!mounted || completed) return;
    setState(() => _showSurveyButton = true);
  }

  Future<void> _openSurvey() async {
    FeedbackRepository repository;
    try {
      repository = FeedbackRepository.supabase();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => BetaSurveySheet(repository: repository),
    );
    if (submitted == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_surveyCompletedKey, true);
      if (mounted) setState(() => _showSurveyButton = false);
    }
  }

  Future<String?> _resolveUserIdForBriefing() async {
    if (!AppEnv.isSupabaseReady && widget.authProviderOverride == null) {
      return null;
    }
    await _authProvider.waitForInitialSessionResolution();
    if (!_authProvider.isSignedIn) {
      await _authProvider.syncCurrentSession();
    }
    final providerUserId = _authProvider.userId?.trim();
    if (providerUserId != null && providerUserId.isNotEmpty) {
      return providerUserId;
    }
    if (widget.authProviderOverride != null) {
      return null;
    }
    final supabaseUserId = Supabase.instance.client.auth.currentUser?.id.trim();
    if (supabaseUserId != null && supabaseUserId.isNotEmpty) {
      return supabaseUserId;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.isMorning ? '모닝 브리핑' : '이브닝 브리핑';
    final result = _result;

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          child: Center(
            child: Card(
              elevation: 0,
              color: PlanFlowColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: const BorderSide(
                  color: PlanFlowColors.primaryFaint,
                  width: 0.8,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      result == null && _errorMessage == null
                          ? Icons.record_voice_over_outlined
                          : result?.delivered == true
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                      size: 42,
                      color: result?.delivered == true
                          ? PlanFlowColors.primary
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      result == null && _errorMessage == null
                          ? _isCheckingSession
                              ? '로그인 세션을 확인하고 있어요.'
                              : '$title을 준비하고 있어요.'
                          : result?.message ?? _errorMessage!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: PlanFlowColors.textPrimary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      result == null && _errorMessage == null
                          ? _isCheckingSession
                              ? '브리핑을 실행하기 전에 저장된 로그인 정보를 조용히 복구합니다.'
                              : '오늘/내일 일정을 시간순으로 정리한 뒤 음성으로 읽어드립니다.'
                          : '홈으로 돌아가 일정을 다시 확인할 수 있어요.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (_showSurveyButton) ...[
                      OutlinedButton.icon(
                        onPressed: _openSurvey,
                        icon: const Icon(Icons.star_border_outlined),
                        label: const Text('오늘 하루 어떠셨나요? 후기 남기기'),
                      ),
                      const SizedBox(height: 8),
                    ],
                    FilledButton(
                      onPressed: () => context.go(AppRoutes.home),
                      child: const Text('홈으로 가기'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
