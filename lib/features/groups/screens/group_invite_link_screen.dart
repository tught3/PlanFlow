import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/theme.dart';
import '../providers/group_invite_provider.dart';

class GroupInviteLinkScreen extends StatefulWidget {
  const GroupInviteLinkScreen({
    super.key,
    required this.groupId,
    required this.inviteToken,
    GroupInviteProvider? provider,
  }) : _provider = provider;

  final String groupId;
  final String inviteToken;
  final GroupInviteProvider? _provider;

  @override
  State<GroupInviteLinkScreen> createState() => _GroupInviteLinkScreenState();
}

class _GroupInviteLinkScreenState extends State<GroupInviteLinkScreen> {
  late final GroupInviteProvider _provider;
  late final bool _ownsProvider;
  bool _isJoining = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ownsProvider = widget._provider == null;
    _provider = widget._provider ?? GroupInviteProvider();
  }

  @override
  void dispose() {
    if (_ownsProvider) {
      _provider.dispose();
    }
    super.dispose();
  }

  Future<void> _join() async {
    setState(() {
      _isJoining = true;
      _error = null;
    });
    try {
      await _provider.acceptInviteLink(
        groupId: widget.groupId,
        inviteToken: widget.inviteToken,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('그룹에 참여했어요.')),
      );
      context.go(AppRoutes.groupDetailForId(widget.groupId));
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = _friendlyJoinError(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isJoining = false;
        });
      }
    }
  }

  String _friendlyJoinError(Object error) {
    final message = error.toString();
    if (message.contains('group_invites_target') ||
        message.contains('check constraint')) {
      return '초대 처리 중 서버 설정이 맞지 않았어요. 잠시 후 다시 시도해 주세요.';
    }
    if (message.contains('이미 활성 멤버')) {
      return '이미 이 그룹의 멤버예요.';
    }
    if (message.contains('초대 링크가 유효하지')) {
      return '초대 링크가 만료되었거나 유효하지 않아요.';
    }
    if (message.contains('로그인이 필요')) {
      return '로그인 후 다시 참여해 주세요.';
    }
    return '그룹 참여에 실패했어요. 잠시 후 다시 시도해 주세요.';
  }

  @override
  Widget build(BuildContext context) {
    final invalidLink =
        widget.groupId.trim().isEmpty || widget.inviteToken.trim().isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('그룹 초대'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.group_add_outlined,
                    color: PlanFlowColors.primary,
                    size: 32,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '그룹 초대 링크를 열었어요',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    invalidLink
                        ? '초대 링크 정보가 올바르지 않아요.'
                        : '아래 버튼을 누르면 이 그룹에 멤버로 참여합니다.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: const Color(0xFFB42318),
                          ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    key: const ValueKey('group-invite-link-join-button'),
                    onPressed: invalidLink || _isJoining ? null : _join,
                    icon: _isJoining
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login_outlined),
                    label: Text(_isJoining ? '참여 중...' : '그룹 참여하기'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
