import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/naver_ics_share_filter.dart';

void main() {
  group('isIcsShareCandidate', () {
    for (final sample in <(String, String?, bool)>[
      ('/shared/report.pdf', 'application/octet-stream', false),
      ('/shared/calendar.ICS', 'application/octet-stream', true),
      ('/shared/calendar', 'text/calendar', true),
      ('/shared/calendar.ics', null, true),
      ('/shared/image.png', 'image/png', false),
      ('/shared/calendar', 'application/ics', true),
      ('/shared/calendar', 'text/x-vcalendar', true),
      (' /shared/calendar.ICS ', null, true),
      ('/shared/calendar', ' TEXT/CALENDAR ', true),
      ('/shared/calendar.ics.pdf', 'application/octet-stream', false),
      ('/shared/calendar.ics?download=1', 'application/octet-stream', false),
    ]) {
      test('${sample.$1} with ${sample.$2} is ${sample.$3}', () {
        expect(
          isIcsShareCandidate(path: sample.$1, mimeType: sample.$2),
          sample.$3,
        );
      });
    }
  });
}
