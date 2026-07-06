import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/local_time.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../data/models/tester_info_model.dart';
import '../../data/repositories/tester_dashboard_repository.dart';
import 'tester_dashboard_provider.dart';

class AdminTesterDashboardScreen extends StatefulWidget {
  const AdminTesterDashboardScreen({super.key});

  @override
  State<AdminTesterDashboardScreen> createState() =>
      _AdminTesterDashboardScreenState();
}

class _AdminTesterDashboardScreenState extends State<AdminTesterDashboardScreen> {
  final TesterDashboardProvider _provider = TesterDashboardProvider();
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _searchController.text = _provider.filter.search;
    _scrollController.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _provider.loadInitial();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    _provider.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 240 &&
        _provider.state.hasMore &&
        !_provider.state.isLoadingMore) {
      _provider.loadMore();
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      _provider.applyFilter(_provider.filter.copyWith(
            search: value.trim(),
            offset: 0,
          ));
    });
  }

  void _setStatusFilter(TesterStatus? status) {
    _provider.applyFilter(_provider.filter.copyWith(
          status: status,
          offset: 0,
        ));
  }

  void _setPlatformFilter(String? platform) {
    _provider.applyFilter(_provider.filter.copyWith(
          platform: platform,
          offset: 0,
        ));
  }

  void _setSort(TesterDashboardSort sort) {
    _provider.applyFilter(_provider.filter.copyWith(
          sort: sort,
          offset: 0,
        ));
  }

  /// 통계 카드 탭 시 메인 리스트로 필터를 적용한다.
  /// 검색어는 항상 초기화하고, 전달받은 필터만 남긴 뒤 리스트 영역으로 스크롤.
  void _applyCardFilter({
    bool loggedInToday = false,
    TesterStatus? status,
    String? platform,
    bool clearPlatform = false,
    String? appVersion,
    bool clearAppVersion = false,
    String search = '',
  }) {
    _provider.applyFilter(TesterDashboardFilter(
      search: search,
      loggedInToday: loggedInToday,
      status: status,
      platform: clearPlatform ? null : platform,
      appVersion: clearAppVersion ? null : appVersion,
      sort: _provider.filter.sort,
      limit: _provider.filter.limit,
      offset: 0,
    ));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent * 0.35,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// "최근 7일 활동" 카드 전용 — 날짜별 그룹화 바텀시트.
  Future<void> _openActive7DaySheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => const _Active7DaySheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _provider,
      builder: (context, _) {
        final state = _provider.state;
        return Scaffold(
          appBar: AppBar(
            title: const Text('관리자 · 테스터 대시보드'),
            actions: [
              IconButton(
                key: const ValueKey('admin-testers-refresh'),
                tooltip: '새로고침',
                onPressed: state.isLoading
                    ? null
                    : () => _provider.refresh(),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: () => _provider.refresh(),
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _buildStatsSection(state.stats)),
                SliverToBoxAdapter(child: _buildFilterSection()),
                if (state.isLoading && state.testers.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: _CenteredProgress(),
                  )
                else if (state.hasError && state.testers.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _ErrorView(
                      message: state.error ?? '데이터를 불러오지 못했어요.',
                      onRetry: () => _provider.refresh(),
                    ),
                  )
                else if (state.testers.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyView(),
                  )
                else ...[
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    sliver: SliverList.separated(
                      itemCount: state.testers.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final tester = state.testers[index];
                        return _TesterCard(
                          key: ValueKey('tester-${tester.id}'),
                          tester: tester,
                        );
                      },
                    ),
                  ),
                  if (state.isLoadingMore)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        ),
                      ),
                    ),
                  if (!state.hasMore)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: Text(
                            '모든 테스터를 불러왔어요.',
                            style: TextStyle(
                              color: PlanFlowColors.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatsSection(TesterStats stats) {
    final latestVersion = stats.latestVersion;
    final cards = <_StatCardData>[
      _StatCardData(
        label: '전체 사용자',
        value: '${stats.totalTesters}',
        icon: Icons.group_outlined,
        color: PlanFlowColors.primary,
        onTap: null,
      ),
      _StatCardData(
        label: '오늘 로그인',
        value: '${stats.loggedInToday}',
        icon: Icons.login,
        color: PlanFlowColors.active,
        onTap: () => _applyCardFilter(
          loggedInToday: true,
          status: null,
          platform: null,
          appVersion: null,
        ),
      ),
      _StatCardData(
        label: '최근 7일 활동',
        value: '${stats.active7d}',
        icon: Icons.calendar_today_outlined,
        color: PlanFlowColors.primaryMid,
        onTap: _openActive7DaySheet,
      ),
      _StatCardData(
        label: '현재 온라인',
        value: '${stats.onlineNow}',
        icon: Icons.bolt,
        color: const Color(0xFF1FA37A),
        onTap: () => _applyCardFilter(
          status: TesterStatus.online,
          loggedInToday: false,
          platform: null,
          appVersion: null,
        ),
      ),
      _StatCardData(
        label: '30일 미접속',
        value: '${stats.inactive30d}',
        icon: Icons.warning_amber_outlined,
        color: const Color(0xFFB45309),
        onTap: () => _applyCardFilter(
          status: TesterStatus.inactive,
          loggedInToday: false,
          platform: null,
          appVersion: null,
        ),
      ),
      _StatCardData(
        label: 'Android',
        value: '${stats.androidCount}',
        icon: Icons.android,
        color: const Color(0xFF3DDC84),
        onTap: () => _applyCardFilter(
          platform: 'android',
          loggedInToday: false,
          status: null,
          appVersion: null,
        ),
      ),
      _StatCardData(
        label: 'iOS',
        value: '${stats.iosCount}',
        icon: Icons.phone_iphone,
        color: PlanFlowColors.textSecondary,
        onTap: () => _applyCardFilter(
          platform: 'ios',
          loggedInToday: false,
          status: null,
          appVersion: null,
        ),
      ),
      _StatCardData(
        label: '최신 버전',
        value: latestVersion == null
            ? '-'
            : '$latestVersion '
                '(${(stats.latestVersionRatio * 100).round()}%)',
        icon: Icons.new_releases_outlined,
        color: PlanFlowColors.fab,
        onTap: latestVersion == null
            ? null
            : () => _applyCardFilter(
                  appVersion: latestVersion,
                  loggedInToday: false,
                  status: null,
                  platform: null,
                ),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: ResponsiveContent(
        maxWidth: 1100,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columns = _columnCountForWidth(constraints.maxWidth);
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: cards
                  .map((card) => _StatCard(
                        data: card,
                        width:
                            (constraints.maxWidth - 10 * (columns - 1)) /
                                columns,
                      ))
                  .toList(),
            );
          },
        ),
      ),
    );
  }

  int _columnCountForWidth(double width) {
    if (width >= 1100) return 4;
    if (width >= 720) return 3;
    if (width >= 480) return 2;
    return 1;
  }

  Widget _buildFilterSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: ResponsiveContent(
        maxWidth: 1100,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('admin-testers-search-field'),
              controller: _searchController,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: '이메일 / 이름 검색',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _FilterChipGroup(
                  label: '상태',
                  items: const [
                    _FilterOption(label: '전체', value: null),
                    _FilterOption(label: '온라인', value: 'online'),
                    _FilterOption(label: '최근 사용', value: 'recent'),
                    _FilterOption(label: '장기 미접속', value: 'inactive'),
                  ],
                  selectedValue: _provider.filter.statusValue.isEmpty
                      ? null
                      : _provider.filter.statusValue,
                  onSelected: (value) {
                    final status = switch (value) {
                      'online' => TesterStatus.online,
                      'recent' => TesterStatus.recent,
                      'inactive' => TesterStatus.inactive,
                      _ => null,
                    };
                    _setStatusFilter(status);
                  },
                ),
                _FilterChipGroup(
                  label: '플랫폼',
                  items: const [
                    _FilterOption(label: '전체', value: null),
                    _FilterOption(label: 'Android', value: 'android'),
                    _FilterOption(label: 'iOS', value: 'ios'),
                  ],
                  selectedValue: _provider.filter.platform,
                  onSelected: (value) => _setPlatformFilter(value),
                ),
                _FilterChipGroup(
                  label: '정렬',
                  items: const [
                    _FilterOption(label: '최근 활동순', value: 'last_active'),
                    _FilterOption(label: '가입일순', value: 'created'),
                  ],
                  selectedValue: _provider.filter.sortValue,
                  onSelected: (value) {
                    final sort = value == 'created'
                        ? TesterDashboardSort.created
                        : TesterDashboardSort.lastActive;
                    _setSort(sort);
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _StatCardData {
  const _StatCardData({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.data, required this.width});

  final _StatCardData data;
  final double width;

  @override
  Widget build(BuildContext context) {
    final cardContent = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: data.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(data.icon, color: data.color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  data.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  data.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (data.onTap != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(
                Icons.chevron_right,
                color: PlanFlowColors.primaryLight,
                size: 20,
              ),
            ),
        ],
      ),
    );

    if (data.onTap == null) {
      return SizedBox(
        width: width,
        child: Card(child: cardContent),
      );
    }

    return SizedBox(
      width: width,
      child: Card(
        child: InkWell(
          onTap: data.onTap,
          borderRadius: BorderRadius.circular(10),
          child: cardContent,
        ),
      ),
    );
  }
}

class _FilterOption {
  const _FilterOption({required this.label, required this.value});

  final String label;
  final String? value;
}

class _FilterChipGroup extends StatelessWidget {
  const _FilterChipGroup({
    required this.label,
    required this.items,
    required this.selectedValue,
    required this.onSelected,
  });

  final String label;
  final List<_FilterOption> items;
  final String? selectedValue;
  final void Function(String? value) onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
          ),
        ),
        ...items.map((option) {
          final selected = option.value == selectedValue;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilterChip(
              key: ValueKey(
                'admin-tester-filter-$label-${option.value ?? 'all'}',
              ),
              label: Text(option.label),
              selected: selected,
              onSelected: (value) => onSelected(option.value),
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
          );
        }),
      ],
    );
  }
}

