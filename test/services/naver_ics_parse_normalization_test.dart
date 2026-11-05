import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/naver_ics_import_service.dart';

void main() {
  group('normalizeIcsText', () {
    test('normalizes plain CRLF lines', () {
      expect(normalizeIcsText('A:1\r\nB:2\r\n'), 'A:1\nB:2');
    });

    test('unfolds exactly one leading continuation character', () {
      expect(
        normalizeIcsText('SUMMARY:Weekly\r\n  sync\r\n'),
        'SUMMARY:Weekly sync',
      );
      expect(normalizeIcsText('DESCRIPTION:a\r\n\tb'), 'DESCRIPTION:ab');
      expect(normalizeIcsText('DESCRIPTION:a\r\n  b'), 'DESCRIPTION:a b');
    });

    test('removes BOM and empty or whitespace-only lines', () {
      expect(normalizeIcsText('\uFEFFA:1\n\n\nB:2'), 'A:1\nB:2');
      expect(normalizeIcsText('\uFEFFA:1\n\n \t \nB:2'), 'A:1\nB:2');
    });

    test('unfolds CRLF fields before parsing', () {
      final service = NaverIcsImportService(
        eventRepository: _UnusedEventRepository(),
      );
      final events = service.parseEvents(
        'BEGIN:VCALENDAR\r\n'
        'VERSION:2.0\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:folded\r\n'
        'SUMMARY:주간\r\n'
        ' 회의\r\n'
        'DTSTART;TZID=Asia/Seoul:20260506T110000\r\n'
        'DTEND;TZID=Asia/Seoul:20260506T120000\r\n'
        'DESCRIPTION:첫 줄\r\n'
        '  둘째\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR\r\n',
      );

      expect(events, hasLength(1));
      expect(events.single.title, '주간회의');
      expect(events.single.description, '첫 줄 둘째');
      expect(events.single.title.contains('\r'), isFalse);
      expect(events.single.description!.contains('\r'), isFalse);
      expect(events.single.startAt, DateTime.utc(2026, 5, 6, 2));
    });

    test('unfolds split multibyte UTF-8 bytes before decoding and parsing', () {
      const content = 'BEGIN:VCALENDAR\r\n'
          'VERSION:2.0\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:split-byte\r\n'
          'SUMMARY:가나\r\n'
          'DTSTART;TZID=Asia/Seoul:20260506T110000\r\n'
          'DTEND;TZID=Asia/Seoul:20260506T120000\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR\r\n';
      final encoded = utf8.encode(content);
      final multibyteStart = encoded.indexOf(0xeb);
      final foldedBytes = <int>[
        ...encoded.take(multibyteStart + 1),
        0x0d,
        0x0a,
        0x20,
        ...encoded.skip(multibyteStart + 1),
      ];
      final decoded = decodeIcsBytes(foldedBytes);

      expect(decoded, isNotNull);
      final service = NaverIcsImportService(
        eventRepository: _UnusedEventRepository(),
      );
      final events = service.parseEvents(decoded!);
      expect(events.single.title, '가나');
      expect(events.single.title.contains('\uFFFD'), isFalse);
    });

    test('leaves LF-only content unchanged', () {
      const content = 'BEGIN:VCALENDAR\nSUMMARY:Plain\nEND:VCALENDAR';
      expect(normalizeIcsText(content), content);
    });
  });
}

class _UnusedEventRepository extends EventRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
