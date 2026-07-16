import 'package:flutter/material.dart';

import '../../../core/theme.dart';

/// 그룹 다중 선택 시트에 넘길 옵션(그룹 id + 표시 이름).
class GroupSelectOption {
  const GroupSelectOption({required this.id, required this.name});
  final String id;
  final String name;
}

/// 그룹 다중 선택 바텀시트.
///
/// 확인 시 선택된 그룹 id 집합을 반환하고, 취소하면 null을 반환한다.
/// 생성(공유할 그룹 선택)·수정/삭제(반영할 그룹 선택) 화면에서 공용으로 쓴다.
Future<Set<String>?> showGroupMultiSelectSheet(
  BuildContext context, {
  required List<GroupSelectOption> options,
  required Set<String> initiallySelected,
  String title = '공유할 그룹 선택',
  String confirmLabel = '확인',
  bool allowEmpty = false,
}) {
  return showModalBottomSheet<Set<String>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _GroupMultiSelectSheet(
      options: options,
      initiallySelected: initiallySelected,
      title: title,
      confirmLabel: confirmLabel,
      allowEmpty: allowEmpty,
    ),
  );
}

class _GroupMultiSelectSheet extends StatefulWidget {
  const _GroupMultiSelectSheet({
    required this.options,
    required this.initiallySelected,
    required this.title,
    required this.confirmLabel,
    required this.allowEmpty,
  });

  final List<GroupSelectOption> options;
  final Set<String> initiallySelected;
  final String title;
  final String confirmLabel;
  final bool allowEmpty;

  @override
  State<_GroupMultiSelectSheet> createState() => _GroupMultiSelectSheetState();
}

class _GroupMultiSelectSheetState extends State<_GroupMultiSelectSheet> {
  late final Set<String> _selected =
      Set<String>.from(widget.initiallySelected);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canConfirm = widget.allowEmpty || _selected.isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                fontSize: (theme.textTheme.titleMedium?.fontSize ?? 16) + 2,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.options.length,
                itemBuilder: (context, index) {
                  final option = widget.options[index];
                  final checked = _selected.contains(option.id);
                  return CheckboxListTile(
                    value: checked,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(option.name),
                    onChanged: (value) {
                      setState(() {
                        if (value == true) {
                          _selected.add(option.id);
                        } else {
                          _selected.remove(option.id);
                        }
                      });
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('취소'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: PlanFlowColors.primary,
                    ),
                    onPressed: canConfirm
                        ? () => Navigator.of(context)
                            .pop(Set<String>.from(_selected))
                        : null,
                    child: Text(widget.confirmLabel),
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
