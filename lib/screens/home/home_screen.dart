import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../data/repositories/early_bird_email_repository.dart';
import '../../services/event_refresh_bus.dart';
import '../../widgets/planflow_voice_fab.dart';

enum _HomeLoadState {
  loading,
  ready,
  supabaseMissing,
  signedOut,
  error,
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.scrollController,
  });

  final ScrollController? scrollController;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<EventModel> _todayEvents = const <EventModel>[];
  List<EventModel> _upcomingEvents = const <EventModel>[];
  _HomeLoadState _loadState = _HomeLoadState.loading;
  String? _loadMessage;

  @override
  void initState() {
    super.initState();
    EventRefreshBus.instance.latest.addListener(_handleEventRefresh);
    _loadTodayEvents();
  }

  @override
  void dispose() {
    EventRefreshBus.instance.latest.removeListener(_handleEventRefresh);
    super.dispose();
  }

  void _handleEventRefresh() {
    _loadTodayEvents();
  }

  Future<void> _loadTodayEvents() async {
    if (mounted) {
      setState(() {
        _loadState = _HomeLoadState.loading;
        _loadMessage = null;
      });
    }

    if (!AppEnv.isSupabaseReady) {
      if (mounted) {
        setState(() {
          _todayEvents = const <EventModel>[];
          _upcomingEvents = const <EventModel>[];
          _loadState = _HomeLoadState.supabaseMissing;
        });
      }
      return;
    }
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() {
          _todayEvents = const <EventModel>[];
          _upcomingEvents = const <EventModel>[];
          _loadState = _HomeLoadState.signedOut;
        });
      }
      return;
    }

    try {
      final repository = EventRepository.supabase();
      final allEvents = await repository.listEvents(userId: user.id);
      final now = DateTime.now();
      final todayEvents = allEvents.where((event) {
        final startAt = event.startAt;
        if (startAt == null) {
          return false;
        }
        return startAt.year == now.year &&
            startAt.month == now.month &&
            startAt.day == now.day;
      }).toList(growable: false)
        ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
      final upcomingEvents = allEvents.where((event) {
        final startAt = event.startAt;
        return startAt != null &&
            !startAt.isBefore(now) &&
            !_isSameDate(startAt, now);
      }).toList(growable: false)
        ..sort((a, b) => a.startAt!.compareTo(b.startAt!));

      if (mounted) {
        setState(() {
          _todayEvents = todayEvents;
          _upcomingEvents = upcomingEvents.take(3).toList(growable: false);
          _loadState = _HomeLoadState.ready;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _todayEvents = const <EventModel>[];
          _upcomingEvents = const <EventModel>[];
          _loadState = _HomeLoadState.error;
          _loadMessage = '오늘 일정을 불러오지 못했어요. 새로고침해 주세요.';
        });
      }
      debugPrint('HomeScreen load failed: $error');
    } finally {
      // Loading state is replaced by one of the terminal states above.
    }
  }

  @override
  Widget build(BuildContext context) {
    final todayLabel = _koreanDateLabel(DateTime.now());
    final theme = Theme.of(context);
    final isLoading = _loadState == _HomeLoadState.loading;

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: 96,
        titleSpacing: AppConstants.defaultPadding,
        backgroundColor: PlanFlowColors.background,
        surfaceTintColor: Colors.transparent,
        title: _HomeHeader(onVoice: () => context.push(AppRoutes.voice)),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: isLoading ? null : _loadTodayEvents,
            icon: isLoading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Container(
          width: double.infinity,
          height: double.infinity,
          color: PlanFlowColors.background,
          child: RefreshIndicator(
            onRefresh: _loadTodayEvents,
            child: SingleChildScrollView(
              controller: widget.scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                AppConstants.defaultPadding,
                12,
                AppConstants.defaultPadding,
                96,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: PlanFlowColors.primaryMid,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: PlanFlowColors.primary.withValues(alpha: 0.16),
                          blurRadius: 18,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          todayLabel,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: PlanFlowColors.briefingLabel,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _todayEvents.isEmpty
                              ? '오늘은 여유로운\n하루예요 😊'
                              : '오늘 ${_todayEvents.length}개의\n일정이 있어요',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: Colors.white,
                            fontSize: 25,
                            fontWeight: FontWeight.w900,
                            height: 1.18,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                _todayEvents.isEmpty ? '일정 없음' : '브리핑 준비 완료',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            Icon(
                              _todayEvents.isEmpty
                                  ? Icons.wb_sunny_outlined
                                  : Icons.event_note,
                              color: Colors.white,
                              size: 20,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: PlanFlowColors.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: PlanFlowColors.primaryFaint,
                        width: 0.8,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '빠른 실행',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: PlanFlowColors.primary,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: () => context.push(AppRoutes.voice),
                              icon: const Icon(Icons.mic_none, size: 18),
                              label: const Text('음성으로 일정 추가'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => context.go(AppRoutes.calendar),
                              icon: const Icon(
                                Icons.event_note_outlined,
                                size: 18,
                              ),
                              label: const Text('일정 보기'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '음성으로 일정을 만들고 캘린더에서 바로 확인할 수 있어요.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: PlanFlowColors.textSecondary,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (isLoading)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  else if (_loadState != _HomeLoadState.ready) ...[
                    _HomeStatusCard(
                      state: _loadState,
                      message: _loadMessage,
                      onRefresh: _loadTodayEvents,
                    ),
                    const SizedBox(height: 12),
                  ] else if (_todayEvents.isNotEmpty) ...[
                    Text(
                      '오늘 일정',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ..._todayEvents.map(
                      (event) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _TodayEventCard(
                          event: event,
                          onTap: () => context.push(
                            '${AppRoutes.eventDetail}/${Uri.encodeComponent(event.id)}',
                            extra: event,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ] else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: PlanFlowColors.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: PlanFlowColors.primaryFaint,
                          width: 0.8,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: PlanFlowColors.primaryFaint,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(
                              Icons.calendar_month_outlined,
                              color: PlanFlowColors.primaryMid,
                              size: 26,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '오늘 일정 안내',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: PlanFlowColors.primary,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '등록된 일정이 없어도 괜찮아요. 새 일정이 생기면 준비물과 알림을 함께 정리해 드릴게요.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: PlanFlowColors.textSecondary,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_loadState == _HomeLoadState.ready &&
                      _upcomingEvents.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      '다가오는 일정',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ..._upcomingEvents.map(
                      (event) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _UpcomingEventCard(
                          event: event,
                          onTap: () => context.push(
                            '${AppRoutes.eventDetail}/${Uri.encodeComponent(event.id)}',
                            extra: event,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const _EarlyBirdBanner(),
                ],
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: PlanFlowVoiceFab(
        onPressed: () => context.push(AppRoutes.voice),
      ),
    );
  }

  bool _isSameDate(DateTime first, DateTime second) {
    return first.year == second.year &&
        first.month == second.month &&
        first.day == second.day;
  }

  String _koreanDateLabel(DateTime value) {
    const weekdays = <int, String>{
      DateTime.monday: '월요일',
      DateTime.tuesday: '화요일',
      DateTime.wednesday: '수요일',
      DateTime.thursday: '목요일',
      DateTime.friday: '금요일',
      DateTime.saturday: '토요일',
      DateTime.sunday: '일요일',
    };
    return '${value.month}월 ${value.day}일 ${weekdays[value.weekday]}';
  }
}

class _HomeStatusCard extends StatelessWidget {
  const _HomeStatusCard({
    required this.state,
    required this.onRefresh,
    this.message,
  });

  final _HomeLoadState state;
  final VoidCallback onRefresh;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, title, body) = switch (state) {
      _HomeLoadState.supabaseMissing => (
          Icons.cloud_off_outlined,
          'Supabase 설정이 필요해요',
          '환경값이 없어서 오늘 일정을 불러올 수 없어요.',
        ),
      _HomeLoadState.signedOut => (
          Icons.lock_outline,
          '로그인이 필요해요',
          '로그인한 뒤 내 일정을 다시 불러올 수 있어요.',
        ),
      _HomeLoadState.error => (
          Icons.error_outline,
          '일정 불러오기 실패',
          message ?? '오늘 일정을 불러오지 못했습니다.',
        ),
      _HomeLoadState.loading => (
          Icons.hourglass_top_outlined,
          '일정 확인 중',
          '잠시만 기다려 주세요.',
        ),
      _HomeLoadState.ready => (
          Icons.check_circle_outline,
          '정상',
          '오늘 일정을 불러왔어요.',
        ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: PlanFlowColors.primaryFaint,
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: PlanFlowColors.primaryMid),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('새로고침'),
          ),
        ],
      ),
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({required this.onVoice});

  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
    final todayLabel = _koreanDateLabel(DateTime.now());

    return Row(
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'PlanFlow',
                style: TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.w900,
                  color: PlanFlowColors.primaryMid,
                  letterSpacing: -1.2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                todayLabel,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: PlanFlowColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '음성 입력',
          onPressed: onVoice,
          icon: const Icon(
            Icons.mic_none,
            size: 34,
            color: PlanFlowColors.primary,
          ),
        ),
      ],
    );
  }

  String _koreanDateLabel(DateTime value) {
    const weekdays = <int, String>{
      DateTime.monday: '월요일',
      DateTime.tuesday: '화요일',
      DateTime.wednesday: '수요일',
      DateTime.thursday: '목요일',
      DateTime.friday: '금요일',
      DateTime.saturday: '토요일',
      DateTime.sunday: '일요일',
    };
    return '${value.month}월 ${value.day}일 ${weekdays[value.weekday]}';
  }
}

// --- Today Event Card ---
class _TodayEventCard extends StatelessWidget {
  const _TodayEventCard({
    required this.event,
    this.onTap,
  });

  final EventModel event;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final startAt = event.startAt;
    final timeStr = startAt != null
        ? '${startAt.hour.toString().padLeft(2, '0')}:${startAt.minute.toString().padLeft(2, '0')}'
        : '';

    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: event.isCritical
              ? const Color(0xFFB42318).withValues(alpha: 0.4)
              : PlanFlowColors.primaryFaint,
          width: event.isCritical ? 1.5 : 0.5,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: event.isCritical
                      ? const Color(0xFFFFE3DD)
                      : PlanFlowColors.primaryFaint,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text(
                    timeStr,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: event.isCritical
                          ? const Color(0xFFB42318)
                          : PlanFlowColors.primaryMid,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (event.location != null)
                      Text(
                        event.location!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (event.supplies.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.backpack_outlined,
                    size: 16,
                    color: PlanFlowColors.primaryMid,
                  ),
                ),
              const SizedBox(width: 4),
              const Icon(
                Icons.chevron_right,
                color: PlanFlowColors.primaryMid,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UpcomingEventCard extends StatelessWidget {
  const _UpcomingEventCard({
    required this.event,
    this.onTap,
  });

  final EventModel event;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final startAt = event.startAt;
    final dateLabel = startAt == null ? '시간 미정' : _formatDateTime(startAt);

    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: event.isCritical
              ? const Color(0xFFB42318).withValues(alpha: 0.4)
              : PlanFlowColors.primaryFaint,
          width: event.isCritical ? 1.5 : 0.5,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: event.isCritical
                      ? const Color(0xFFFFE3DD)
                      : PlanFlowColors.primaryFaint,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  event.isCritical
                      ? Icons.priority_high
                      : Icons.schedule_outlined,
                  color: event.isCritical
                      ? const Color(0xFFB42318)
                      : PlanFlowColors.primaryMid,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dateLabel,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: PlanFlowColors.primaryMid,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      event.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (event.location != null)
                      Text(
                        event.location!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.chevron_right,
                color: PlanFlowColors.primaryMid,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDateTime(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$month/$day $hour:$minute';
  }
}

// --- Early Bird Banner ---
class _EarlyBirdBanner extends StatefulWidget {
  const _EarlyBirdBanner();

  @override
  State<_EarlyBirdBanner> createState() => _EarlyBirdBannerState();
}

class _EarlyBirdBannerState extends State<_EarlyBirdBanner> {
  final _emailController = TextEditingController();
  bool _isSubmitting = false;
  bool _isSubmitted = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('올바른 이메일을 입력해 주세요.')),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      if (!AppEnv.isSupabaseReady) {
        throw StateError('Supabase is not configured.');
      }

      final repository = EarlyBirdEmailRepository.supabase();
      await repository.saveEmail(email);

      if (mounted) {
        setState(() {
          _isSubmitted = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🎉 얼리버드 신청이 완료되었습니다!'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('신청에 실패했습니다. 다시 시도해 주세요.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isSubmitted) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF5D61A8), Color(0xFF2E6DA4)],
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '🎉 얼리버드 신청 완료!',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'PRO 출시 때 특별 할인 혜택을 보내드릴게요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF5D61A8), Color(0xFF2E6DA4)],
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '🚀 PRO 얼리버드 신청',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '무제한 음성 등록, AI 브리핑, 선행역산 알림을 먼저 만나보세요.\n출시 시 특별 할인 혜택을 드립니다.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.85),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'your@email.com',
                    hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 13,
                    ),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.15),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _isSubmitting ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF5D61A8),
                  minimumSize: const Size(0, 44),
                ),
                child: _isSubmitting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('신청'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
