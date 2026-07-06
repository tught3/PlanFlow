import 'package:flutter/foundation.dart';

import '../../core/local_time.dart';

/// Tester Dashboard에 표시할 단일 테스터(사용자) 정보.
@immutable
class TesterInfo {
  const TesterInfo({
    required this.id,
    required this.email,
    required this.displayName,
    required this.name,
    required this.createdAt,
    required this.lastLoginAt,
    required this.lastActiveAt,
    required this.appVersion,
    required this.buildNumber,
    required this.platform,
  });

  factory TesterInfo.fromMap(Map<String, dynamic> map) {
    return TesterInfo(
      id: map['id']?.toString() ?? '',
      email: map['email']?.toString() ?? '',
      displayName: map['display_name']?.toString().trim().isEmpty == true
          ? null
          : map['display_name']?.toString(),
      name: map['name']?.toString().trim().isEmpty == true
          ? null
          : map['name']?.toString(),
      createdAt: _parseDateTime(map['created_at']),
      lastLoginAt: _parseDateTime(map['last_login_at']),
      lastActiveAt: _parseDateTime(map['last_active_at']),
      appVersion: map['app_version']?.toString().trim().isEmpty == true
          ? null
          : map['app_version']?.toString().trim(),
      buildNumber: map['build_number']?.toString().trim().isEmpty == true
          ? null
          : map['build_number']?.toString().trim(),
      platform: map['platform']?.toString().trim().isEmpty == true
          ? null
          : map['platform']?.toString().trim().toLowerCase(),
    );
  }

  final String id;
  final String email;
  final String? displayName;
  final String? name;
  final DateTime? createdAt;
  final DateTime? lastLoginAt;
  final DateTime? lastActiveAt;
  final String? appVersion;
  final String? buildNumber;
  final String? platform;

  /// 화면 표시용 사용자 식별자. 우선순위: display_name > name > email.
  String get displayLabel {
    final nameValue = displayName ?? name;
    if (nameValue != null && nameValue.trim().isNotEmpty) {
      return nameValue.trim();
    }
    return email.isEmpty ? '(이름 없음)' : email;
  }

  /// app_version과 build_number를 "1.1.1 (77)" 형태로 반환. 둘 다 없으면 '-'.
  String get versionLabel {
    final parts = <String>[];
    if (appVersion != null) parts.add(appVersion!);
    if (buildNumber != null) parts.add('빌드 $buildNumber');
    return parts.isEmpty ? '-' : parts.join(' / ');
  }

  /// platform 한글 라벨.
  String get platformLabel {
    return switch (platform) {
      'android' => 'Android',
      'ios' => 'iOS',
      'web' => 'Web',
      'macos' => 'macOS',
      'windows' => 'Windows',
      'linux' => 'Linux',
      _ => '-',
    };
  }

  /// 상태 분류. [now] 기준으로 계산한다.
  TesterStatus status({DateTime? now}) {
    final reference = (now ?? planflowNow()).toUtc();
    final active = lastActiveAt;
    if (active == null) {
      return TesterStatus.inactive;
    }
    final delta = reference.difference(active.toUtc());
    if (delta.inMinutes < 5) {
      return TesterStatus.online;
    }
    if (delta.inDays < 7) {
      return TesterStatus.recent;
    }
    return TesterStatus.inactive;
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'email': email,
      'display_name': displayName,
      'name': name,
      'created_at': createdAt?.toUtc().toIso8601String(),
      'last_login_at': lastLoginAt?.toUtc().toIso8601String(),
      'last_active_at': lastActiveAt?.toUtc().toIso8601String(),
      'app_version': appVersion,
      'build_number': buildNumber,
      'platform': platform,
    };
  }

  TesterInfo copyWith({
    String? id,
    String? email,
    String? displayName,
    String? name,
    DateTime? createdAt,
    DateTime? lastLoginAt,
    DateTime? lastActiveAt,
    String? appVersion,
    String? buildNumber,
    String? platform,
  }) {
    return TesterInfo(
      id: id ?? this.id,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      lastLoginAt: lastLoginAt ?? this.lastLoginAt,
      lastActiveAt: lastActiveAt ?? this.lastActiveAt,
      appVersion: appVersion ?? this.appVersion,
      buildNumber: buildNumber ?? this.buildNumber,
      platform: platform ?? this.platform,
    );
  }

  static DateTime? _parseDateTime(Object? value) {
    if (value == null) return null;
    final raw = value.toString().trim();
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }
}

