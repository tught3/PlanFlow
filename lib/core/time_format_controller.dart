import 'package:flutter/material.dart';

/// 앱 전역 시간 표시 형식을 관리하는 싱글톤.
/// PlanFlowRegionController 와 동일 패턴.
class TimeFormatController extends ChangeNotifier {
  TimeFormatController._();

  static final TimeFormatController instance = TimeFormatController._();

  bool _use24HourFormat = false;

  bool get use24HourFormat => _use24HourFormat;

  void setUse24HourFormat(bool value) {
    if (_use24HourFormat == value) return;
    _use24HourFormat = value;
    notifyListeners();
  }

  void reset() => setUse24HourFormat(false);
}

/// 시간 문자열 포맷 헬퍼 — 앱 전체에서 사용.
///
/// 24시간 설정: "14:30"
/// 12시간 설정: "오후 2:30"
String planflowFormatTime(int hour, int minute) {
  final mm = minute.toString().padLeft(2, '0');
  if (TimeFormatController.instance.use24HourFormat) {
    return '${hour.toString().padLeft(2, '0')}:$mm';
  }
  final period = hour < 12 ? '오전' : '오후';
  final h = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
  return '$period $h:$mm';
}
