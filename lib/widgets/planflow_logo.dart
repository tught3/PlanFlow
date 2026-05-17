import 'package:flutter/material.dart';

import '../core/theme.dart';

class PlanFlowLogo extends StatelessWidget {
  const PlanFlowLogo({
    super.key,
    this.fontSize = 27,
    this.semanticLabel = 'PlanFlow',
  });

  final double fontSize;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: RichText(
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          text: TextSpan(
            style: TextStyle(
              fontFamily: 'Noto Sans KR',
              fontFamilyFallback: const ['Malgun Gothic', 'Roboto'],
              fontSize: fontSize,
              fontWeight: FontWeight.w900,
              height: 1,
              letterSpacing: 0,
            ),
            children: const [
              TextSpan(
                text: 'Plan',
                style: TextStyle(color: PlanFlowColors.primaryMid),
              ),
              TextSpan(
                text: 'Flow',
                style: TextStyle(color: Color(0xFF111827)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
