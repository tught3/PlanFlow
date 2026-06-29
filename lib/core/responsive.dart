import 'dart:math' as math;
import 'dart:ui' as ui;

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

  static const double compactBreakpoint = 600;
  static const double expandedBreakpoint = 840;
  static const double twoPaneBreakpoint = 900;
  static const double minimumRailHeight = 520;
  static const double minimumTwoPaneHeight = 620;

  static PlanFlowResponsiveSize sizeForWidth(double width) {
    if (width >= expandedBreakpoint) {
      return PlanFlowResponsiveSize.expanded;
    }
    if (width >= compactBreakpoint) {
      return PlanFlowResponsiveSize.medium;
    }
    return PlanFlowResponsiveSize.compact;
  }

  static PlanFlowWindowInfo windowInfoOf(
    BuildContext context, {
    BoxConstraints? constraints,
  }) {
    final mediaQuery = MediaQuery.of(context);
    final rawSize = constraints == null
        ? mediaQuery.size
        : Size(
            constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : mediaQuery.size.width,
            constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : mediaQuery.size.height,
          );
    final safeSize = safeSizeFor(rawSize, mediaQuery.displayFeatures);
    return PlanFlowWindowInfo(
      size: rawSize,
      safeSize: safeSize,
      viewInsets: mediaQuery.viewInsets,
      displayFeatures: mediaQuery.displayFeatures,
    );
  }

  static Size safeSizeFor(
    Size size,
    List<ui.DisplayFeature> displayFeatures,
  ) {
    var safeSize = size;
    for (final feature in displayFeatures) {
      final bounds = feature.bounds;
      if (bounds.isEmpty) {
        continue;
      }

      final isVerticalSeparator =
          bounds.width > 0 && bounds.height >= size.height * 0.5;
      if (isVerticalSeparator) {
        final leftWidth = bounds.left.clamp(0.0, size.width);
        final rightWidth = (size.width - bounds.right).clamp(0.0, size.width);
        safeSize = Size(math.max(leftWidth, rightWidth), safeSize.height);
        continue;
      }

      final isHorizontalSeparator =
          bounds.height > 0 && bounds.width >= size.width * 0.5;
      if (isHorizontalSeparator) {
        final topHeight = bounds.top.clamp(0.0, size.height);
        final bottomHeight =
            (size.height - bounds.bottom).clamp(0.0, size.height);
        safeSize = Size(safeSize.width, math.max(topHeight, bottomHeight));
      }
    }
    return safeSize;
  }

  static bool hasSeparatingDisplayFeature(
    Size size,
    List<ui.DisplayFeature> displayFeatures,
  ) {
    return displayFeatures.any((feature) {
      final isFoldableFeature = feature.type == ui.DisplayFeatureType.hinge ||
          feature.type == ui.DisplayFeatureType.fold;
      if (!isFoldableFeature) {
        return false;
      }

      final bounds = feature.bounds;
      if (bounds.isEmpty) {
        return false;
      }
      return (bounds.width > 0 && bounds.height >= size.height * 0.5) ||
          (bounds.height > 0 && bounds.width >= size.width * 0.5);
    });
  }
}

extension PlanFlowResponsiveContext on BuildContext {
  PlanFlowResponsiveSize get planflowResponsiveSize {
    return PlanFlowResponsive.sizeForWidth(MediaQuery.sizeOf(this).width);
  }

  PlanFlowWindowInfo get planflowWindowInfo {
    return PlanFlowResponsive.windowInfoOf(this);
  }
}

class PlanFlowWindowInfo {
  const PlanFlowWindowInfo({
    required this.size,
    required this.safeSize,
    required this.viewInsets,
    required this.displayFeatures,
  });

  final Size size;
  final Size safeSize;
  final EdgeInsets viewInsets;
  final List<ui.DisplayFeature> displayFeatures;

  PlanFlowResponsiveSize get sizeClass {
    return PlanFlowResponsive.sizeForWidth(safeSize.width);
  }

  bool get isLandscape => safeSize.width > safeSize.height;

  bool get isShortHeight =>
      safeSize.height < PlanFlowResponsive.minimumRailHeight;

  bool get hasKeyboard => viewInsets.bottom > 0;

  bool get hasSeparatingDisplayFeature {
    return PlanFlowResponsive.hasSeparatingDisplayFeature(
      size,
      displayFeatures,
    );
  }

  bool get useNavigationRail {
    return sizeClass.isMediumOrLarger &&
        safeSize.height >= PlanFlowResponsive.minimumRailHeight;
  }

  bool get useTwoPane {
    return safeSize.width >= PlanFlowResponsive.twoPaneBreakpoint &&
        safeSize.height >= PlanFlowResponsive.minimumTwoPaneHeight;
  }

  double get contentMaxWidth {
    return switch (sizeClass) {
      PlanFlowResponsiveSize.compact => 760,
      PlanFlowResponsiveSize.medium => 860,
      PlanFlowResponsiveSize.expanded => 980,
    };
  }

  double get wideContentMaxWidth => useTwoPane ? 1180 : contentMaxWidth;
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
