part of 'settings_screen.dart';

class _UnavailableSettingsRepository extends SettingsRepository {
  @override
  Future<UserSettingsModel?> fetchSettings(String userId) async => null;

  @override
  Future<UserSettingsModel> upsertSettings(UserSettingsModel settings) async {
    return settings;
  }
}

class _NaverCalDavCredentials {
  const _NaverCalDavCredentials({
    required this.naverId,
    required this.appPassword,
  });

  final String naverId;
  final String appPassword;
}

class _NaverCalDavImportRange {
  _NaverCalDavImportRange({
    required this.mode,
    required this.from,
    required this.to,
    required this.label,
  });

  factory _NaverCalDavImportRange.months(int months) {
    final now = DateTime.now().toUtc();
    return _NaverCalDavImportRange(
      mode: NaverCalDavSyncMode.custom,
      from: DateTime.utc(now.year, now.month - months, now.day),
      to: DateTime.utc(now.year, now.month + 6, now.day),
      label: '과거 $months개월',
    );
  }

  factory _NaverCalDavImportRange.years(int years) {
    final now = DateTime.now().toUtc();
    return _NaverCalDavImportRange(
      mode: NaverCalDavSyncMode.custom,
      from: DateTime.utc(now.year - years, now.month, now.day),
      to: DateTime.utc(now.year, now.month + 6, now.day),
      label: '과거 $years년',
    );
  }

  factory _NaverCalDavImportRange.all() {
    return _NaverCalDavImportRange(
      mode: NaverCalDavSyncMode.all,
      from: null,
      to: null,
      label: '전체',
    );
  }

  final NaverCalDavSyncMode mode;
  final DateTime? from;
  final DateTime? to;
  final String label;
}

class _AccountSection extends StatelessWidget {
  const _AccountSection({required this.authService, required this.onSignedOut});

  final AuthService? authService;
  final VoidCallback onSignedOut;

  @override
  Widget build(BuildContext context) {
    if (!AppEnv.isSupabaseReady) {
      return _SectionCard(
        title: '계정',
        subtitle: '현재 로그인 상태를 확인하고 필요하면 로그아웃할 수 있습니다.',
        child: Column(
          children: [
            const _StatusRow(
              label: '로그인 상태',
              value: '로그아웃됨',
              icon: Icons.account_circle_outlined,
              isConfigured: false,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => context.go(AppRoutes.login),
                child: const Text('로그인'),
              ),
            ),
          ],
        ),
      );
    }

