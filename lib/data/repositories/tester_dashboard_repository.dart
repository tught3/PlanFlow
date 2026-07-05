import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/tester_info_model.dart';

abstract class TesterDashboardRepository {
  Future<List<TesterInfo>> fetchTesters(TesterDashboardFilter filter);

  Future<TesterStats> fetchStats();

  /// Realtime 갱신 콜백을 등록한다. 반환값은 구독 해제 함수.
  StreamSubscription<dynamic> subscribeToUserChanges(void Function() onUpdate);
}

class SupabaseTesterDashboardRepository
    implements TesterDashboardRepository {
  SupabaseTesterDashboardRepository({
    SupabaseClient? client,
    int callTimeoutSeconds = 15,
  })  : _client = client ?? Supabase.instance.client,
        _callTimeout = Duration(seconds: callTimeoutSeconds);

  final SupabaseClient _client;
  final Duration _callTimeout;

  @override
  Future<List<TesterInfo>> fetchTesters(TesterDashboardFilter filter) async {
    try {
      final response = await _client
          .rpc('get_tester_dashboard', params: <String, dynamic>{
            'p_search': filter.search.trim().isEmpty ? null : filter.search.trim(),
            'p_status': filter.statusValue.isEmpty ? null : filter.statusValue,
            'p_platform': filter.platform?.isNotEmpty == true
                ? filter.platform
                : null,
            'p_app_version': filter.appVersion?.isNotEmpty == true
                ? filter.appVersion
                : null,
            'p_sort': filter.sortValue,
            'p_limit': filter.limit,
            'p_offset': filter.offset,
          })
          .timeout(_callTimeout);

      final List<dynamic> rows = response is List
          ? response
          : (response is Map && response['data'] is List
              ? response['data'] as List
              : const <dynamic>[]);

      return rows
          .whereType<Map>()
          .map((row) => TesterInfo.fromMap(Map<String, dynamic>.from(row)))
          .toList(growable: false);
    } on PostgrestException catch (error) {
      debugPrint('TesterDashboard fetchTesters failed: ${error.message}');
      rethrow;
    } on TimeoutException {
      throw const TesterDashboardException('요청 시간이 초과됐어요. 잠시 후 다시 시도해 주세요.');
    } catch (error) {
      debugPrint('TesterDashboard fetchTesters error: $error');
      throw const TesterDashboardException(
        '테스터 목록을 불러오지 못했어요. 네트워크 상태를 확인해 주세요.',
      );
    }
  }

  @override
  Future<TesterStats> fetchStats() async {
    try {
      final response = await _client
          .rpc('get_tester_stats')
          .timeout(_callTimeout);

      // RPC가 단일 행을 반환하므로 Postgrest는 List로 감싸서 준다.
      Map<String, dynamic>? row;
      if (response is List && response.isNotEmpty) {
        final first = response.first;
        if (first is Map) {
          row = Map<String, dynamic>.from(first);
        }
      } else if (response is Map) {
        row = Map<String, dynamic>.from(response);
      }
      if (row == null) {
        return TesterStats.empty();
      }
      return TesterStats.fromMap(row);
    } on PostgrestException catch (error) {
      debugPrint('TesterDashboard fetchStats failed: ${error.message}');
      rethrow;
    } on TimeoutException {
      throw const TesterDashboardException('요청 시간이 초과됐어요. 잠시 후 다시 시도해 주세요.');
    } catch (error) {
      debugPrint('TesterDashboard fetchStats error: $error');
      throw const TesterDashboardException(
        '통계를 불러오지 못했어요. 잠시 후 다시 시도해 주세요.',
      );
    }
  }

  @override
  StreamSubscription<dynamic> subscribeToUserChanges(
    void Function() onUpdate,
  ) {
    try {
      final channel = _client
          .channel('tester-dashboard-users')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'users',
            callback: (payload) {
              try {
                onUpdate();
              } catch (error) {
                debugPrint('TesterDashboard realtime callback error: $error');
              }
            },
          )
          .subscribe();

      return _ChannelSubscription(channel, _client);
    } catch (error) {
      debugPrint('TesterDashboard realtime subscribe failed: $error');
      return _NoopSubscription() as StreamSubscription<dynamic>;
    }
  }
}

/// Realtime 채널 해제를 StreamSubscription 인터페이스로 래핑.
class _ChannelSubscription implements StreamSubscription<dynamic> {
  _ChannelSubscription(this._channel, this._client);

  final RealtimeChannel _channel;
  final SupabaseClient _client;

  @override
  Future<void> cancel() async {
    try {
      await _client.removeChannel(_channel);
    } catch (error) {
      debugPrint('TesterDashboard channel cancel failed: $error');
    }
  }

  @override
  void onData(void Function(dynamic data)? handleData) {}

  @override
  void onDone(void Function()? handleDone) {}

  @override
  void onError(Function? handleError) {}

  @override
  void pause([Future<void>? resumeSignal]) {}

  @override
  void resume() {}

  @override
  bool get isPaused => false;

  @override
  Future<T> asFuture<T>([T? futureValue]) {
    final completer = Completer<T>();
    return completer.future;
  }
}

/// Realtime을 사용할 수 없는 환경에서 no-op으로 대체.
class _NoopSubscription implements StreamSubscription<dynamic> {
  @override
  Future<void> cancel() async {}
  @override
  void onData(void Function(dynamic data)? handleData) {}
  @override
  void onDone(void Function()? handleDone) {}
  @override
  void onError(Function? handleError) {}
  @override
  void pause([Future<void>? resumeSignal]) {}
  @override
  void resume() {}
  @override
  bool get isPaused => false;
  @override
  Future<T> asFuture<T>([T? futureValue]) {
    final completer = Completer<T>();
    return completer.future;
  }
}

class TesterDashboardException implements Exception {
  const TesterDashboardException(this.message);

  final String message;

  @override
  String toString() => message;
}
