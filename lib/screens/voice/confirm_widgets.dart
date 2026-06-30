part of 'confirm_screen.dart';

class _ConfirmBottomNavigation extends StatelessWidget {
  const _ConfirmBottomNavigation({
    required this.onHome,
    required this.onCalendar,
    required this.onSettings,
  });

  final VoidCallback onHome;
  final VoidCallback onCalendar;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: 1,
      onDestinationSelected: (index) {
        switch (index) {
          case 0:
            onHome();
            break;
          case 1:
            onCalendar();
            break;
          case 2:
            onSettings();
            break;
        }
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: '홈',
        ),
        NavigationDestination(
          icon: Icon(Icons.event_note_outlined),
          selectedIcon: Icon(Icons.event_note),
          label: '일정',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: '설정',
        ),
      ],
    );
  }
}

class _PreActionDraft {
  _PreActionDraft.auto({String? title, int? offsetHours})
      : isAuto = true,
        key = GlobalKey(),
        titleController = TextEditingController(text: title ?? ''),
        offsetController = TextEditingController(
          text: (offsetHours ?? 1).toString(),
        ),
        titleFocusNode = FocusNode();

  final bool isAuto;
  final GlobalKey key;
  final TextEditingController titleController;
  final TextEditingController offsetController;
  final FocusNode titleFocusNode;

  void dispose() {
    titleController.dispose();
    offsetController.dispose();
    titleFocusNode.dispose();
  }
}

class _SupplyDraft {
  _SupplyDraft(String title)
      : key = GlobalKey(),
        titleController = TextEditingController(text: title),
        focusNode = FocusNode();

  final GlobalKey key;
  final TextEditingController titleController;
  final FocusNode focusNode;

  void dispose() {
    titleController.dispose();
    focusNode.dispose();
  }
}

class _SuppliesEditor extends StatelessWidget {
  const _SuppliesEditor({
    required this.supplies,
    required this.newSupplyController,
    required this.newSupplyFocusNode,
    required this.errorText,
    required this.onAdd,
    required this.onRemove,
  });

  final List<_SupplyDraft> supplies;
  final TextEditingController newSupplyController;
  final FocusNode newSupplyFocusNode;
  final String? errorText;
  final VoidCallback onAdd;
  final ValueChanged<_SupplyDraft> onRemove;

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
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '준비물',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '일정에 필요한 준비물을 한 줄씩 정리해 주세요. 실제 체크는 일정 상세에서 할 수 있어요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            if (supplies.isEmpty)
              Text(
                '아직 준비물이 없어요. 아래에서 하나씩 추가해 보세요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
              )
            else ...[
              Column(
                children: supplies
                    .map(
                      (draft) => _SupplyInputRow(
                        draft: draft,
                        onDelete: () => onRemove(draft),
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: newSupplyController,
                    focusNode: newSupplyFocusNode,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: '준비물 추가',
                      hintText: '예: 물, 여권, 충전기',
                      helperText: '입력 후 추가 버튼을 누르세요.',
                      border: const OutlineInputBorder(),
                      errorText: errorText,
                    ),
                    onSubmitted: (_) {
                      onAdd();
                      FocusScope.of(context).unfocus();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    onPressed: onAdd,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(72, 56),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    child: const Text('추가'),
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

class _SupplyInputRow extends StatelessWidget {
  const _SupplyInputRow({required this.draft, required this.onDelete});

  final _SupplyDraft draft;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: PlanFlowColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: PlanFlowColors.primaryFaint, width: 0.6),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(
              Icons.backpack_outlined,
              size: 18,
              color: PlanFlowColors.primaryMid,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: draft.titleController,
                focusNode: draft.focusNode,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => FocusScope.of(context).unfocus(),
                style: theme.textTheme.bodyMedium,
                decoration: const InputDecoration(
                  hintText: '준비물 입력',
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 6),
                ),
                maxLines: 1,
              ),
            ),
            IconButton(
              tooltip: '삭제',
              onPressed: onDelete,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

