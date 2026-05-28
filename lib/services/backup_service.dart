import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class BackupSnapshot {
  const BackupSnapshot({
    required this.id,
    required this.createdAt,
    required this.itemCounts,
    this.label,
  });

  factory BackupSnapshot.fromJson(Map<String, dynamic> json) {
    return BackupSnapshot(
      id: json['id'].toString(),
      label: json['label'] as String?,
      createdAt: DateTime.parse(json['created_at'].toString()),
      itemCounts: Map<String, dynamic>.from(
        (json['item_counts'] as Map?) ?? const <String, dynamic>{},
      ).map((key, value) => MapEntry(key, value is num ? value.toInt() : 0)),
    );
  }

  final String id;
  final String? label;
  final DateTime createdAt;
  final Map<String, int> itemCounts;

  int get totalItems => itemCounts.values.fold(0, (sum, count) => sum + count);
}

class BackupAuthRequiredException implements Exception {
  const BackupAuthRequiredException();

  @override
  String toString() => '로그인 후 백업을 사용할 수 있습니다.';
}

class BackupSchemaException implements Exception {
  const BackupSchemaException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BackupService {
  BackupService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  static const List<String> _scopedTables = <String>[
    'events',
    'pre_actions',
    'reminders',
    'voice_logs',
    'location_history',
    'user_settings',
  ];
  static const String _automaticBackupLabel = '자동 백업';
  static const Duration _recentAutomaticBackupWindow = Duration(days: 30);
  static const Duration _monthlyAutomaticBackupWindow = Duration(days: 365);

  final SupabaseClient _client;

  Future<List<BackupSnapshot>> listBackups() async {
    final userId = _requireUserId();
    final dynamic rows;
    try {
      rows = await _client
          .from('user_backups')
          .select('id, label, item_counts, created_at')
          .eq('user_id', userId)
          .order('created_at', ascending: false);
    } on PostgrestException catch (error) {
      if (_isSchemaError(error)) {
        throw BackupSchemaException(_schemaErrorMessage);
      }
      rethrow;
    }

    final backups = (rows as List<dynamic>)
        .map((row) => BackupSnapshot.fromJson(Map<String, dynamic>.from(row)))
        .toList(growable: false);
    final pruneIds = automaticBackupIdsToPrune(
      backups,
      now: DateTime.now().toUtc(),
    );
    if (pruneIds.isEmpty) {
      return backups;
    }

    try {
      await _client
          .from('user_backups')
          .delete()
          .eq('user_id', userId)
          .inFilter('id', pruneIds.toList(growable: false));
    } catch (error, stackTrace) {
      debugPrint('Backup retention prune skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
      return backups;
    }

    return backups
        .where((backup) => !pruneIds.contains(backup.id))
        .toList(growable: false);
  }

  Future<BackupSnapshot> createBackup({String? label}) async {
    final userId = _requireUserId();
    final payload = <String, dynamic>{};
    final counts = <String, int>{};

    for (final table in _scopedTables) {
      final rows = await _fetchTableRows(table, userId);
      final tableRows = (rows as List<dynamic>)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList(growable: false);
      payload[table] = tableRows;
      counts[table] = tableRows.length;
    }

    final inserted = await _client
        .from('user_backups')
        .insert(<String, dynamic>{
          'user_id': userId,
          'label': label ?? '수동 백업',
          'payload': payload,
          'item_counts': counts,
        })
        .select('id, label, item_counts, created_at')
        .single();

    return BackupSnapshot.fromJson(Map<String, dynamic>.from(inserted));
  }

  Future<BackupSnapshot?> createAutomaticBackupIfDue({DateTime? now}) async {
    final current = now ?? DateTime.now();
    final dueAt = _latestBackupBoundary(current);
    final backups = await listBackups();
    final hasFreshAutomaticBackup = backups.any((backup) {
      return backup.label == _automaticBackupLabel &&
          !backup.createdAt.isBefore(dueAt);
    });

    if (hasFreshAutomaticBackup) {
      return null;
    }

    return createBackup(label: _automaticBackupLabel);
  }

  Future<void> restoreBackup(String backupId) async {
    _requireUserId();
    try {
      await _client.rpc(
        'restore_user_backup',
        params: <String, dynamic>{'backup_id_input': backupId},
      );
    } on PostgrestException catch (error) {
      if (_isSchemaError(error)) {
        throw BackupSchemaException(_schemaErrorMessage);
      }
      rethrow;
    }
  }

  String _selectColumnsFor(String table) {
    if (table == 'user_settings') {
      return 'id, user_id, morning_briefing_at, evening_briefing_at, '
          'default_reminder_min, prep_time_min, prep_pre_alarm_offset, '
          'depart_pre_alarm_offset, departure_safety_margin_min, '
          'travel_mode, voice_auto_start, voice_correction_learning_enabled, '
          'voice_common_learning_opt_in, '
          'preferred_map_provider, country_code, locale_code, time_zone_id, '
          'created_at';
    }
    return '*';
  }

  String _legacySelectColumnsFor(String table) {
    if (table == 'user_settings') {
      return 'id, user_id, morning_briefing_at, evening_briefing_at, '
          'default_reminder_min, prep_time_min, prep_pre_alarm_offset, '
          'depart_pre_alarm_offset, departure_safety_margin_min, '
          'travel_mode, voice_auto_start, voice_correction_learning_enabled, '
          'voice_common_learning_opt_in, created_at';
    }
    return _selectColumnsFor(table);
  }

  Future<dynamic> _fetchTableRows(String table, String userId) async {
    try {
      return await _client
          .from(table)
          .select(_selectColumnsFor(table))
          .eq('user_id', userId);
    } on PostgrestException catch (error) {
      if (table == 'user_settings' && _isMissingRegionColumnError(error)) {
        return _client
            .from(table)
            .select(_legacySelectColumnsFor(table))
            .eq('user_id', userId);
      }
      if (_isSchemaError(error)) {
        throw BackupSchemaException(_schemaErrorMessage);
      }
      rethrow;
    }
  }

  bool _isMissingRegionColumnError(PostgrestException error) {
    final text =
        '${error.code} ${error.message} ${error.details}'.toLowerCase();
    return isMissingRegionColumnErrorText(text);
  }

  bool _isSchemaError(PostgrestException error) {
    final text =
        '${error.code} ${error.message} ${error.details}'.toLowerCase();
    return isSchemaErrorText(text);
  }

  @visibleForTesting
  static bool isMissingRegionColumnErrorText(String text) {
    final normalized = text.toLowerCase();
    return normalized.contains('preferred_map_provider') ||
        normalized.contains('country_code') ||
        normalized.contains('locale_code') ||
        normalized.contains('time_zone_id');
  }

  @visibleForTesting
  static bool isSchemaErrorText(String text) {
    final normalized = text.toLowerCase();
    return normalized.contains('schema cache') ||
        normalized.contains('column') &&
            normalized.contains('does not exist') ||
        normalized.contains('42703');
  }

  String _requireUserId() {
    final userId = _client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      throw const BackupAuthRequiredException();
    }
    return userId;
  }

  static const String _schemaErrorMessage =
      'Supabase 백업 스키마가 앱과 맞지 않습니다. schema.sql 적용 상태를 확인해 주세요.';

  DateTime _latestBackupBoundary(DateTime now) {
    var boundary = DateTime(now.year, now.month, now.day, 3);
    if (now.isBefore(boundary)) {
      boundary = boundary.subtract(const Duration(days: 1));
    }
    return boundary;
  }

  static Set<String> automaticBackupIdsToPrune(
    List<BackupSnapshot> backups, {
    required DateTime now,
  }) {
    if (backups.isEmpty) {
      return const <String>{};
    }

    final ordered = backups.toList(growable: false)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final recentCutoff = now.toUtc().subtract(_recentAutomaticBackupWindow);
    final monthlyCutoff = now.toUtc().subtract(_monthlyAutomaticBackupWindow);
    final retainedMonthlyBuckets = <String>{};
    final pruneIds = <String>{};

    for (final backup in ordered) {
      if (backup.label != _automaticBackupLabel) {
        continue;
      }

      final createdAt = backup.createdAt.toUtc();
      if (!createdAt.isBefore(recentCutoff)) {
        continue;
      }
      if (createdAt.isBefore(monthlyCutoff)) {
        pruneIds.add(backup.id);
        continue;
      }

      final monthlyBucket =
          '${createdAt.year}-${createdAt.month.toString().padLeft(2, '0')}';
      if (retainedMonthlyBuckets.add(monthlyBucket)) {
        continue;
      }
      pruneIds.add(backup.id);
    }

    return pruneIds;
  }
}
