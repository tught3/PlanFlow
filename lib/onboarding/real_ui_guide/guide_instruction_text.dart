import 'package:flutter/material.dart';

/// Shared typography for the guide's instructional body copy.
class GuideInstructionText extends StatelessWidget {
  const GuideInstructionText(this.text, {super.key, this.fontWeight})
      : span = null;

  const GuideInstructionText.rich(this.span, {super.key, this.fontWeight})
      : text = null;

  final String? text;
  final InlineSpan? span;
  final FontWeight? fontWeight;

  @override
  Widget build(BuildContext context) {
    final style = (Theme.of(context).textTheme.bodyLarge ?? const TextStyle())
        .copyWith(fontSize: 14, fontWeight: fontWeight, height: 1.5);
    return span == null
        ? Text(text!, style: style)
        : Text.rich(span!, style: style);
  }
}