    return _SectionCard(
      title: '계정',
      subtitle: '현재 로그인 상태를 확인하고 필요하면 로그아웃할 수 있습니다.',
      child: AnimatedBuilder(
        animation: authProvider,
        builder: (context, _) {
          final signedIn = authProvider.isSignedIn;
          return Column(
            children: [
              _StatusRow(
                label: '로그인 상태',
                value: signedIn ? authProvider.accountDisplayWithMethod : '로그아웃됨',
                icon: Icons.account_circle_outlined,
                isConfigured: signedIn,
              ),
              if (signedIn && authProvider.provider != null) ...[
                const SizedBox(height: 6),
                _AccountDetailText('로그인 방식: ${authProvider.providerLabel}'),
              ],
              if (authProvider.socialAccountInfoIncomplete) ...[
                const SizedBox(height: 8),
                const _InlineNotice(
                  icon: Icons.info_outline,
                  text:
                      '소셜 로그인은 되었지만 계정 이메일/이름을 확인하지 못했습니다. 제공 항목 동의나 provider 설정을 다시 확인해 주세요.',
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: signedIn
                    ? FilledButton(
                        key: const ValueKey('settings-logout-button'),
                        onPressed: () async {
                          await authService?.signOut();
                          onSignedOut();
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: PlanFlowColors.tertiaryAccent,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(48),
                        ),
                        child: const Text('로그아웃'),
                      )
                    : OutlinedButton(
                        onPressed: () => context.go(AppRoutes.login),
                        child: const Text('로그인'),
                      ),
              ),
              if (signedIn) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => context.push(AppRoutes.groups),
                    icon: const Icon(Icons.groups_outlined),
                    label: const Text('그룹 관리'),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

String _groupAutoSharePrefKey(String userId, String groupId) =>
    'planflow:group_auto_share:v1:$userId:$groupId';

/// 내가 리더로 있는 그룹에만 표시되는 "일정 등록 시 그룹에 자동 공유" 토글 목록.
/// [ConfirmScreen]/[EventEditScreen]의 리더 공유 확인 다이얼로그와 같은
/// SharedPreferences 키(_groupAutoSharePrefKey)를 그대로 읽고 쓴다.
class _LeaderGroupShareSection extends StatefulWidget {
  const _LeaderGroupShareSection({
    GroupContextProvider? provider,
    SharedPreferences? preferences,
    String? currentUserIdOverride,
  })  : _provider = provider,
        _preferences = preferences,
        _currentUserIdOverride = currentUserIdOverride;

  final GroupContextProvider? _provider;
  final SharedPreferences? _preferences;
  final String? _currentUserIdOverride;

  @override
  State<_LeaderGroupShareSection> createState() =>
      _LeaderGroupShareSectionState();
}

class _LeaderGroupShareSectionState extends State<_LeaderGroupShareSection> {
  late final GroupContextProvider _provider;
  late final bool _ownsProvider;
  final Map<String, bool> _decidedValues = <String, bool>{};
  final Set<String> _decidedGroupIds = <String>{};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _ownsProvider = widget._provider == null;
    _provider = widget._provider ?? GroupContextProvider();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (_ownsProvider) {
      _provider.dispose();
    }
    super.dispose();
  }

  String? get _userId => widget._currentUserIdOverride ?? authProvider.userId;

  Future<void> _load() async {
    final userId = _userId?.trim();
    if (userId == null || userId.isEmpty) {
      if (mounted) {
        setState(() {
          _loaded = true;
        });
      }
      return;
    }

    await _provider.load(userId);
    if (!mounted) {
      return;
    }

    final leaderGroups = _provider.leaderGroups;
    if (leaderGroups.isEmpty) {
      setState(() {
        _loaded = true;
      });
      return;
    }

    final preferences =
        widget._preferences ?? await SharedPreferences.getInstance();
    final values = <String, bool>{};
    final decided = <String>{};
    for (final group in leaderGroups) {
      final key = _groupAutoSharePrefKey(userId, group.id);
      values[group.id] = preferences.getBool(key) ?? false;
      if (preferences.containsKey(key)) {
        decided.add(group.id);
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _decidedValues
        ..clear()
        ..addAll(values);
      _decidedGroupIds
        ..clear()
        ..addAll(decided);
      _loaded = true;
    });
  }

  Future<void> _toggle(String groupId, bool value) async {
    final userId = _userId?.trim();
    if (userId == null || userId.isEmpty) {
      return;
    }
    final preferences =
        widget._preferences ?? await SharedPreferences.getInstance();
    await preferences.setBool(
      _groupAutoSharePrefKey(userId, groupId),
      value,
    );
    if (mounted) {
      setState(() {
        _decidedValues[groupId] = value;
        _decidedGroupIds.add(groupId);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const SizedBox.shrink();
    }
    final leaderGroups = _provider.leaderGroups;
    if (leaderGroups.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      children: [
        const SizedBox(height: 16),
        _SectionCard(
          title: '내가 리더로 있는 그룹에 일정공유',
          subtitle: '새 일정을 등록할 때 아래 그룹에 자동으로 공유할지 정합니다.',
          child: Column(
            children: [
              for (var i = 0; i < leaderGroups.length; i += 1) ...[
                SwitchListTile(
                  key: ValueKey(
                    'settings-leader-group-share-toggle-${leaderGroups[i].id}',
                  ),
                  contentPadding: EdgeInsets.zero,
                  title: Text(leaderGroups[i].name),
                  subtitle: Text(_subtitleFor(leaderGroups[i].id)),
                  value: _decidedValues[leaderGroups[i].id] ?? false,
                  onChanged: (value) => _toggle(leaderGroups[i].id, value),
                ),
                if (i != leaderGroups.length - 1) const Divider(height: 1),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _subtitleFor(String groupId) {
    if (!_decidedGroupIds.contains(groupId)) {
      return '아직 정하지 않았어요. 리더로 일정을 등록할 때 물어봐요.';
    }
    return (_decidedValues[groupId] ?? false)
        ? '새 일정을 이 그룹에도 자동 공유해요.'
        : '새 일정을 이 그룹에 공유하지 않아요.';
  }
}

@visibleForTesting
bool shouldShowNaverAccountRecheck({
  required bool signedIn,
  required bool isNaverAccount,
  required bool socialAccountInfoIncomplete,
}) {
  return signedIn && isNaverAccount && socialAccountInfoIncomplete;
}

class _NaverGuideThumbnail extends StatelessWidget {
  const _NaverGuideThumbnail({required this.title, required this.assetPath});

  final String title;
  final String assetPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () =>
          _showNaverGuideImage(context, title: title, assetPath: assetPath),
      borderRadius: BorderRadius.circular(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: PlanFlowColors.primary,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: 1.55,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: PlanFlowColors.primaryFaint),
                ),
                child: Image.asset(
                  assetPath,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return const Center(
                      child: Icon(
                        Icons.image_not_supported_outlined,
                        color: PlanFlowColors.textSecondary,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _showNaverGuideImage(
  BuildContext context, {
  required String title,
  required String assetPath,
}) async {
  await showDialog<void>(
    context: context,
    builder: (context) {
      return Dialog.fullscreen(
        backgroundColor: const Color(0xFF101820),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                ),
                      ),
                    ),
                    IconButton(
                      tooltip: '닫기',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: InteractiveViewer(
                  minScale: 0.7,
                  maxScale: 4,
                  child: Center(
                    child: Image.asset(assetPath, fit: BoxFit.contain),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child, this.subtitle});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                color: PlanFlowColors.primary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _PrepTimeInputDialog extends StatefulWidget {
  const _PrepTimeInputDialog({required this.initialValue});

  final int initialValue;

  @override
  State<_PrepTimeInputDialog> createState() => _PrepTimeInputDialogState();
}

class _PrepTimeInputDialogState extends State<_PrepTimeInputDialog> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue.toString());
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = int.tryParse(_controller.text.trim());
    if (parsed == null) {
      setState(() {
        _errorText = '준비 시간을 숫자로 입력해 주세요.';
      });
      return;
    }
    if (parsed < 5 || parsed > 240) {
      setState(() {
        _errorText = '5분부터 240분 사이로 입력해 주세요.';
      });
      return;
    }
    Navigator.of(context).pop(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('준비 시간 직접 입력'),
      content: SingleChildScrollView(
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          keyboardType: TextInputType.number,
          autofocus: true,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: '분 단위',
            hintText: '예: 50',
            errorText: _errorText,
          ),
          onChanged: (_) {
            if (_errorText != null) {
              setState(() {
                _errorText = null;
              });
            }
          },
          onSubmitted: (_) => _submit(),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actions: [
        PlanFlowActionButtons(
          buttons: [
            PlanFlowActionButton(
              label: '취소',
              onPressed: () => Navigator.of(context).pop(),
              type: ActionButtonType.secondary,
              flex: 1,
            ),
            PlanFlowActionButton(
              label: '저장',
              onPressed: _submit,
              type: ActionButtonType.primary,
              flex: 1,
            ),
          ],
        ),
      ],
    );
  }
}

class _SmartAlarmControl extends StatelessWidget {
  const _SmartAlarmControl({
    required this.title,
    required this.helperText,
    required this.child,
  });

  final String title;
  final String helperText;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            color: PlanFlowColors.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          helperText,
          style: theme.textTheme.bodySmall?.copyWith(
            color: PlanFlowColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _TimeSettingTile extends StatelessWidget {
  const _TimeSettingTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.icon,
    required this.onTap,
    this.trailingAction,
  });

  final String title;
  final String subtitle;
  final String value;
  final IconData icon;
  final VoidCallback onTap;
  final Widget? trailingAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: PlanFlowColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: PlanFlowColors.primaryMid),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: PlanFlowColors.primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              value,
              style: theme.textTheme.titleSmall?.copyWith(
                color: PlanFlowColors.primaryMid,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, color: PlanFlowColors.primaryMid),
            if (trailingAction != null) ...[
              const SizedBox(width: 4),
              trailingAction!,
            ],
          ],
        ),
      ),
    );
  }
}

class _BriefingTestButton extends StatelessWidget {
  const _BriefingTestButton({
    required this.isLoading,
    required this.tooltip,
    required this.onPressed,
  });

  final bool isLoading;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: isLoading ? null : onPressed,
      icon: isLoading
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.play_arrow_outlined),
    );
  }
}

class _NaverDiagnosticCountTable extends StatelessWidget {
  const _NaverDiagnosticCountTable({required this.diagnostics});

  final NaverCalDavSyncDiagnostics diagnostics;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, int)>[
      ('읽음', diagnostics.rawEvents),
      ('파싱 성공', diagnostics.parsedEvents),
      ('파싱 실패', diagnostics.invalidEvents),
      ('저장 대상', diagnostics.saveCandidates),
      ('저장', diagnostics.saved),
      ('중복 스킵', diagnostics.duplicateSkipped),
      ('변경 없음', diagnostics.unchangedSkipped),
      ('실패', diagnostics.failed),
    ];
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PlanFlowColors.primaryFaint),
      ),
      child: Wrap(
        children: rows.map((row) {
          return SizedBox(
            width: 132,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.$1,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                  ),
                  Text(
                    '${row.$2}개',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: PlanFlowColors.primary,
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                ],
              ),
            ),
          );
        }).toList(growable: false),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.label,
    required this.value,
    required this.icon,
    required this.isConfigured,
    this.onInfo,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool isConfigured;
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        isConfigured ? const Color(0xFF1F8A4C) : PlanFlowColors.textSecondary;
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: PlanFlowColors.primary,
                      ),
                    ),
                  ),
                  if (onInfo != null) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: onInfo,
                      child: const Icon(
                        Icons.info_outline,
                        size: 18,
                        color: PlanFlowColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(value, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Icon(
          isConfigured
              ? Icons.check_circle_outline
              : Icons.remove_circle_outline,
          color: color,
        ),
      ],
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF4FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFBFDDF7)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: PlanFlowColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountDetailText extends StatelessWidget {
  const _AccountDetailText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 52),
        child: Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: PlanFlowColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
