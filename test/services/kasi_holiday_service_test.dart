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
{"dateKind":"01","dateName":"대체공휴일(개천절)","isHoliday":"Y","locdate":20261005,"seq":1},
{"dateKind":"01","dateName":"한글날","isHoliday":"Y","locdate":20261009,"seq":1},
{"dateKind":"01","dateName":"기독탄신일","isHoliday":"Y","locdate":20261225,"seq":1}
]},"numOfRows":50,"pageNo":1,"totalCount":19}}}
''';

  test('실 API 응답을 파싱해 KoreanHolidays에 반영한다 (노동절·선거일 등 계산으로 알 수 없는 항목 포함)', () {
    const sampleYear = 2026;
    final applied = KasiHolidayService.instance.applyRawJsonForTesting(
      sampleYear,
      sampleRawJson,
    );

    expect(applied, isTrue);
    expect(KoreanHolidays.isDayOff(DateTime(sampleYear, 5, 1)), isTrue);
    expect(KoreanHolidays.holidayName(DateTime(sampleYear, 5, 1)), '노동절');
    expect(KoreanHolidays.isDayOff(DateTime(sampleYear, 6, 3)), isTrue);
    expect(
      KoreanHolidays.holidayName(DateTime(sampleYear, 6, 3)),
      '전국동시지방선거',
    );
    expect(KoreanHolidays.isDayOff(DateTime(sampleYear, 10, 5)), isTrue);
    expect(
      KoreanHolidays.holidayName(DateTime(sampleYear, 10, 5)),
      '대체공휴일(개천절)',
    );
  });

  test('API의 제헌절 isHoliday:Y를 2026년 공휴일로 반영한다', () {
    const sampleYear = 2026;
    KasiHolidayService.instance
        .applyRawJsonForTesting(sampleYear, sampleRawJson);

    expect(KoreanHolidays.isDayOff(DateTime(sampleYear, 7, 17)), isTrue);
    expect(KoreanHolidays.holidayName(DateTime(sampleYear, 7, 17)), '제헌절');
  });

  test('KASI가 isHoliday:Y로 응답하면 연도명 규칙으로 제외하지 않는다', () {
    const sampleYear = 2025;
    const constitutionDay2025 = '''
{"response":{"header":{"resultCode":"00"},"body":{"items":{"item":[
{"dateName":"제헌절","isHoliday":"Y","locdate":20250717}
]}}}}
''';
    KasiHolidayService.instance
        .applyRawJsonForTesting(sampleYear, constitutionDay2025);

    expect(KoreanHolidays.isDayOff(DateTime(sampleYear, 7, 17)), isTrue);
  });

  test('빈 item 목록이면 true를 반환하고 계산값 없이 빈 결과를 확정한다', () {
    const emptyYear = 2095;
    const emptyJson =
        '{"response":{"header":{"resultCode":"00"},"body":{"items":{"item":[]}}}}';
    final applied = KasiHolidayService.instance.applyRawJsonForTesting(
      emptyYear,
      emptyJson,
    );

    expect(applied, isTrue);
    expect(KoreanHolidays.isDayOff(DateTime(emptyYear, 10, 3)), isFalse);
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

  test('실패한 KASI 응답은 빈 성공 응답으로 취급하지 않는다', () {
    const failedYear = 2096;
    const failedJson =
        '{"response":{"header":{"resultCode":"03"},"body":{"items":{"item":[]}}}}';
    expect(
      KasiHolidayService.instance
          .applyRawJsonForTesting(failedYear, failedJson),
      isFalse,
    );
    expect(KoreanHolidays.isDayOff(DateTime(failedYear, 1, 1)), isFalse);
  });

  test('요청 연도와 다른 KASI locdate는 무시한다', () {
    const requestedYear = 2096;
    const wrongYearJson = '''
{"response":{"header":{"resultCode":"00"},"body":{"items":{"item":[
{"dateName":"잘못된 연도","isHoliday":"Y","locdate":20970101}
]}}}}
''';
    expect(
      KasiHolidayService.instance.applyRawJsonForTesting(
        requestedYear,
        wrongYearJson,
      ),
      isTrue,
    );
    expect(KoreanHolidays.isDayOff(DateTime(requestedYear, 1, 1)), isFalse);
  });
}
