import 'package:flutter/material.dart';

class PlanFlowEventCategories {
  const PlanFlowEventCategories._();

  static const work = '업무';
  static const personal = '개인';
  static const health = '건강';
  static const education = '교육';
  static const etc = '기타';
  static const legacyFamily = '가족';

  static const values = <String>[
    work,
    personal,
    health,
    education,
    etc,
  ];

  static const colors = <String, Color>{
    work: Color(0xFF1A4FD6),
    personal: Color(0xFF1D9E75),
    health: Color(0xFFE07B30),
    education: Color(0xFF6B2D8B),
    etc: Color(0xFF7AB3D4),
  };

  static String normalize(Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text == legacyFamily) {
      return health;
    }
    return values.contains(text) ? text : etc;
  }

  static Color colorOf(String category) {
    return colors[normalize(category)] ?? colors[etc]!;
  }
}

class PlanFlowEventTypeLabels {
  const PlanFlowEventTypeLabels._();

  static const single = '하루';
  static const allDay = '종일';
  static const multiDay = '연속';
}
