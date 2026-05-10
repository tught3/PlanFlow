import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/responsive.dart';

void main() {
  test('responsive size class splits at the expected widths', () {
    expect(PlanFlowResponsive.sizeForWidth(359), PlanFlowResponsiveSize.compact);
    expect(PlanFlowResponsive.sizeForWidth(600), PlanFlowResponsiveSize.medium);
    expect(PlanFlowResponsive.sizeForWidth(839), PlanFlowResponsiveSize.medium);
    expect(
      PlanFlowResponsive.sizeForWidth(840),
      PlanFlowResponsiveSize.expanded,
    );
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
