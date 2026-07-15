import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants.dart';
import '../core/env.dart';
import '../core/theme.dart';
import '../data/repositories/event_repository.dart';
import '../services/departure_alarm_service.dart';
import '../services/pending_departure_store.dart';
import '../widgets/planflow_action_buttons.dart';

/// 출발 전용 알람 화면.
///
/// 사용자가 "출발" 버튼을 탭하면 알람을 완료 처리하고 홈으로 돌아간다.
/// "닫기" 버튼은 알람을 실행하지 않고 홈으로 돌아간다.
class DepartureAlarmScreen extends StatefulWidget {
  const DepartureAlarmScreen({
    super.key,
    required this.eventId,
    this.initialTitle,
    this.travelMinutes,
    this.departureAlarmService = const DepartureAlarmService(),
    this.pendingStore = const SharedPreferencesPendingDepartureStore(),
    this.eventRepository,
  });

  /// 출발할 일정의 ID (필수)
  final String eventId;

  /// 일정 제목 (옵션, 없으면 초기값 표시)
  final String? initialTitle;

  /// 이동 예상 시간(분) (옵션)
  final int? travelMinutes;

  /// 알람 처리 서비스 (의존성 주입용, 기본값: DepartureAlarmService)
  final DepartureAlarmService departureAlarmService;

  /// 보류 상태 저장소 (의존성 주입용)
  final PendingDepartureStore pendingStore;

  /// 일정 정보 조회 레포 (의존성 주입용, 기본값: Supabase)
  final EventRepository? eventRepository;

  @override
  State<DepartureAlarmScreen> createState() => _DepartureAlarmScreenState();
}

class _DepartureAlarmScreenState extends State<DepartureAlarmScreen> {
  late String _title;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _title = widget.initialTitle ?? '지금 출발하세요';
    _loadEventTitle();
  }

  /// eventId가 유효하면 최신 일정명을 조회한다.
  /// 실패해도 기본값을 유지하고 진행한다.
  Future<void> _loadEventTitle() async {
    if (widget.eventId.trim().isEmpty) {
      return;
    }

    if (!AppEnv.isSupabaseReady) {
      return;
    }

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      return;
    }

    try {
      final repo = widget.eventRepository ?? EventRepository.supabase();
      final event = await repo.fetchEvent(
        widget.eventId,
        userId: user.id,
      );
      if (!mounted) {
        return;
      }
      if (event != null && event.title.isNotEmpty) {
        setState(() {
          _title = event.title;
        });
      }
    } catch (_) {
      // best-effort: 조회 실패해도 무시하고 기본값 사용
    }
  }

  /// "출발" 버튼 처리
  Future<void> _handleDeparture() async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
    });

    try {
      // 알람을 완료 처리
      await widget.departureAlarmService.acknowledgeDeparture(widget.eventId);

      if (!mounted) return;

      // 보류 상태 삭제
      await widget.pendingStore.clear();

      if (!mounted) return;

      // 홈으로 이동
      context.go(AppRoutes.home);
    } catch (_) {
      // 예외는 조용히 무시하고 상태만 복구
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  /// "닫기" 버튼 처리
  Future<void> _handleClose() async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
    });

    try {
      // 알람 처리 없이 보류 상태만 삭제
      await widget.pendingStore.clear();

      if (!mounted) return;

      // 홈으로 이동 (뒤로 가기 우선)
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(AppRoutes.home);
      }
    } catch (_) {
      // 예외는 조용히 무시
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // eventId가 공백이면 홈으로 리다이렉트
    if (widget.eventId.trim().isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.go(AppRoutes.home);
        }
      });
      return const Scaffold(body: SizedBox.expand());
    }

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            children: [
              const Spacer(),
              // 아이콘
              Icon(
                Icons.directions_car,
                size: 72,
                color: PlanFlowColors.primary,
              ),
              const SizedBox(height: 24),

              // 제목 (크게)
              Text(
                _title,
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: PlanFlowColors.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),

              // 이동 시간 (옵션)
              if (widget.travelMinutes != null)
                Text(
                  '약 ${widget.travelMinutes}분',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
                ),

              const Spacer(),

              // 버튼
              PlanFlowActionButtons(
                buttons: [
                  PlanFlowActionButton(
                    label: '닫기',
                    onPressed: _isProcessing ? null : _handleClose,
                    type: ActionButtonType.secondary,
                    buttonKey: const Key('departure_alarm_close_button'),
                    flex: 1,
                  ),
                  PlanFlowActionButton(
                    label: '출발',
                    onPressed: _isProcessing ? null : _handleDeparture,
                    type: ActionButtonType.primary,
                    buttonKey: const Key('departure_alarm_go_button'),
                    flex: 1,
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
