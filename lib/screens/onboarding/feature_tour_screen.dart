import 'dart:async';

import 'package:flutter/material.dart';
import 'package:planflow/l10n/app_localizations.dart';

import '../../core/theme.dart';
import '../../services/feature_tour_service.dart';
import 'voice_first_tour_controller.dart';
import 'voice_first_tour_voice_capture.dart';

/// Voice-first practice tour.
///
/// The old manual form/picker tour is replaced by a guided voice flow with
/// four phases, each driven by a real capture session through [VoiceCapture]
/// (production default: [SttServiceVoiceCapture] over the unchanged
/// `SttService`; the microphone only starts on an explicit mic tap):
///  1. create - speak a full schedule ("내일 오전 9시에 강남역에서 팀장님과
///     면담"), review the structured preview, then SAVE explicitly.
///  2. query  - speak a query ("내일 일정 보여줘") and see the actually
///     saved records in their rendered order.
///  3. edit   - speak an ordinal edit ("첫 번째 일정 오후 1시로 미뤄줘"),
///     preview the time change, then SAVE explicitly.
///  4. detail - open the SAME saved record and see its stored
///     departure/preparation times derived from EXAMPLE assumptions.
///
/// Partials are display-only; only a final transcript is parsed and nothing
/// is committed without an explicit Save. A typed fallback exists only when
/// the user explicitly selects text mode (initially blank, clearly labeled
/// "not voice") and runs the exact same parser pipeline. All practice data
/// stays in memory; the only persistence is the completion marker written
/// through [FeatureTourStore.markCompleted] on explicit Skip/Finish, with
/// saved read-back verification, inline retry, and duplicate protection.
/// System back never completes the tour implicitly; Restart clears the
/// in-memory practice state and cancels this screen's own microphone
/// session without touching anyone else's STT.
class FeatureTourScreen extends StatefulWidget {
  const FeatureTourScreen({
    super.key,
    this.store = const SharedPreferencesFeatureTourStore(),
    this.onCompleted,
    this.requireFinalConfirmation = false,
    this.nowProvider,
    this.voiceCapture,
  });

  final FeatureTourStore store;
  final VoidCallback? onCompleted;
  final bool requireFinalConfirmation;

  /// Injectable clock so widget tests can exercise relative dates without
  /// hardcoding calendar dates. Frozen once per tour session by the
  /// controller.
  final DateTime Function()? nowProvider;

  /// Injectable capture seam. Production leaves this null and the screen
  /// owns a lazily-started [SttServiceVoiceCapture].
  final VoiceCapture? voiceCapture;

  @override
  State<FeatureTourScreen> createState() => _FeatureTourScreenState();
}

enum _TourPhase { create, query, edit, detail }

class _FeatureTourScreenState extends State<FeatureTourScreen> {
  final TextEditingController _textController = TextEditingController();

  late final VoiceCapture _capture;
  late final bool _ownsCapture;
  late final VoiceFirstTourController _controller;

  _TourPhase _phase = _TourPhase.create;

  /// Session token: bumped on every cancel/restart/dispose so late capture
  /// results can never mutate a newer UI state.
  int _sessionToken = 0;
  bool _micActive = false;
  bool _micReady = false;
  bool _micFinalizing = false;
  String? _caption;
  String? _statusMessage;

  bool _textMode = false;
  bool _hasQueried = false;
  bool _detailViewed = false;
  int? _practiceEventId;
  int? _updatedId;

  bool _saveInFlight = false;
  bool _saveCompleted = false;
  bool _saveFailed = false;
  bool _showRestarted = false;

  @override
  void initState() {
    super.initState();
    _capture = widget.voiceCapture ?? SttServiceVoiceCapture();
    _ownsCapture = widget.voiceCapture == null;
    _controller = VoiceFirstTourController(nowProvider: widget.nowProvider);
  }

  @override
  void dispose() {
    _sessionToken++;
    _micActive = false;
    _micReady = false;
    _controller.dispose();
    _textController.dispose();
    final capture = _capture;
    if (_ownsCapture && capture is SttServiceVoiceCapture) {
      capture.dispose(); // resolves own listen, cancels own native session
    } else {
      unawaited(capture.cancel().catchError((Object _) {}));
    }
    super.dispose();
  }

  bool get _busy => _saveInFlight || _saveCompleted;

  // Explicit completion (skip / finish) --------------------------------------

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

