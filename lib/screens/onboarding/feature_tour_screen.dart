import 'package:flutter/material.dart';
import 'package:planflow/l10n/app_localizations.dart';

import '../../core/theme.dart';
import '../../services/feature_tour_service.dart';

/// Interactive practice tour.
///
/// Step 1: title plus a sample date/time that can be edited, confirmed with an
/// explicit create action. Step 2: local time picker plus a quick "+30
/// minutes" shortcut; cancelling the picker preserves the current value and
/// confirming applies the edit. Step 3: live preparation/departure preview
/// built from example values (travel 20 min + buffer 10 min, preparation 15
/// minutes earlier) - it is an example, not a real route.
///
/// All practice data stays in memory. The only persistence is the completion
/// marker written through [FeatureTourStore.markCompleted] when the user
/// explicitly chooses Skip or Finish. System back never completes the tour
/// implicitly, Restart resets the draft without writing, and a failed save
/// shows an inline retry instead of trapping or duplicating the write.
class FeatureTourScreen extends StatefulWidget {
  const FeatureTourScreen({
    super.key,
    this.store = const SharedPreferencesFeatureTourStore(),
    this.onCompleted,
    this.requireFinalConfirmation = false,
    this.nowProvider,
  });

  final FeatureTourStore store;
  final VoidCallback? onCompleted;
  final bool requireFinalConfirmation;

  /// Injectable clock so widget tests can exercise relative dates and the
  /// midnight rollover without hardcoding calendar dates.
  final DateTime Function()? nowProvider;

  @override
  State<FeatureTourScreen> createState() => _FeatureTourScreenState();
}

class _FeatureTourScreenState extends State<FeatureTourScreen> {
  static const int _stepCount = 3;
  static const Duration _travelTime = Duration(minutes: 20);
  static const Duration _bufferTime = Duration(minutes: 10);
  static const Duration _prepBeforeDeparture = Duration(minutes: 15);
  static const Duration _quickForward = Duration(minutes: 30);

  final TextEditingController _titleController = TextEditingController();

  int _step = 0;
  DateTime? _sampleTime;
  bool _created = false;
  bool _titleMissing = false;
  bool _timeConfirmed = false;
  bool _showRestarted = false;
  bool _saveInFlight = false;
  bool _saveCompleted = false;
  bool _saveFailed = false;

  DateTime get _now => (widget.nowProvider ?? DateTime.now)();

  /// Default draft is the next full hour, always relative to the clock.
  DateTime _defaultSampleTime() {
    final now = _now;
    return DateTime(now.year, now.month, now.day, now.hour + 1);
  }

  DateTime get _currentDraft => _sampleTime ?? _defaultSampleTime();

  DateTime _departureFor(DateTime sample) =>
      sample.subtract(_travelTime + _bufferTime);

  DateTime _prepFor(DateTime sample) =>
      sample.subtract(_travelTime + _bufferTime + _prepBeforeDeparture);

  String _formatStamp(DateTime time) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${twoDigits(time.month)}/${twoDigits(time.day)} '
        '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  // Explicit decisions (skip / finish) --------------------------------------