class _TesterCard extends StatelessWidget {
  const _TesterCard({super.key, required this.tester});

  final TesterInfo tester;

  @override
  Widget build(BuildContext context) {
    final now = planflowNow();
    final status = tester.status(now: now);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(status.emoji, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tester.displayLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tester.email.isEmpty ? '(이메일 없음)' : tester.email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _InfoChip(text: tester.platformLabel),
                      _InfoChip(text: tester.versionLabel),
                      _InfoChip(
                        text: '가입 ${_formatDate(tester.createdAt)}',
                      ),
                      _InfoChip(
                        text:
                            '마지막 로그인 ${_formatRelative(tester.lastLoginAt, now)}',
                      ),
                      _InfoChip(
                        text:
                            '마지막 활동 ${_formatRelative(tester.lastActiveAt, now)}',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor(status).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                status.label,
                style: TextStyle(
                  color: statusColor(status),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Color statusColor(TesterStatus status) {
    return switch (status) {
      TesterStatus.online => const Color(0xFF1FA37A),
      TesterStatus.recent => const Color(0xFFB45309),
      TesterStatus.inactive => const Color(0xFFB42318),
    };
  }

  static String _formatDate(DateTime? value) {
    if (value == null) return '-';
    final local = value.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  static String _formatRelative(DateTime? value, DateTime now) {
    if (value == null) return '기록 없음';
    final local = value.toLocal();
    final delta = now.difference(local);
    if (delta.isNegative) {
      return '방금';
    }
    if (delta.inMinutes < 1) return '방금';
    if (delta.inMinutes < 60) return '${delta.inMinutes}분 전';
    if (delta.inHours < 24) return '${delta.inHours}시간 전';
    if (delta.inDays < 30) return '${delta.inDays}일 전';
    return _formatDate(value);
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: PlanFlowColors.tagNormalBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 10,
          color: PlanFlowColors.tagNormalText,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _CenteredProgress extends StatelessWidget {
  const _CenteredProgress();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 80),
      child: Center(
        child: SizedBox(
          height: 28,
          width: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 80),
      child: Center(
        child: Text(
          '조건에 맞는 테스터가 없어요.',
          style: TextStyle(color: PlanFlowColors.textSecondary),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off,
              size: 40,
              color: PlanFlowColors.textSecondary,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }
}

/// "최근 7일 활동" 카드 탭 시 노출되는 날짜별 그룹화 뷰.
/// 7일치 active 사용자를 get_tester_dashboard(status=recent, limit=200)로
/// 가져온 뒤, 클라이언트에서 last_active_at의 날짜(로컬)로 그룹핑한다.
class _Active7DaySheet extends StatefulWidget {
  const _Active7DaySheet();

  @override
  State<_Active7DaySheet> createState() => _Active7DaySheetState();
}

class _Active7DaySheetState extends State<_Active7DaySheet> {
  late final TesterDashboardRepository _repository;
  List<TesterInfo> _testers = const <TesterInfo>[];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _repository = SupabaseTesterDashboardRepository();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final filter = const TesterDashboardFilter(
        status: TesterStatus.recent,
        limit: 200,
        offset: 0,
      );
      final rows = await _repository.fetchTesters(filter);
      if (!mounted) return;
      setState(() {
        _testers = rows;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _isLoading = false;
      });
    }
  }

  /// [TesterInfo.last_active_at]의 로컬 날짜(yyyy-MM-dd) 기준 그룹핑.
  /// 날짜 내림차순(오늘 → 과거), 같은 날 안에서는 시간 내림차순으로 정렬.
  Map<String, List<TesterInfo>> _groupByDay() {
    final map = <String, List<TesterInfo>>{};
    for (final tester in _testers) {
      final active = tester.lastActiveAt;
      if (active == null) continue;
      final local = active.toLocal();
      final key =
          '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
      map.putIfAbsent(key, () => <TesterInfo>[]).add(tester);
    }
    final sortedKeys = map.keys.toList()..sort((a, b) => b.compareTo(a));
    return {for (final k in sortedKeys) k: map[k]!};
  }

  String _dayLabel(String key) {
    final today = DateTime.now();
    final todayKey =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final yesterday = today.subtract(const Duration(days: 1));
    final yesterdayKey =
        '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';
    if (key == todayKey) return '오늘';
    if (key == yesterdayKey) return '어제';
    return key;
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: PlanFlowColors.textSecondary
                              .withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '최근 7일 활동',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 16,
                                    ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '최근 7일 내 접속 기록이 있는 사용자를 날짜별로 묶어 보여줘요. (최대 200명)',
                                style:
                                    Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          tooltip: '새로고침',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? _SheetErrorView(
                            message: _error!,
                            onRetry: _load,
                          )
                        : _testers.isEmpty
                            ? const Center(
                                child: Text(
                                  '최근 7일 내 활동 사용자가 없어요.',
                                  style: TextStyle(
                                    color: PlanFlowColors.textSecondary,
                                  ),
                                ),
                              )
                            : ListView(
                                controller: scrollController,
                                padding: EdgeInsets.fromLTRB(
                                  16,
                                  8,
                                  16,
                                  mediaQuery.padding.bottom + 24,
                                ),
                                children: [
                                  for (final entry in _groupByDay().entries) ...[
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                          4, 12, 4, 6),
                                      child: Row(
                                        children: [
                                          Text(
                                            _dayLabel(entry.key),
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleSmall
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                  color: PlanFlowColors.primary,
                                                ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            '${entry.value.length}명',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                        ],
                                      ),
                                    ),
                                    for (final tester in entry.value)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 4),
                                        child: _ActiveDayTesterRow(
                                            tester: tester),
                                      ),
                                  ],
                                ],
                              ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ActiveDayTesterRow extends StatelessWidget {
  const _ActiveDayTesterRow({required this.tester});

  final TesterInfo tester;

  @override
  Widget build(BuildContext context) {
    final active = tester.lastActiveAt?.toLocal();
    final timeLabel = active == null
        ? ''
        : '${active.hour.toString().padLeft(2, '0')}:'
            '${active.minute.toString().padLeft(2, '0')}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: PlanFlowColors.primaryFaint,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                tester.displayLabel.isNotEmpty
                    ? tester.displayLabel.substring(0, 1)
                    : '?',
                style: const TextStyle(
                  color: PlanFlowColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tester.displayLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tester.email.isEmpty ? '(이메일 없음)' : tester.email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (timeLabel.isNotEmpty)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: PlanFlowColors.tagNormalBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  timeLabel,
                  style: const TextStyle(
                    fontSize: 10,
                    color: PlanFlowColors.tagNormalText,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SheetErrorView extends StatelessWidget {
  const _SheetErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off,
                size: 36, color: PlanFlowColors.textSecondary),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }
}
