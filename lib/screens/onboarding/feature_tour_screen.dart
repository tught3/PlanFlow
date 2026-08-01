import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../services/feature_tour_service.dart';

class FeatureTourScreen extends StatefulWidget {
  const FeatureTourScreen({
    super.key,
    this.store = const SharedPreferencesFeatureTourStore(),
    this.onCompleted,
  });

  final FeatureTourStore store;
  final VoidCallback? onCompleted;

  @override
  State<FeatureTourScreen> createState() => _FeatureTourScreenState();
}

class _FeatureTourScreenState extends State<FeatureTourScreen> {
  final PageController _pageController = PageController();
  var _pageIndex = 0;
  var _isCompleting = false;

  static const _pages = <_TourPageData>[
    _TourPageData(
      icon: Icons.mic_none_rounded,
      title: '말하면 일정이 정리돼요',
      description: '음성으로 말하면 날짜, 시간, 반복 일정까지 빠르게 정리할 수 있어요.',
    ),
    _TourPageData(
      icon: Icons.auto_awesome_outlined,
      title: 'AI 대화로 일정도 고쳐요',
      description: '회의 시간을 바꾸거나 장소를 추가해 달라고 이어서 말할 수 있어요.',
    ),
    _TourPageData(
      icon: Icons.directions_walk_outlined,
      title: '출발과 브리핑을 챙겨드려요',
      description: '장소를 확인한 일정은 출발 알림으로, 하루 일정은 브리핑으로 알려드려요.',
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _complete() async {
    if (_isCompleting) return;
    setState(() => _isCompleting = true);
    try {
      await widget.store.markCompleted();
    } catch (_) {
      // Custom stores used by tests or future integrations must not trap users.
    }
    if (!mounted) return;
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
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
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
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: const ValueKey('feature-tour-skip-button'),
                    onPressed: _isCompleting ? null : _complete,
                    child: const Text('건너뛰기'),
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _pages.length,
                    onPageChanged: (index) =>
                        setState(() => _pageIndex = index),
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
                            child: Icon(item.icon,
                                size: 46, color: PlanFlowColors.primary),
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
                            style:
                                Theme.of(context).textTheme.bodyLarge?.copyWith(
                                      height: 1.5,
                                      color: PlanFlowColors.textSecondary,
                                    ),
                          ),
                        ],
                      );
                    },
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
                    key: const ValueKey('feature-tour-next-button'),
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

class _TourPageData {
  const _TourPageData({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;
}