  /// Sole persistence path: an explicit Skip or Finish tap. Duplicate saves
  /// (double tap, retry after success) are ignored.
  Future<void> _completeTour() async {
    if (_saveInFlight || _saveCompleted) return;
    _saveInFlight = true;
    if (mounted) {
      setState(() {
        _saveFailed = false;
        _showRestarted = false;
      });
    }
    try {
      await widget.store.markCompleted();
      // The store returns normally even when the write was swallowed
      // (unavailable prefs or a setBool error), so a normal return does not
      // prove the marker persisted. Probe the flag and only report
      // completion once it really reads back as saved.
      final stillPending = await widget.store.shouldShow();
      if (stillPending) {
        if (!mounted) return;
        setState(() {
          _saveInFlight = false;
          _saveFailed = true;
        });
        return;
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saveInFlight = false;
        _saveFailed = true;
      });
      return;
    }
    _saveInFlight = false;
    if (!mounted) return;
    setState(() => _saveCompleted = true);
    // Rebuild the pop guard before dispatching explicit completion.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.onCompleted != null) {
        widget.onCompleted!();
      } else {
        Navigator.of(context).pop();
      }
    });
  }

  /// Restarts the practice (draft, controllers, step) without any writes.
  void _restartTour() {
    if (_saveInFlight || _saveCompleted) return;
    setState(() {
      _step = 0;
      _titleController.clear();
      _sampleTime = null;
      _created = false;
      _titleMissing = false;
      _timeConfirmed = false;
      _saveFailed = false;
      _showRestarted = true;
    });
  }

  // Step navigation ----------------------------------------------------------

  void _goNext() {
    if (_step >= _stepCount - 1) return;
    setState(() {
      _step += 1;
      _showRestarted = false;
    });
  }

  void _goBack() {
    if (_step == 0) return;
    setState(() {
      _step -= 1;
      _showRestarted = false;
    });
  }

  // Step 1: create the sample ------------------------------------------------

  void _createSample() {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() {
        _titleMissing = true;
        _created = false;
      });
      return;
    }
    setState(() {
      _sampleTime ??= _currentDraft;
      _created = true;
      _titleMissing = false;
      _showRestarted = false;
    });
  }

  // Editing helpers ----------------------------------------------------------

  Future<void> _pickSampleDate() async {
    final draft = _currentDraft;
    final now = _now;
    final picked = await showDatePicker(
      context: context,
      initialDate: draft,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (picked == null || !mounted) return; // Cancel preserves the value.
    setState(() {
      _sampleTime = DateTime(
          picked.year, picked.month, picked.day, draft.hour, draft.minute);
      _timeConfirmed = false;
    });
  }

  Future<void> _pickSampleTime() async {
    final draft = _currentDraft;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(draft),
    );
    if (picked == null || !mounted) return; // Cancel preserves the value.
    setState(() {
      _sampleTime = DateTime(
          draft.year, draft.month, draft.day, picked.hour, picked.minute);
      _timeConfirmed = false;
    });
  }

  void _addThirtyMinutes() {
    setState(() {
      _sampleTime = _currentDraft.add(_quickForward);
      _timeConfirmed = false;
      _showRestarted = false;
    });
  }

  void _confirmTimeEdit() {
    setState(() {
      _sampleTime ??= _currentDraft;
      _timeConfirmed = true;
      _showRestarted = false;
    });
  }

  // Build --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isLastStep = _step == _stepCount - 1;
    final busy = _saveInFlight || _saveCompleted;
    return PopScope(
      canPop: _saveCompleted,
      onPopInvokedWithResult: (didPop, result) {
        // System back never completes the tour implicitly; leaving requires
        // an explicit Skip or Finish decision.
      },
      child: Scaffold(
        backgroundColor: PlanFlowColors.background,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton.icon(
                      key: const ValueKey('feature-tour-restart-button'),
                      onPressed: busy ? null : _restartTour,
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.featureTourRestart),
                    ),
                    TextButton(
                      key: const ValueKey('feature-tour-skip-button'),
                      onPressed: busy ? null : _completeTour,
                      child: Text(l10n.featureTourSkip),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.featureTourStep(_step + 1),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: PlanFlowColors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: SingleChildScrollView(
                    key: ValueKey('feature-tour-step-$_step'),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: _buildStep(context, l10n),
                  ),
                ),
                if (_saveFailed)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.featureTourSaveFailed,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                    color: Theme.of(context).colorScheme.error),
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('feature-tour-save-retry-button'),
                          onPressed: _completeTour,
                          child: Text(l10n.featureTourSaveRetry),
                        ),
                      ],
                    ),
                  ),
                if (_showRestarted)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      l10n.featureTourRestarted,
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: PlanFlowColors.textSecondary),
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List<Widget>.generate(
                    _stepCount,
                    (index) => AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: _step == index ? 20 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _step == index
                            ? PlanFlowColors.primary
                            : PlanFlowColors.primaryFaint,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    if (_step > 0) ...[
                      OutlinedButton(
                        key: const ValueKey('feature-tour-back-button'),
                        onPressed: busy ? null : _goBack,
                        child: Text(l10n.featureTourBack),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: FilledButton(
                        key: const ValueKey('feature-tour-next-button'),
                        onPressed: busy || (_step == 0 && !_created)
                            ? null
                            : (isLastStep ? _completeTour : _goNext),
                        child: Text(isLastStep
                            ? l10n.featureTourFinish
                            : l10n.featureTourNext),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStep(BuildContext context, AppLocalizations l10n) {
    switch (_step) {
      case 0:
        return _buildCreateStep(context, l10n);
      case 1:
        return _buildEditStep(context, l10n);
      default:
        return _buildPreviewStep(context, l10n);
    }
  }

  Widget _buildCreateStep(BuildContext context, AppLocalizations l10n) {
    final draft = _currentDraft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepHeader(
          icon: Icons.edit_calendar_outlined,
          title: l10n.featureTourCreateTitle,
          hint: l10n.featureTourCreateHint,
        ),
        const SizedBox(height: 20),
        TextField(
          key: const ValueKey('feature-tour-title-field'),
          controller: _titleController,
          textInputAction: TextInputAction.done,
          onChanged: (_) {
            if (_titleMissing) {
              setState(() => _titleMissing = false);
            }
          },
          decoration: InputDecoration(
            labelText: l10n.featureTourTitleLabel,
            errorText: _titleMissing ? l10n.featureTourTitleRequired : null,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        _SampleRow(
          label: l10n.featureTourDateLabel,
          value: _formatStamp(draft),
          actionLabel: l10n.featureTourChooseDate,
          actionKey: const ValueKey('feature-tour-pick-date-button'),
          onAction: _pickSampleDate,
        ),
        const SizedBox(height: 10),
        _SampleRow(
          label: l10n.featureTourSampleTime,
          value: _formatStamp(draft),
          actionLabel: l10n.featureTourChooseTime,
          actionKey: const ValueKey('feature-tour-pick-time-button'),
          onAction: _pickSampleTime,
        ),
        const SizedBox(height: 20),
        FilledButton.tonal(
          key: const ValueKey('feature-tour-create-button'),
          onPressed: _createSample,
          child: Text(l10n.featureTourCreateAction),
        ),
        if (_created) ...[
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.check_circle_outline,
                  size: 18, color: PlanFlowColors.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '${_titleController.text.trim()} · ${_formatStamp(_currentDraft)}',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: PlanFlowColors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.featureTourSample,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: PlanFlowColors.textSecondary),
          ),
        ],
      ],
    );
  }

  Widget _buildEditStep(BuildContext context, AppLocalizations l10n) {
    final draft = _currentDraft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepHeader(
          icon: Icons.schedule_outlined,
          title: l10n.featureTourEditTitle,
          hint: l10n.featureTourEditHint,
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: PlanFlowColors.primaryFaint,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              Text(
                l10n.featureTourSampleTime,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: PlanFlowColors.textSecondary),
              ),
              const SizedBox(height: 6),
              Text(
                _formatStamp(draft),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: PlanFlowColors.textPrimary,
                      fontWeight: FontWeight.w800,
                    ),
              ),
              if (_timeConfirmed) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.check_circle_outline,
                        size: 16, color: PlanFlowColors.primary),
                    const SizedBox(width: 4),
                    Text(
                      l10n.featureTourConfirmTime,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: PlanFlowColors.primary),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          key: const ValueKey('feature-tour-pick-time-button'),
          onPressed: _pickSampleTime,
          icon: const Icon(Icons.access_time),
          label: Text(l10n.featureTourChooseTime),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const ValueKey('feature-tour-plus-30-button'),
          onPressed: _addThirtyMinutes,
          icon: const Icon(Icons.update),
          label: Text(l10n.featureTourAddThirty),
        ),
        const SizedBox(height: 10),
        FilledButton.tonal(
          key: const ValueKey('feature-tour-confirm-time-button'),
          onPressed: _confirmTimeEdit,
          child: Text(l10n.featureTourConfirmTime),
        ),
      ],
    );
  }

  Widget _buildPreviewStep(BuildContext context, AppLocalizations l10n) {
    final sample = _currentDraft;
    final departure = _departureFor(sample);
    final prep = _prepFor(sample);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepHeader(
          icon: Icons.notifications_active_outlined,
          title: l10n.featureTourPreviewTitle,
          hint: l10n.featureTourPreviewHint,
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: PlanFlowColors.primaryFaint),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PreviewRow(
                  label: l10n.featureTourPrep, stamp: _formatStamp(prep)),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Divider(height: 1),
              ),
              _PreviewRow(
                  label: l10n.featureTourDeparture,
                  stamp: _formatStamp(departure)),
              const SizedBox(height: 12),
              Text(
                '${_titleController.text.trim()} · ${_formatStamp(sample)}',
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: PlanFlowColors.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          l10n.featureTourSample,
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: PlanFlowColors.textSecondary),
        ),
      ],
    );
  }
}

class _StepHeader extends StatelessWidget {
  const _StepHeader({
    required this.icon,
    required this.title,
    required this.hint,
  });

  final IconData icon;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: const BoxDecoration(
            color: PlanFlowColors.primaryFaint,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 30, color: PlanFlowColors.primary),
        ),
        const SizedBox(height: 14),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: PlanFlowColors.textPrimary,
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 6),
        Text(
          hint,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
                height: 1.4,
              ),
        ),
      ],
    );
  }
}

class _SampleRow extends StatelessWidget {
  const _SampleRow({
    required this.label,
    required this.value,
    required this.actionLabel,
    required this.actionKey,
    required this.onAction,
  });

  final String label;
  final String value;
  final String actionLabel;
  final Key actionKey;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PlanFlowColors.primaryFaint),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: PlanFlowColors.textSecondary),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: PlanFlowColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
          ),
          TextButton(
            key: actionKey,
            onPressed: onAction,
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.label, required this.stamp});

  final String label;
  final String stamp;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: PlanFlowColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        Text(
          stamp,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w800,
              ),
        ),
      ],
    );
  }
}
