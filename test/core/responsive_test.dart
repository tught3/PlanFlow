import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/responsive.dart';

void main() {
  test('responsive size class splits at the expected widths', () {
    expect(
        PlanFlowResponsive.sizeForWidth(359), PlanFlowResponsiveSize.compact);
    expect(PlanFlowResponsive.sizeForWidth(600), PlanFlowResponsiveSize.medium);
    expect(PlanFlowResponsive.sizeForWidth(839), PlanFlowResponsiveSize.medium);
    expect(
      PlanFlowResponsive.sizeForWidth(840),
      PlanFlowResponsiveSize.expanded,
    );
  });

  test('foldable hinge reduces the safe width used for layout decisions', () {
    const screenSize = Size(1000, 800);
    final safeSize = PlanFlowResponsive.safeSizeFor(
      screenSize,
      const <ui.DisplayFeature>[
        ui.DisplayFeature(
          bounds: Rect.fromLTWH(495, 0, 10, 800),
          type: ui.DisplayFeatureType.hinge,
          state: ui.DisplayFeatureState.postureHalfOpened,
        ),
      ],
    );

    expect(safeSize, const Size(495, 800));
    expect(
      PlanFlowResponsive.sizeForWidth(safeSize.width),
      PlanFlowResponsiveSize.compact,
    );
  });

  testWidgets(
      'window info uses rail on tablets and bottom tabs on narrow folds',
      (tester) async {
    PlanFlowWindowInfo? tabletInfo;
    PlanFlowWindowInfo? narrowFoldInfo;

    await tester.binding.setSurfaceSize(const Size(800, 1280));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            tabletInfo = context.planflowWindowInfo;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    await tester.binding.setSurfaceSize(const Size(500, 800));
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(1000, 800),
          displayFeatures: <ui.DisplayFeature>[
            ui.DisplayFeature(
              bounds: Rect.fromLTWH(500, 0, 12, 800),
              type: ui.DisplayFeatureType.hinge,
              state: ui.DisplayFeatureState.postureHalfOpened,
            ),
          ],
        ),
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              narrowFoldInfo = context.planflowWindowInfo;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));

    expect(tabletInfo?.useNavigationRail, isTrue);
    expect(tabletInfo?.useTwoPane, isFalse);
    expect(narrowFoldInfo?.useNavigationRail, isFalse);
    expect(narrowFoldInfo?.useTwoPane, isFalse);
  });

  testWidgets('responsive two pane stacks on compact widths', (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(size: Size(500, 800)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.expand(
            child: ResponsiveTwoPane(
              primary: ColoredBox(
                color: Colors.red,
                child: SizedBox(height: 20, child: Text('left')),
              ),
              secondary: ColoredBox(
                color: Colors.blue,
                child: SizedBox(height: 20, child: Text('right')),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Column), findsWidgets);
    expect(find.byType(Row), findsNothing);
  });

  testWidgets('responsive two pane uses a row on wide widths', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(size: Size(1000, 800)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.expand(
            child: ResponsiveTwoPane(
              primary: ColoredBox(
                color: Colors.red,
                child: SizedBox(height: 20, child: Text('left')),
              ),
              secondary: ColoredBox(
                color: Colors.blue,
                child: SizedBox(height: 20, child: Text('right')),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Row), findsWidgets);
  });
}
