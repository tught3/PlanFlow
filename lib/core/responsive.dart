import 'package:flutter/material.dart';

enum PlanFlowResponsiveSize {
  compact,
  medium,
  expanded;

  bool get isCompact => this == compact;
  bool get isMediumOrLarger => this != compact;
  bool get isExpanded => this == expanded;
}

class PlanFlowResponsive {
  const PlanFlowResponsive._();

  static PlanFlowResponsiveSize sizeForWidth(double width) {
    if (width >= 840) {
      return PlanFlowResponsiveSize.expanded;
    }
    if (width >= 600) {
      return PlanFlowResponsiveSize.medium;
    }
    return PlanFlowResponsiveSize.compact;
  }
}

extension PlanFlowResponsiveContext on BuildContext {
  PlanFlowResponsiveSize get planflowResponsiveSize {
    return PlanFlowResponsive.sizeForWidth(MediaQuery.sizeOf(this).width);
  }
}

class ResponsiveContent extends StatelessWidget {
  const ResponsiveContent({
    super.key,
    required this.child,
    this.maxWidth = 760,
    this.alignment = Alignment.topCenter,
  });

  final Widget child;
  final double maxWidth;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width <= maxWidth) {
          return SizedBox(width: width, child: child);
        }

        return Align(
          alignment: alignment,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: SizedBox(width: double.infinity, child: child),
          ),
        );
      },
    );
  }
}

class ResponsiveTwoPane extends StatelessWidget {
  const ResponsiveTwoPane({
    super.key,
    required this.primary,
    required this.secondary,
    this.breakpoint = 840,
    this.gap = 16,
    this.primaryFlex = 5,
    this.secondaryFlex = 4,
    this.crossAxisAlignment = CrossAxisAlignment.start,
  });

  final Widget primary;
  final Widget secondary;
  final double breakpoint;
  final double gap;
  final int primaryFlex;
  final int secondaryFlex;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < breakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              primary,
              SizedBox(height: gap),
              secondary,
            ],
          );
        }

        return Row(
          crossAxisAlignment: crossAxisAlignment,
          children: [
            Expanded(flex: primaryFlex, child: primary),
            SizedBox(width: gap),
            Expanded(flex: secondaryFlex, child: secondary),
          ],
        );
      },
    );
  }
}
