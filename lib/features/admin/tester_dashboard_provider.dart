import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/models/tester_info_model.dart';
import '../../data/repositories/tester_dashboard_repository.dart';

enum TesterDashboardLoadStatus { idle, loading, refreshing, error }

class TesterDashboardState {
  const TesterDashboardState({
    required this.filter,
    required this.testers,
    required this.stats,
    required this.status,
    required this.isLoadingMore,
    required this.hasMore,
    required this.error,
  });

  factory TesterDashboardState.initial() => TesterDashboardState(
        filter: const TesterDashboardFilter(),
        testers: const <TesterInfo>[],
        stats: TesterStats.empty(),
        status: TesterDashboardLoadStatus.idle,
        isLoadingMore: false,
        hasMore: true,
        error: null,
      );

  final TesterDashboardFilter filter;
  final List<TesterInfo> testers;
  final TesterStats stats;
  final TesterDashboardLoadStatus status;
  final bool isLoadingMore;
  final bool hasMore;
  final String? error;

  bool get isLoading => status == TesterDashboardLoadStatus.loading;
  bool get hasError => status == TesterDashboardLoadStatus.error;

  TesterDashboardState copyWith({
    TesterDashboardFilter? filter,
    List<TesterInfo>? testers,
    TesterStats? stats,
    TesterDashboardLoadStatus? status,
    bool? isLoadingMore,
    bool? hasMore,
    Object? error,
    bool clearError = false,
  }) {
    return TesterDashboardState(
      filter: filter ?? this.filter,
      testers: testers ?? this.testers,
      stats: stats ?? this.stats,
      status: status ?? this.status,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : error?.toString() ?? this.error,
    );
  }
}

class TesterDashboardProvider extends ChangeNotifier {
  TesterDashboardProvider({
    TesterDashboardRepository? repository,
  }) : _repository = repository ?? SupabaseTesterDashboardRepository();

  static const int _pageSize = 50;
  static const int _maxPages = 20;

  final TesterDashboardRepository _repository;

  TesterDashboardState _state = TesterDashboardState.initial();
  bool _disposed = false;
  dynamic _realtimeSubscription;
  bool _realtimeReloadScheduled = false;

  TesterDashboardState get state => _state;
  TesterDashboardFilter get filter => _state.filter;
  TesterStats get stats => _state.stats;
  List<TesterInfo> get testers => _state.testers;
  bool get isLoading => _state.isLoading;
  String? get error => _state.error;

  /// 검색/필터/정렬이 바뀌면 1페이지부터 다시 로드한다.
  Future<void> applyFilter(TesterDashboardFilter nextFilter) async {
    if (nextFilter == _state.filter) {
      return;
    }
    _setState(
      _state.copyWith(
        filter: nextFilter,
        status: TesterDashboardLoadStatus.loading,
        testers: const <TesterInfo>[],
        hasMore: true,
        clearError: true,
      ),
    );
    await _loadPage(nextFilter, isRefresh: true);
    unawaited(_loadStats());
  }

  Future<void> refresh() async {
    _setState(
      _state.copyWith(status: TesterDashboardLoadStatus.refreshing),
    );
    await _loadPage(_state.filter, isRefresh: true);
    unawaited(_loadStats());
  }

  Future<void> loadInitial() async {
    _setState(
      _state.copyWith(status: TesterDashboardLoadStatus.loading, clearError: true),
    );
    await Future.wait<void>([
      _loadPage(_state.filter, isRefresh: true),
      _loadStats(),
    ]);
    _ensureRealtime();
  }

  Future<void> loadMore() async {
    if (_state.isLoadingMore || !_state.hasMore) {
      return;
    }
    _setState(_state.copyWith(isLoadingMore: true));
    final nextOffset = _state.filter.offset + _state.filter.limit;
    final nextPageFilter = _state.filter.copyWith(offset: nextOffset);
    try {
      final items = await _repository.fetchTesters(nextPageFilter);
      final hasMore = items.length == nextPageFilter.limit;
      _setState(
        _state.copyWith(
          filter: nextPageFilter,
          testers: <TesterInfo>[..._state.testers, ...items],
          isLoadingMore: false,
          hasMore: hasMore,
        ),
      );
    } catch (error) {
      _setState(
        _state.copyWith(isLoadingMore: false, error: error),
      );
    }
  }

  Future<void> _loadPage(
    TesterDashboardFilter pageFilter, {
    required bool isRefresh,
  }) async {
    try {
      final items = await _repository.fetchTesters(pageFilter);
      final hasMore = items.length == pageFilter.limit;
      final reachedHardCap = pageFilter.offset >= _pageSize * _maxPages;
      _setState(
        _state.copyWith(
          filter: pageFilter,
          testers: items,
          status: TesterDashboardLoadStatus.idle,
          hasMore: hasMore && !reachedHardCap,
          clearError: true,
        ),
      );
    } catch (error) {
      _setState(
        _state.copyWith(
          status: TesterDashboardLoadStatus.error,
          error: error,
        ),
      );
    }
  }

  Future<void> _loadStats() async {
    try {
      final nextStats = await _repository.fetchStats();
      _setState(_state.copyWith(stats: nextStats, clearError: true));
    } catch (error) {
      // 통계 실패는 목록 로드와 독립적으로 다뤄 무시한다.
      debugPrint('TesterDashboard stats skipped: $error');
    }
  }

  void _ensureRealtime() {
    if (_realtimeSubscription != null) {
      return;
    }
    try {
      _realtimeSubscription = _repository.subscribeToUserChanges(() {
        if (_realtimeReloadScheduled) {
          return;
        }
        _realtimeReloadScheduled = true;
        // Realtime 폭주 방지: 콜백 수신 후 4초 디바운스.
        Future<void>.delayed(const Duration(seconds: 4), () {
          _realtimeReloadScheduled = false;
          if (_disposed) return;
          unawaited(refresh());
        });
      });
    } catch (error) {
      debugPrint('TesterDashboard realtime subscribe failed: $error');
    }
  }

  void _setState(TesterDashboardState next) {
    _state = next;
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final sub = _realtimeSubscription;
    if (sub is StreamSubscription<dynamic>) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }
}