  /// Restarts the practice without any writes: clears the in-memory events,
  /// previews and captions, cancels this screen's OWN microphone session,
  /// and never touches the completion marker.
  Future<void> _restartTour() async {
    if (_busy) return;
    await _cancelMicSession();
    if (!mounted) return;
    setState(() {
      _controller.restart();
      _phase = _TourPhase.create;
      _hasQueried = false;
      _detailViewed = false;
      _practiceEventId = null;
      _updatedId = null;
      _caption = null;
      _statusMessage = null;
      _textMode = false;
      _textController.clear();
      _showRestarted = true;
    });
  }

  // Microphone session handling ----------------------------------------------

  Future<void> _toggleMic() async {
    if (_busy) return;
    if (_micActive) {
      if (_micFinalizing) return; // duplicate tap while finalizing
      setState(() => _micFinalizing = true);
      try {
        await _capture.stop(); // final text arrives via the listen future
      } catch (_) {
        if (!mounted) return;
        _endMicSession();
      }
      return;
    }
    await _startMicSession();
  }

  Future<void> _startMicSession() async {
    if (_micActive || _busy) return;
    // banned-ok: Increments the local session generation counter.
    final token = ++_sessionToken;
    _micActive = true;
    _micReady = false;
    _micFinalizing = false;
    if (mounted) {
      setState(() {
        _caption = null;
        _statusMessage = null;
      });
    }
    try {
      final result = await _capture.listen(
        onPartial: (partial) {
          if (!mounted || token != _sessionToken || !_micActive) return;
          setState(() => _caption = partial);
        },
        onReady: (ready) {
          if (!mounted || token != _sessionToken || !_micActive) return;
          if (ready) {
            setState(() => _micReady = true);
          }
        },
      );
      if (!mounted || token != _sessionToken) return; // stale session
      _endMicSession();
      if (result.isSuccess) {
        _applyFinalTranscript(result.text!);
      } else {
        setState(() {
          _caption = null;
          _statusMessage = _captureErrorMessage(result);
        });
      }
    } catch (_) {
      if (!mounted || token != _sessionToken) return;
      _endMicSession();
      setState(() {
        _caption = null;
        _statusMessage =
            AppLocalizations.of(context).voiceTourErrorUnavailable;
      });
    }
  }

  void _endMicSession() {
    _micActive = false;
    _micReady = false;
    _micFinalizing = false;
  }

  Future<void> _cancelMicSession() async {
    if (!_micActive) return;
    _sessionToken++;
    _endMicSession();
    if (mounted) {
      setState(() => _caption = null);
    }
    try {
      await _capture.cancel();
    } catch (_) {
      // The listen future already resolved locally; cleanup is best effort.
    }
  }

  // Transcript application ---------------------------------------------------

  void _applyFinalTranscript(String transcript) {
    final outcome = _controller.applyTranscript(transcript);
    if (!mounted) return;
    setState(() {
      _caption = null;
      if (outcome.addDraft != null) {
        _statusMessage = null;
      } else if (outcome.queryRange != null) {
        _statusMessage = null;
        _hasQueried = true;
        if (_phase == _TourPhase.query && _controller.lastQueryEvents.isNotEmpty) {
          // Guided advance once real saved records are rendered.
          _phase = _TourPhase.edit;
        }
      } else if (outcome.editTarget != null) {
        _statusMessage = null;
      } else {
        _statusMessage = AppLocalizations.of(context).voiceTourUnsupported;
      }
    });
  }

  void _submitTextTranscript() {
    final text = _textController.text.trim();
    if (text.isEmpty || _micActive) return;
    _textController.clear();
    _applyFinalTranscript(text);
  }

  void _toggleTextMode() {
    if (_busy) return;
    setState(() {
      _textMode = !_textMode;
      if (!_textMode) {
        _textController.clear();
      }
    });
  }

  String? _captureErrorMessage(VoiceCaptureResult result) {
    final l10n = AppLocalizations.of(context);
    if (result.deniedPermission) return l10n.voiceTourErrorPermission;
    if (result.unsupportedLocale) return l10n.voiceTourErrorLocale;
    if (result.silence) return l10n.voiceTourErrorSilence;
    return l10n.voiceTourErrorUnavailable;
  }

  // Phase transitions --------------------------------------------------------

  void _saveCreate() {
    if (_busy || _controller.pendingAdd == null) return;
    final id = _controller.savePending();
    if (id == null) return; // duplicate tap: already committed
    setState(() {
      _practiceEventId = id;
      _phase = _TourPhase.query;
      _hasQueried = false;
      _showRestarted = false;
    });
  }

  void _saveEdit() {
    if (_busy || _controller.pendingEdit == null) return;
    final id = _controller.savePending();
    if (id == null) return; // duplicate tap: already committed
    setState(() {
      _updatedId = id;
      // The rendered list is invalidated by the controller after an edit
      // save; hide it (detail binds by saved id instead of a stale index).
      _hasQueried = false;
      _showRestarted = false;
    });
  }

