import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/kasi_holiday_service.dart';
import 'package:planflow/services/korean_holidays.dart';

void main() {
  // 실제 API 호출로 받은 2026년 응답을 그대로 고정 데이터로 쓴다(2026-07-11
  // 실측). 2026년부터 제헌절이 isHoliday:Y로 포함된 실제 응답을 사용한다.
  const sampleRawJson = '''
{"response":{"header":{"resultCode":"00","resultMsg":"NORMAL SERVICE."},"body":{"items":{"item":[
{"dateKind":"01","dateName":"1월1일","isHoliday":"Y","locdate":20260101,"seq":1},
{"dateKind":"01","dateName":"설날","isHoliday":"Y","locdate":20260216,"seq":1},
{"dateKind":"01","dateName":"설날","isHoliday":"Y","locdate":20260217,"seq":1},
{"dateKind":"01","dateName":"설날","isHoliday":"Y","locdate":20260218,"seq":1},
{"dateKind":"01","dateName":"삼일절","isHoliday":"Y","locdate":20260301,"seq":1},
{"dateKind":"01","dateName":"대체공휴일(삼일절)","isHoliday":"Y","locdate":20260302,"seq":1},
{"dateKind":"01","dateName":"노동절","isHoliday":"Y","locdate":20260501,"seq":2},
{"dateKind":"01","dateName":"어린이날","isHoliday":"Y","locdate":20260505,"seq":2},
{"dateKind":"01","dateName":"부처님오신날","isHoliday":"Y","locdate":20260524,"seq":1},
{"dateKind":"01","dateName":"전국동시지방선거","isHoliday":"Y","locdate":20260603,"seq":1},
{"dateKind":"01","dateName":"현충일","isHoliday":"Y","locdate":20260606,"seq":2},
{"dateKind":"01","dateName":"제헌절","isHoliday":"Y","locdate":20260717,"seq":1},
{"dateKind":"01","dateName":"광복절","isHoliday":"Y","locdate":20260815,"seq":1},
{"dateKind":"01","dateName":"추석","isHoliday":"Y","locdate":20260924,"seq":1},
{"dateKind":"01","dateName":"추석","isHoliday":"Y","locdate":20260925,"seq":1},
{"dateKind":"01","dateName":"추석","isHoliday":"Y","locdate":20260926,"seq":1},
{"dateKind":"01","dateName":"개천절","isHoliday":"Y","locdate":20261003,"seq":1},
{"dateKind":"01","dateName":"한글날","isHoliday":"Y","locdate":20261009,"seq":1},
{"dateKind":"01","dateName":"기독탄신일","isHoliday":"Y","locdate":20261225,"seq":1}
]},"numOfRows":50,"pageNo":1,"totalCount":19}}}
''';

  test('실 API 응답을 파싱해 KoreanHolidays에 반영한다 (노동절·선거일 등 계산으로 알 수 없는 항목 포함)', () {
    final applied = KasiHolidayService.instance.applyRawJsonForTesting(
      2097,
      sampleRawJson,
    );

    expect(applied, isTrue);
    expect(KoreanHolidays.isDayOff(DateTime(2097, 5, 1)), isTrue);
    expect(KoreanHolidays.holidayName(DateTime(2097, 5, 1)), '노동절');
    expect(KoreanHolidays.isDayOff(DateTime(2097, 6, 3)), isTrue);
    expect(KoreanHolidays.holidayName(DateTime(2097, 6, 3)), '전국동시지방선거');
  });

  test('API의 제헌절 isHoliday:Y를 2026년 공휴일로 반영한다', () {
    KasiHolidayService.instance.applyRawJsonForTesting(2026, sampleRawJson);

    expect(KoreanHolidays.isDayOff(DateTime(2026, 7, 17)), isTrue);
    expect(KoreanHolidays.holidayName(DateTime(2026, 7, 17)), '제헌절');
  });

  test('API의 2025년 제헌절은 쉬는 날로 반영하지 않는다', () {
    KasiHolidayService.instance.applyRawJsonForTesting(2025, sampleRawJson);

    expect(KoreanHolidays.isDayOff(DateTime(2025, 7, 17)), isFalse);
  });

  test('빈 item 목록이면 false를 반환하고 기존 계산값에 영향을 주지 않는다', () {
    const emptyJson = '{"response":{"body":{"items":{"item":[]}}}}';
    final applied = KasiHolidayService.instance.applyRawJsonForTesting(
      2095,
      emptyJson,
    );

    expect(applied, isFalse);
    // 실 데이터가 없으므로 klc 계산값(개천절 등)이 그대로 동작해야 한다.
    expect(KoreanHolidays.isDayOff(DateTime(2095, 10, 3)), isTrue);
  });

  test('깨진 JSON이 와도 예외를 던지지 않고 false를 반환한다', () {
    expect(
      () => KasiHolidayService.instance.applyRawJsonForTesting(
        2094,
        'not valid json',
      ),
      returnsNormally,
    );
    expect(
      KasiHolidayService.instance.applyRawJsonForTesting(
        2094,
        'not valid json',
      ),
      isFalse,
    );
  });
}
