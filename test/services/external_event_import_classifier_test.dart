import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/external_event_import_classifier.dart';

void main() {
  group('ExternalEventImportClassifier', () {
    test('treats high iCal priority as critical', () {
      expect(
        ExternalEventImportClassifier.isCritical(
          title: '병원 예약',
          priority: 1,
        ),
        isTrue,
      );
      expect(
        ExternalEventImportClassifier.isCritical(
          title: '외부 중요 일정',
          priority: 5,
        ),
        isTrue,
      );
    });

    test('treats pre-actions as critical', () {
      expect(
        ExternalEventImportClassifier.isCritical(
          title: '출발 준비가 필요한 일정',
          hasPreActions: true,
        ),
        isTrue,
      );
    });

    test('treats important or Naver booking buckets as critical', () {
      expect(
        ExternalEventImportClassifier.isCritical(
          title: '진료',
          calendarName: '네이버 예약',
        ),
        isTrue,
      );
      expect(
        ExternalEventImportClassifier.isCritical(
          title: '미팅',
          categories: const <String>['Important'],
        ),
        isTrue,
      );
    });

    test('does not mark ordinary reservation wording as critical by itself',
        () {
      expect(
        ExternalEventImportClassifier.isCritical(
          title: '저녁 예약',
          calendarName: '개인 캘린더',
        ),
        isFalse,
      );
    });
  });
}