/// 통계 카드에 표시할 집계 결과.
@immutable
class TesterStats {
  const TesterStats({
    required this.totalTesters,
    required this.active7d,
    required this.loggedInToday,
    required this.inactive30d,
    required this.onlineNow,
    required this.androidCount,
    required this.iosCount,
    required this.latestVersion,
    required this.latestVersionCount,
  });

  factory TesterStats.fromMap(Map<String, dynamic> map) {
    int parseInt(String key) {
      final value = map[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    String? parseString(String key) {
      final value = map[key]?.toString().trim();
      return (value == null || value.isEmpty) ? null : value;
    }

    return TesterStats(
      totalTesters: parseInt('total_testers'),
      active7d: parseInt('active_7d'),
      loggedInToday: parseInt('logged_in_today'),
      inactive30d: parseInt('inactive_30d'),
      onlineNow: parseInt('online_now'),
      androidCount: parseInt('android_count'),
      iosCount: parseInt('ios_count'),
      latestVersion: parseString('latest_version'),
      latestVersionCount: parseInt('latest_version_count'),
    );
  }

  final int totalTesters;
  final int active7d;
  final int loggedInToday;
  final int inactive30d;
  final int onlineNow;
  final int androidCount;
  final int iosCount;
  final String? latestVersion;
  final int latestVersionCount;

  /// 최신 버전 사용자 비율(0~1). total이 0이면 0.
  double get latestVersionRatio {
    if (totalTesters <= 0) return 0;
    if (latestVersion == null) return 0;
    return (latestVersionCount / totalTesters).clamp(0.0, 1.0);
  }

  static TesterStats empty() => const TesterStats(
        totalTesters: 0,
        active7d: 0,
        loggedInToday: 0,
        inactive30d: 0,
        onlineNow: 0,
        androidCount: 0,
        iosCount: 0,
        latestVersion: null,
        latestVersionCount: 0,
      );
}

/// 테이블 행 상태 분류.
enum TesterStatus {
  online,
  recent,
  inactive;

  String get label => switch (this) {
        TesterStatus.online => '온라인',
        TesterStatus.recent => '최근 사용',
        TesterStatus.inactive => '장기 미접속',
      };

  String get emoji => switch (this) {
        TesterStatus.online => '🟢',
        TesterStatus.recent => '🟡',
        TesterStatus.inactive => '🔴',
      };
}

/// 대시보드 필터/정렬 상태.
@immutable
class TesterDashboardFilter {
  const TesterDashboardFilter({
    this.search = '',
    this.status,
    this.platform,
    this.appVersion,
    this.loggedInToday = false,
    this.sort = TesterDashboardSort.lastActive,
    this.limit = 50,
    this.offset = 0,
  });

  final String search;
  final TesterStatus? status;
  final String? platform;
  final String? appVersion;
  final bool loggedInToday;
  final TesterDashboardSort sort;
  final int limit;
  final int offset;

  String get statusValue => switch (status) {
        TesterStatus.online => 'online',
        TesterStatus.recent => 'recent',
        TesterStatus.inactive => 'inactive',
        null => '',
      };

  String get sortValue => switch (sort) {
        TesterDashboardSort.lastActive => 'last_active',
        TesterDashboardSort.created => 'created',
      };

  TesterDashboardFilter copyWith({
    String? search,
    TesterStatus? status,
    Object? platform = _sentinel,
    Object? appVersion = _sentinel,
    bool? loggedInToday,
    TesterDashboardSort? sort,
    int? limit,
    int? offset,
  }) {
    return TesterDashboardFilter(
      search: search ?? this.search,
      status: status ?? this.status,
      platform: identical(platform, _sentinel)
          ? this.platform
          : platform as String?,
      appVersion: identical(appVersion, _sentinel)
          ? this.appVersion
          : appVersion as String?,
      loggedInToday: loggedInToday ?? this.loggedInToday,
      sort: sort ?? this.sort,
      limit: limit ?? this.limit,
      offset: offset ?? this.offset,
    );
  }

  static const Object _sentinel = Object();

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TesterDashboardFilter &&
        other.search == search &&
        other.status == status &&
        other.platform == platform &&
        other.appVersion == appVersion &&
        other.loggedInToday == loggedInToday &&
        other.sort == sort &&
        other.limit == limit &&
        other.offset == offset;
  }

  @override
  int get hashCode => Object.hash(
        search,
        status,
        platform,
        appVersion,
        loggedInToday,
        sort,
        limit,
        offset,
      );
}

enum TesterDashboardSort {
  lastActive,
  created,
}
