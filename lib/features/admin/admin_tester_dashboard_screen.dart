import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/local_time.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../data/models/tester_info_model.dart';
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
    final cards = <_StatCardData>[
      _StatCardData(
        label: '전체 사용자',
        value: '${stats.totalTesters}',
        icon: Icons.group_outlined,
        color: PlanFlowColors.primary,
      ),
      _StatCardData(
        label: '오늘 로그인',
        value: '${stats.loggedInToday}',
        icon: Icons.login,
        color: PlanFlowColors.active,
      ),
      _StatCardData(
        label: '최근 7일 활동',
        value: '${stats.active7d}',
        icon: Icons.calendar_today_outlined,
        color: PlanFlowColors.primaryMid,
      ),
      _StatCardData(
        label: '현재 온라인',
        value: '${stats.onlineNow}',
        icon: Icons.bolt,
        color: const Color(0xFF1FA37A),
      ),
      _StatCardData(
        label: '30일 미접속',
        value: '${stats.inactive30d}',
        icon: Icons.warning_amber_outlined,
        color: const Color(0xFFB45309),
      ),
      _StatCardData(
        label: 'Android',
        value: '${stats.androidCount}',
        icon: Icons.android,
        color: const Color(0xFF3DDC84),
      ),
      _StatCardData(
        label: 'iOS',
        value: '${stats.iosCount}',
        icon: Icons.phone_iphone,
        color: PlanFlowColors.textSecondary,
      ),
      _StatCardData(
        label: '최신 버전',
        value: stats.latestVersion == null
            ? '-'
            : '${stats.latestVersion} '
                '(${(stats.latestVersionRatio * 100).round()}%)',
        icon: Icons.new_releases_outlined,
        color: PlanFlowColors.fab,
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
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.data, required this.width});

  final _StatCardData data;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Card(
        child: Padding(
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
            ],
          ),
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
