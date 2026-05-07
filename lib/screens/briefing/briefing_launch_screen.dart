import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../services/briefing_scheduler_service.dart';

class BriefingLaunchScreen extends StatefulWidget {
  const BriefingLaunchScreen({
    super.key,
    required this.isMorning,
    this.briefingSchedulerService,
  });

  final bool isMorning;
  final BriefingSchedulerService? briefingSchedulerService;

  @override
  State<BriefingLaunchScreen> createState() => _BriefingLaunchScreenState();
}

class _BriefingLaunchScreenState extends State<BriefingLaunchScreen> {
  late final BriefingSchedulerService _briefingSchedulerService;
  BriefingExecutionResult? _result;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _briefingSchedulerService =
        widget.briefingSchedulerService ?? BriefingSchedulerService();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runBriefing();
    });
  }

  Future<void> _runBriefing() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id.trim();
      final result = await _briefingSchedulerService.executeBriefing(
        isMorning: widget.isMorning,
        userId: userId == null || userId.isEmpty ? null : userId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _result = result;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = '브리핑을 시작하지 못했습니다. 잠시 후 다시 시도해 주세요.';
      });
    }
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
                          ? '$title을 준비하고 있어요.'
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
                          ? '오늘/내일 일정을 시간순으로 정리한 뒤 음성으로 읽어드립니다.'
                          : '홈으로 돌아가 일정을 다시 확인할 수 있어요.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 18),
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
