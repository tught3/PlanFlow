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
