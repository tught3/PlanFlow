import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../services/feature_tour_service.dart';

/// Legacy 3-page voice-first intro.
///
/// Restored from the pre-WIP `feature_tour_screen.dart` (git 87256e3f). The
/// screen renders three explanation pages, lets the user swipe between them,
/// and only marks the tour complete on the final page once the injected
/// [FeatureTourStore] reports the completion has actually persisted.
///
/// All persistence is delegated to the injected store — this widget never
/// touches `SharedPreferences`, files, calendars, or network on its own.
class LegacyIntroScreen extends StatefulWidget {
  const LegacyIntroScreen({
    super.key,
    required this.store,
    this.onCompleted,
    this.requireFinalConfirmation = true,
  });

  /// Storage adapter. Must be supplied by the caller so each user can
  /// plug in their own backend (test fake, server-backed store, etc.).
  final FeatureTourStore store;

  /// Optional completion hook. When null, the screen pops the current
  /// route on success.
  final VoidCallback? onCompleted;

  /// When true, the screen is treated as a mandatory gate: the system back
  /// gesture is suppressed, and the top-right skip button is hidden. When
  /// false, the skip button is shown and the system back gesture triggers
  /// the same completion flow as the final-page CTA.
  final bool requireFinalConfirmation;

  @override
  State<LegacyIntroScreen> createState() => _LegacyIntroScreenState();
}

class _LegacyIntroScreenState extends State<LegacyIntroScreen> {
  final PageController _pageController = PageController();
  int _pageIndex = 0;
  bool _isCompleting = false;
  String? _errorMessage;

  static const List<_LegacyPageData> _pages = <_LegacyPageData>[
    _LegacyPageData(
      icon: Icons.mic_none_rounded,
      title: '말하면 일정이 정리돼요',
      description: '음성으로 말하면 날짜, 시간, 반복 일정까지 빠르게 정리할 수 있어요.',
    ),
    _LegacyPageData(
      icon: Icons.auto_awesome_outlined,
      title: 'AI 대화로 일정도 고쳐요',
      description: '회의 시간을 바꾸거나 장소를 추가해 달라고 이어서 말할 수 있어요.',
    ),
    _LegacyPageData(
      icon: Icons.directions_walk_outlined,
      title: '출발과 브리핑을 챙겨드려요',
      description: '장소가 확인된 일정은 예상 이동 시간과 준비·출발 시점을 알려드려요. 하루 일정은 브리핑으로 정리해드려요.',
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Completes the tour: persist via [FeatureTourStore.markCompleted], verify
  /// the change with a readback [FeatureTourStore.shouldShow], and only then
  /// invoke the completion callback or pop the route. If any step fails the
  /// screen stays in place with a retry message.
  Future<void> _complete() async {
    // Double-tap / rapid-tap guard. `_isCompleting` is mutated synchronously
    // by the very first call before any `await` yields control, so any
    // follow-up tap that races past the rebuild is rejected here.
    if (_isCompleting) return;
    if (!mounted) return;
    setState(() {
      _isCompleting = true;
      _errorMessage = null;
    });

    try {
      await widget.store.markCompleted();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isCompleting = false;
        _errorMessage = '저장에 실패했어요. 다시 시도해 주세요.';
      });
      return;
    }

    // Readback guard: trust nothing but the store's own `shouldShow`. If it
    // still reports the tour as visible, treat persistence as failed and let
    // the user retry rather than popping a half-saved state.
    bool persisted = false;
    try {
      persisted = !(await widget.store.shouldShow());
    } catch (_) {
      persisted = false;
    }
    if (!mounted) return;
    if (!persisted) {
      setState(() {
        _isCompleting = false;
        _errorMessage = '저장이 완료되지 않았어요. 다시 시도해 주세요.';
      });
      return;
    }

    if (widget.onCompleted != null) {
      widget.onCompleted!();
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _next() async {
    if (_pageIndex == _pages.length - 1) {
      await _complete();
      return;
    }
    await _pageController.nextPage(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLastPage = _pageIndex == _pages.length - 1;
    return PopScope(
      canPop: !widget.requireFinalConfirmation,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !widget.requireFinalConfirmation) {
          _complete();
        }
      },
      child: Scaffold(
        backgroundColor: PlanFlowColors.background,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
            child: Column(
              children: [
                if (widget.requireFinalConfirmation)
                  const SizedBox(height: 48)
                else
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      key: const ValueKey('legacy-intro-skip-button'),
                      onPressed: _isCompleting ? null : _complete,
                      child: const Text('건너뛰기'),
                    ),
                  ),
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _pages.length,
                    onPageChanged: (index) {
                      if (!mounted) return;
                      setState(() => _pageIndex = index);
                    },
                    itemBuilder: (context, index) {
                      final item = _pages[index];
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 96,
                            height: 96,
                            decoration: const BoxDecoration(
                              color: PlanFlowColors.primaryFaint,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              item.icon,
                              size: 46,
                              color: PlanFlowColors.primary,
                            ),
                          ),
                          const SizedBox(height: 36),
                          Text(
                            item.title,
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(
                                  color: PlanFlowColors.textPrimary,
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            item.description,
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .bodyLarge
                                ?.copyWith(
                                  height: 1.5,
                                  color: PlanFlowColors.textSecondary,
                                ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                if (_errorMessage != null)
                  Padding(
                    key: const ValueKey('legacy-intro-error-message'),
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _errorMessage!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFB42318),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List<Widget>.generate(
                    _pages.length,
                    (index) => AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: _pageIndex == index ? 20 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _pageIndex == index
                            ? PlanFlowColors.primary
                            : PlanFlowColors.primaryFaint,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const ValueKey('legacy-intro-next-button'),
                    onPressed: _isCompleting ? null : _next,
                    icon: Icon(isLastPage ? Icons.check : Icons.arrow_forward),
                    label: Text(isLastPage ? '시작하기' : '다음'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LegacyPageData {
  const _LegacyPageData({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;
}
