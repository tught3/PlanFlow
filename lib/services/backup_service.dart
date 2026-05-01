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

  final SupabaseClient _client;

  Future<List<BackupSnapshot>> listBackups() async {
    final userId = _requireUserId();
    final rows = await _client
        .from('user_backups')
        .select('id, label, item_counts, created_at')
        .eq('user_id', userId)
        .order('created_at', ascending: false);

    return (rows as List<dynamic>)
        .map((row) => BackupSnapshot.fromJson(Map<String, dynamic>.from(row)))
        .toList(growable: false);
  }

  Future<BackupSnapshot> createBackup({String? label}) async {
    final userId = _requireUserId();
    final payload = <String, dynamic>{};
    final counts = <String, int>{};

    for (final table in _scopedTables) {
      final rows = await _client
          .from(table)
          .select(_selectColumnsFor(table))
          .eq('user_id', userId);
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

  Future<void> restoreBackup(String backupId) async {
    _requireUserId();
    await _client.rpc(
      'restore_user_backup',
      params: <String, dynamic>{'backup_id_input': backupId},
    );
  }

  String _selectColumnsFor(String table) {
    if (table == 'user_settings') {
      return 'id, user_id, morning_briefing_at, evening_briefing_at, '
          'default_reminder_min, created_at';
    }
    return '*';
  }

  String _requireUserId() {
    final userId = _client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      throw StateError('A signed-in user is required for backup and restore.');
    }
    return userId;
  }
}
