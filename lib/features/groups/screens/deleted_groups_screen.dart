import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants.dart';
import '../../../core/theme.dart';
import '../models/group_backup_model.dart';
import '../providers/deleted_groups_provider.dart';

class DeletedGroupsScreen extends StatefulWidget {
  const DeletedGroupsScreen({super.key});

  @override
  State<DeletedGroupsScreen> createState() => _DeletedGroupsScreenState();
}

class _DeletedGroupsScreenState extends State<DeletedGroupsScreen> {
  static const int _defaultRetentionDays = 30;

  late final DeletedGroupsProvider _provider;

  @override
  void initState() {
    super.initState();
    _provider = DeletedGroupsProvider();
    _provider.addListener(_onProviderChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _provider.load();
    });
  }

  @override
  void dispose() {
    _provider.removeListener(_onProviderChanged);
    _provider.dispose();
    super.dispose();
  }

  void _onProviderChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  String _relativeDescription(GroupBackupModel backup) {
    final created = backup.createdAt;
    if (created == null) {
      return '시점 정보 없음';
    }
    final age = DateTime.now().toUtc().difference(created.toUtc());
    final days = age.inDays;
    final hours = age.inHours;
    if (backup.isArchive) {
      // 보관(archive)은 만료 없이 복원 가능.
      if (days <= 0) {
        if (hours <= 0) {
          return '방금 보관됨';
        }
        return '$hours시간 전 보관 · 복원 가능';
      }
      return '$days일 전 보관 · 복원 가능';
    }
    if (days <= 0) {
      if (hours <= 0) {
        return '방금 삭제됨';
      }
      return '$hours시간 전 삭제';
    }
    final remaining = _defaultRetentionDays - days;
    if (remaining > 0) {
      return '$days일 전 삭제 · 복원 가능 $remaining일 남음';
    }
    return '$days일 전 삭제 · 만료 (복원 불가)';
  }

  String _groupNameFromSnapshot(GroupBackupModel backup) {
    final group = backup.snapshot['group'];
    if (group is Map) {
      final name = group['name'];
      if (name is String && name.trim().isNotEmpty) {
        return name.trim();
      }
    }
    return '삭제된 그룹';
  }

  Future<void> _confirmRestore(GroupBackupModel backup) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = GoRouter.of(context);
    final shouldRestore = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('그룹을 복원할까요?'),
        content: Text(
          '"${_groupNameFromSnapshot(backup)}" 그룹을 복원하면 새 그룹 ID로 다시 만들어집니다.\n'
          '기존 멤버·일정·댓글·권한위임 정보가 복원됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('복원'),
          ),
        ],
      ),
    );
    if (shouldRestore != true) {
      return;
    }
    try {
      final groupName = _groupNameFromSnapshot(backup);
      await _provider.restore(backup.id);
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text('"$groupName" 복원 완료')),
      );
      // restore RPC는 백업 행만 반환. 새 그룹은 새 group_id를 받아낸다.
      // 클라이언트에서 같은 이름의 active 그룹을 찾아 상세로 이동.
      final response = await Supabase.instance.client
          .from('groups')
          .select('id, name')
          .eq('name', groupName)
          .eq('status', 'active')
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      final groups = response;
      if (groups is Map<String, dynamic> && groups['id'] is String) {
        navigator.go(AppRoutes.groupDetailForId(groups['id'] as String));
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text('복원 실패: $error')),
      );
    }
  }

  Future<void> _confirmPermanentDelete(GroupBackupModel backup) async {
    final messenger = ScaffoldMessenger.of(context);
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('백업을 영구 삭제할까요?'),
        content: const Text(
          '백업을 삭제하면 더 이상 복원할 수 없습니다.\n'
          '이 작업은 되돌릴 수 없습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('영구 삭제'),
          ),
        ],
      ),
    );
    if (shouldDelete != true) {
      return;
    }
    try {
      await _provider.permanentlyDelete(backup.id);
      messenger.showSnackBar(
        const SnackBar(content: Text('백업을 영구 삭제했습니다.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text('삭제 실패: $error')),
      );
    }
  }

  bool _isExpired(GroupBackupModel backup) {
    // 보관(archive)은 만료 없이 항상 복원 가능.
    if (backup.isArchive) {
      return false;
    }
    final created = backup.createdAt;
    if (created == null) {
      return false;
    }
    final age = DateTime.now().toUtc().difference(created.toUtc());
    return age.inDays >= _defaultRetentionDays;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('보관 · 삭제된 그룹'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: _buildBody(theme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_provider.state == DeletedGroupsLoadState.loading &&
        _provider.backups.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_provider.state == DeletedGroupsLoadState.error) {
      return Padding(
        padding: const EdgeInsets.all(AppConstants.defaultPadding),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '보관 · 삭제된 그룹을 불러오지 못했어요.\n${_provider.lastError ?? ''}',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => _provider.load(),
              child: const Text('다시 시도'),
            ),
          ],
        ),
      );
    }
    if (_provider.backups.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppConstants.defaultPadding),
        child: Center(
          child: Text(
            '보관되거나 삭제된 그룹이 없습니다.\n그룹을 삭제하면 30일 동안, 보관한 그룹은 만료 없이 이 화면에서 복원할 수 있습니다.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _provider.load(),
      child: ListView.separated(
        padding: const EdgeInsets.all(AppConstants.defaultPadding),
        itemCount: _provider.backups.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final backup = _provider.backups[index];
          final isExpired = _isExpired(backup);
          return _DeletedGroupCard(
            backup: backup,
            groupName: _groupNameFromSnapshot(backup),
            description: _relativeDescription(backup),
            isExpired: isExpired,
            isRestoring: _provider.isRestoring(backup.id),
            isDeleting: _provider.isDeleting(backup.id),
            onRestore: isExpired
                ? null
                : () => _confirmRestore(backup),
            onDelete: () => _confirmPermanentDelete(backup),
          );
        },
      ),
    );
  }
}

class _DeletedGroupCard extends StatelessWidget {
  const _DeletedGroupCard({
    required this.backup,
    required this.groupName,
    required this.description,
    required this.isExpired,
    required this.isRestoring,
    required this.isDeleting,
    required this.onRestore,
    required this.onDelete,
  });

  final GroupBackupModel backup;
  final String groupName;
  final String description;
  final bool isExpired;
  final bool isRestoring;
  final bool isDeleting;
  final VoidCallback? onRestore;
  final VoidCallback onDelete;

  Widget _backupTypeChip(ThemeData theme) {
    final isArchive = backup.isArchive;
    final label = isArchive ? '보관됨' : '삭제됨';
    final bg = isArchive
        ? theme.colorScheme.secondaryContainer
        : theme.colorScheme.errorContainer;
    final fg = isArchive
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onErrorContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isExpired
              ? theme.colorScheme.error.withValues(alpha: 0.4)
              : PlanFlowColors.primaryFaint,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isExpired ? Icons.timer_off_outlined : Icons.history_outlined,
                  color: isExpired
                      ? theme.colorScheme.error
                      : PlanFlowColors.primaryMid,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    groupName,
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                _backupTypeChip(theme),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: isRestoring ? null : onRestore,
                    icon: isRestoring
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.restore, size: 18),
                    label: Text(isRestoring ? '복원 중…' : '복원하기'),
                    style: FilledButton.styleFrom(
                      backgroundColor: PlanFlowColors.primary,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: isDeleting ? null : onDelete,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('영구 삭제'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    side: BorderSide(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