  void _openUpdated() {
    if (_updatedId == null) return;
    setState(() {
      _phase = _TourPhase.detail;
      _detailViewed = true; // saved detail actually viewed
      _showRestarted = false;
    });
  }

  // Formatting ----------------------------------------------------------------

  String _two(int value) => value.toString().padLeft(2, '0');

  String _formatDate(DateTime time) => _fmtDate(time);

  String _formatClock(DateTime time) => _fmtClock(time);

  String _formatStamp(DateTime time) => '${_fmtDate(time)} ${_fmtClock(time)}';

  // Build ----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final phaseIndex = _TourPhase.values.indexOf(_phase) + 1;
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
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: TextButton.icon(
                        key: const ValueKey('voice-tour-restart'),
                        onPressed: _busy ? null : _restartTour,
                        icon: const Icon(Icons.refresh),
                        label: Text(
                          l10n.featureTourRestart,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    if (!widget.requireFinalConfirmation)
                      Flexible(
                        child: TextButton(
                          key: const ValueKey('voice-tour-skip'),
                          onPressed: _busy ? null : _completeTour,
                          child: Text(
                            l10n.featureTourSkip,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.voiceTourStep(phaseIndex),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: PlanFlowColors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: SingleChildScrollView(
                    key: ValueKey('voice-tour-phase-${_phase.name}'),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: _buildPhase(context, l10n),
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
                if (!_detailViewed && !_busy)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      l10n.voiceTourFinishLocked,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: PlanFlowColors.textSecondary,
                          ),
                    ),
                  ),
                FilledButton(
                  key: const ValueKey('voice-tour-finish'),
                  onPressed: (_detailViewed && !_busy) ? _completeTour : null,
                  child: Text(l10n.featureTourFinish),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPhase(BuildContext context, AppLocalizations l10n) {
    switch (_phase) {
      case _TourPhase.create:
        return _buildCreatePhase(context, l10n);
      case _TourPhase.query:
        return _buildQueryPhase(context, l10n);
      case _TourPhase.edit:
        return _buildEditPhase(context, l10n);
      case _TourPhase.detail:
        return _buildDetailPhase(context, l10n);
    }
  }

  Widget _buildCreatePhase(BuildContext context, AppLocalizations l10n) {
    final draft = _controller.pendingAdd;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepHeader(
          icon: Icons.mic_outlined,
          title: l10n.voiceTourPhaseCreateTitle,
          hint: l10n.voiceTourPhaseCreateHint,
        ),
        const SizedBox(height: 8),
        _ExampleChip(label: l10n.voiceTourExampleCreate),
        const SizedBox(height: 16),
        _MicControls(l10n: l10n, state: this),
        const SizedBox(height: 16),
        if (draft != null) ...[
          _PreviewCard(
            key: const ValueKey('voice-tour-create-preview'),
            title: l10n.voiceTourCreatePreviewTitle,
            note: l10n.voiceTourPreviewNote,
            rows: [
              _PreviewRowData(label: l10n.voiceTourPreviewTitleLabel, value: draft.title),
              _PreviewRowData(
                  label: l10n.voiceTourPreviewDate, value: _formatDate(draft.date)),
              _PreviewRowData(
                label: l10n.voiceTourPreviewTime,
                value:
                    '${_two(draft.time.hour)}:${_two(draft.time.minute)}',
              ),
              _PreviewRowData(
                label: l10n.voiceTourPreviewLocation,
                value: draft.location ?? l10n.voiceTourPreviewLocationEmpty,
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            key: const ValueKey('voice-tour-save-create'),
            onPressed: _busy ? null : _saveCreate,
            child: Text(l10n.voiceTourSaveCreate),
          ),
        ],
      ],
    );
  }

  Widget _buildQueryPhase(BuildContext context, AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepHeader(
          icon: Icons.question_answer_outlined,
          title: l10n.voiceTourPhaseQueryTitle,
          hint: l10n.voiceTourPhaseQueryHint,
        ),
        const SizedBox(height: 8),
        _ExampleChip(label: l10n.voiceTourExampleQuery),
        const SizedBox(height: 16),
        _MicControls(l10n: l10n, state: this),
        const SizedBox(height: 16),
        _ResultsList(controller: _controller, hasQueried: _hasQueried),
      ],
    );
  }

  Widget _buildEditPhase(BuildContext context, AppLocalizations l10n) {
    final edit = _controller.pendingEdit;
    final updated = _updatedId != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepHeader(
          icon: Icons.schedule_outlined,
          title: l10n.voiceTourPhaseEditTitle,
          hint: l10n.voiceTourPhaseEditHint,
        ),
        const SizedBox(height: 8),
        _ExampleChip(label: l10n.voiceTourExampleEdit),
        const SizedBox(height: 16),
        _MicControls(l10n: l10n, state: this),
        const SizedBox(height: 16),
        _ResultsList(controller: _controller, hasQueried: _hasQueried),
        if (edit != null) ...[
          const SizedBox(height: 12),
          _PreviewCard(
            key: const ValueKey('voice-tour-edit-preview'),
            title: l10n.voiceTourEditPreviewTitle,
            note: l10n.voiceTourEditPreviewNote,
            rows: [
              _PreviewRowData(
                  label: l10n.voiceTourPreviewTitleLabel, value: edit.originalEvent.title),
              _PreviewRowData(
                label: l10n.voiceTourEditPreviewFrom,
                value: _formatStamp(edit.originalEvent.eventTime),
              ),
              _PreviewRowData(
                label: l10n.voiceTourEditPreviewTo,
                value:
                    '${_two(edit.newTime.hour)}:${_two(edit.newTime.minute)}',
              ),
              _PreviewRowData(
                label: l10n.voiceTourPreviewLocation,
                value: edit.originalEvent.location ??
                    l10n.voiceTourPreviewLocationEmpty,
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            key: const ValueKey('voice-tour-save-edit'),
            onPressed: _busy ? null : _saveEdit,
            child: Text(l10n.voiceTourSaveEdit),
          ),
        ],
        if (updated) ...[
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('voice-tour-open-updated'),
            onPressed: _busy ? null : _openUpdated,
            child: Text(l10n.voiceTourOpenUpdated),
          ),
        ],
      ],
    );
  }

  Widget _buildDetailPhase(BuildContext context, AppLocalizations l10n) {
    final id = _updatedId ?? _practiceEventId;
    final event = id == null ? null : _controller.findById(id);
    if (event == null) {
      return _StepHeader(
        icon: Icons.event_busy_outlined,
        title: l10n.voiceTourPhaseDetailTitle,
        hint: l10n.voiceTourResultsEmpty,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepHeader(
          icon: Icons.event_available_outlined,
          title: l10n.voiceTourPhaseDetailTitle,
          hint: l10n.voiceTourPhaseDetailHint,
        ),
        const SizedBox(height: 16),
        Container(
          key: const ValueKey('voice-tour-detail'),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: PlanFlowColors.primaryFaint),
          ),
          child: Container(
            key: ValueKey('voice-tour-detail-event-${event.id}'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.voiceTourDetailSavedTitle,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  key: const ValueKey('voice-tour-detail-title'),
                  event.title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: PlanFlowColors.textPrimary,
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 12),
                _DetailRow(
                  label: l10n.voiceTourPreviewDate,
                  value: _formatDate(event.eventTime),
                  valueKey: const ValueKey('voice-tour-detail-date'),
                ),
                _DetailRow(
                  label: l10n.voiceTourDetailEventTime,
                  value: _formatClock(event.eventTime),
                  valueKey: const ValueKey('voice-tour-detail-event-time'),
                ),
                _DetailRow(
                  label: l10n.voiceTourPreviewLocation,
                  value:
                      event.location ?? l10n.voiceTourPreviewLocationEmpty,
                  valueKey: const ValueKey('voice-tour-detail-location'),
                ),
                _DetailRow(
                  label: l10n.voiceTourDetailDeparture,
                  value: _formatStamp(event.departure),
                  valueKey: const ValueKey('voice-tour-detail-departure'),
                ),
                _DetailRow(
                  label: l10n.voiceTourDetailPreparation,
                  value: _formatStamp(event.preparation),
                  valueKey: const ValueKey('voice-tour-detail-preparation'),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.voiceTourExampleNote,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                        height: 1.4,
                      ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Shared mic controls card: toggle start/stop, cancel, live status and the
/// live partial transcript (display-only, never parsed), plus the optional
/// explicit text fallback.
class _MicControls extends StatelessWidget {
  const _MicControls({required this.l10n, required this.state});

  final AppLocalizations l10n;
  final _FeatureTourScreenState state;

  @override
  Widget build(BuildContext context) {
    final micActive = state._micActive;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PlanFlowColors.primaryFaint),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('voice-tour-mic-button'),
                  onPressed: state._busy ? null : state._toggleMic,
                  icon: Icon(micActive ? Icons.stop : Icons.mic),
                  label: Text(
                    micActive
                        ? l10n.voiceTourMicStop
                        : l10n.voiceTourMicStart,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (micActive) ...[
                const SizedBox(width: 8),
                OutlinedButton(
                  key: const ValueKey('voice-tour-cancel-mic'),
                  onPressed: state._cancelMicSession,
                  child: Text(l10n.voiceTourCancelMic),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (micActive && !state._micReady)
            Text(
              l10n.voiceTourPreparing,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
          if (micActive && state._micReady)
            Text(
              key: const ValueKey('voice-tour-ready'),
              l10n.voiceTourListening,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('voice-tour-transcript'),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: PlanFlowColors.primaryFaint,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              state._caption ?? l10n.voiceTourTranscriptHint,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: state._caption == null
                        ? PlanFlowColors.textSecondary
                        : PlanFlowColors.textPrimary,
                  ),
            ),
          ),
          if (state._statusMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              state._statusMessage!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
            ),
          ],
          const SizedBox(height: 10),
          TextButton.icon(
            key: const ValueKey('voice-tour-text-mode'),
            onPressed: state._busy ? null : state._toggleTextMode,
            icon: Icon(
              state._textMode ? Icons.mic : Icons.keyboard,
              size: 18,
            ),
            label: Text(l10n.voiceTourTextMode),
          ),
          if (state._textMode) ...[
            TextField(
              key: const ValueKey('voice-tour-text-input'),
              controller: state._textController,
              enabled: !micActive,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => state._submitTextTranscript(),
              decoration: InputDecoration(
                labelText: l10n.voiceTourTextLabel,
                helperText: l10n.voiceTourTextHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              key: const ValueKey('voice-tour-text-submit'),
              onPressed:
                  micActive || state._busy ? null : state._submitTextTranscript,
              child: Text(l10n.voiceTourTextSubmit),
            ),
          ],
        ],
      ),
    );
  }
}


/// Rendered query results. Ordinals shown here are what spoken ordinals
/// bind to ("첫 번째" = row 1 of this list).
class _ResultsList extends StatelessWidget {
  const _ResultsList({required this.controller, required this.hasQueried});

  final VoiceFirstTourController controller;
  final bool hasQueried;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final events = controller.lastQueryEvents;
    if (events.isEmpty) {
      if (!hasQueried) {
        return const SizedBox.shrink();
      }
      return Text(
        l10n.voiceTourResultsEmpty,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
      );
    }
    return Container(
      key: const ValueKey('voice-tour-results'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PlanFlowColors.primaryFaint),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.voiceTourResultsTitle,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < events.length; i += 1)
            Padding(
              key: ValueKey('voice-tour-result-${events[i].id}'),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${i + 1}. ',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: PlanFlowColors.primary,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      Expanded(
                        child: Text(
                          key: ValueKey(
                              'voice-tour-result-title-${events[i].id}'),
                          events[i].title,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: PlanFlowColors.textPrimary,
                                  ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            key: ValueKey(
                                'voice-tour-result-date-${events[i].id}'),
                            _fmtDate(events[i].eventTime),
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: PlanFlowColors.textPrimary),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            key: ValueKey(
                                'voice-tour-result-time-${events[i].id}'),
                            _fmtClock(events[i].eventTime),
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: PlanFlowColors.textPrimary),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (events[i].location != null)
                    Text(
                      key: ValueKey(
                          'voice-tour-result-location-${events[i].id}'),
                      events[i].location!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: PlanFlowColors.textSecondary,
                          ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    super.key,
    required this.title,
    required this.note,
    required this.rows,
  });

  final String title;
  final String note;
  final List<_PreviewRowData> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PlanFlowColors.primaryFaint),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
          ),
          const SizedBox(height: 8),
          for (final row in rows) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    row.label,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                  ),
                ),
                Flexible(
                  child: Text(
                    row.value,
                    textAlign: TextAlign.end,
                    style:
                        Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: PlanFlowColors.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
          ],
          Text(
            note,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
          ),
        ],
      ),
    );
  }
}

class _PreviewRowData {
  const _PreviewRowData({required this.label, required this.value});

  final String label;
  final String value;
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value, this.valueKey});

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
          ),
          const SizedBox(width: 8),
          // Shrinks instead of overflowing at large text scales.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                key: valueKey,
                value,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: PlanFlowColors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _fmtDate(DateTime time) =>
    '${time.month.toString().padLeft(2, '0')}/${time.day.toString().padLeft(2, '0')}';

String _fmtClock(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

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

class _ExampleChip extends StatelessWidget {
  const _ExampleChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: PlanFlowColors.primaryFaint,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textPrimary,
            ),
      ),
    );
  }
}
