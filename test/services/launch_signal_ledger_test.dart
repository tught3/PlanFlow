import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/diag_logger.dart';
import 'package:planflow/services/launch_signal_ledger.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('reminder token persists across ledger instances', () async {
    final ledger = LaunchSignalLedger();
    expect(await ledger.lastNaverReminderToken(), isNull);
    await ledger
        .markNaverReminderToken('naver_ics_monthly_reminder:2026-11-01');
    expect(await LaunchSignalLedger().lastNaverReminderToken(),
        'naver_ics_monthly_reminder:2026-11-01');
  });

  test('share history keeps the latest twenty unique keys', () async {
    final ledger = LaunchSignalLedger(now: () => DateTime.utc(2026, 11, 4));
    for (var i = 0; i < 25; i++) {
      await ledger.recordShareKey('key-$i');
    }
    expect(await ledger.hasShareKey('key-4'), isFalse);
    expect(await ledger.hasShareKey('key-5'), isTrue);
    expect(await ledger.hasShareKey('key-24'), isTrue);
    await ledger.recordShareKey('key-5');
    final prefs = await SharedPreferences.getInstance();
    final entries = jsonDecode(prefs.getString('launch_ledger:ics_share:keys')!)
        as List<dynamic>;
    expect(entries, hasLength(20));
    expect(entries.last['k'], 'key-5');
  });

  test('share entries older than ninety days are removed', () async {
    var now = DateTime.utc(2026, 7, 1);
    final ledger = LaunchSignalLedger(now: () => now);
    await ledger.recordShareKey('old');
    now = now.add(const Duration(days: 90));
    expect(await ledger.hasShareKey('old'), isTrue);
    now = now.add(const Duration(seconds: 1));
    expect(await ledger.hasShareKey('old'), isFalse);
    await ledger.recordShareKey('new');
    final prefs = await SharedPreferences.getInstance();
    final entries = jsonDecode(prefs.getString('launch_ledger:ics_share:keys')!)
        as List<dynamic>;
    expect(entries.single['k'], 'new');
  });

  test('corrupt JSON is treated as empty and overwritten', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'launch_ledger:ics_share:keys': '{broken',
    });
    final ledger = LaunchSignalLedger();
    expect(await ledger.hasShareKey('old'), isFalse);
    await ledger.recordShareKey('new');
    expect(await ledger.hasShareKey('new'), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('launch_ledger:ics_share:keys')!),
        isA<List<dynamic>>());
  });

  test('invalid JSON entry shapes do not escape as exceptions', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'launch_ledger:ics_share:keys': '[null,1,{"k":4,"t":false}]',
    });
    final ledger = LaunchSignalLedger();
    expect(await ledger.hasShareKey('key'), isFalse);
    await expectLater(ledger.recordShareKey('safe'), completes);
    expect(await ledger.hasShareKey('safe'), isTrue);
  });

  test('unavailable or failing prefs preserve routing and do not throw',
      () async {
    for (final loader in <Future<SharedPreferences?> Function()>[
      () async => null,
      () async => throw StateError('private preference error'),
    ]) {
      final ledger = LaunchSignalLedger(prefsLoader: loader);
      expect(await ledger.lastNaverReminderToken(), isNull);
      expect(await ledger.hasShareKey('share'), isFalse);
      await expectLater(ledger.markNaverReminderToken('token'), completes);
      await expectLater(ledger.recordShareKey('share'), completes);
    }
  });

  test('diagnostics do not include preference errors or shared file paths',
      () async {
    DiagLogger.clear();
    const privateText = 'PRIVATE_FILE_OR_EXCEPTION';
    final ledger = LaunchSignalLedger(
      prefsLoader: () async => throw StateError(privateText),
    );
    await ledger.lastNaverReminderToken();
    await LaunchSignalLedger.computeShareKey(
      <String>['/$privateText.ics'],
      length: (_) async => throw StateError(privateText),
    );
    final log = DiagLogger.dump();
    expect(log, contains('ledger operation='));
    expect(log, isNot(contains(privateText)));
  });

  group('content-based share key', () {
    final contents = <String, Uint8List>{
      '/a/one.ics': Uint8List.fromList(<int>[1, 2, 3]),
      '/a/two.ics': Uint8List.fromList(<int>[4, 5, 6]),
      '/different/FILE_123.ics': Uint8List.fromList(<int>[1, 2, 3]),
    };

    Future<String?> key(List<String> paths) =>
        LaunchSignalLedger.computeShareKey(
          paths,
          readHead: (path, maxBytes) async {
            expect(maxBytes, 1024 * 1024);
            return contents[path];
          },
          length: (path) async => contents[path]?.length,
        );

    test('same input is deterministic', () async {
      expect(
          await key(<String>['/a/one.ics']), await key(<String>['/a/one.ics']));
      expect(await key(<String>['/a/one.ics']),
          matches(RegExp(r'^[a-f0-9]{64}$')));
    });

    test('path ordering does not affect the key', () async {
      expect(await key(<String>['/a/one.ics', '/a/two.ics']),
          await key(<String>['/a/two.ics', '/a/one.ics']));
    });

    test('renamed copies with identical length and content have the same key',
        () async {
      expect(await key(<String>['/a/one.ics']),
          await key(<String>['/different/FILE_123.ics']));
    });

    test('different contents change the key', () async {
      expect(await key(<String>['/a/one.ics']),
          isNot(await key(<String>['/a/two.ics'])));
    });

    test('trims paths and removes duplicate paths', () async {
      expect(await key(<String>[' /a/one.ics ', '/a/one.ics']),
          await key(<String>['/a/one.ics']));
    });

    test('missing file or empty input returns null', () async {
      expect(await key(<String>['/missing.ics']), isNull);
      expect(await key(<String>['/a/one.ics', '/missing.ics']), isNull);
      expect(await key(<String>[]), isNull);
    });

    test('reader errors return null', () async {
      expect(
        await LaunchSignalLedger.computeShareKey(
          <String>['/a/one.ics'],
          readHead: (_, __) async => throw StateError('private file error'),
          length: (_) async => 3,
        ),
        isNull,
      );
    });

    test('total length is part of the key beyond the hashed head', () async {
      Future<String?> withLength(int bytes) =>
          LaunchSignalLedger.computeShareKey(
            <String>['/a/one.ics'],
            readHead: (_, __) async => Uint8List.fromList(<int>[1, 2, 3]),
            length: (_) async => bytes,
          );
      expect(await withLength(1024 * 1024 + 1),
          isNot(await withLength(1024 * 1024 + 2)));
    });

    test('only the first one MiB participates in the content hash', () async {
      Future<String?> withTail(int tail) => LaunchSignalLedger.computeShareKey(
            <String>['/a/one.ics'],
            readHead: (_, __) async {
              final bytes = Uint8List(1024 * 1024 + 1);
              bytes.last = tail;
              return bytes;
            },
            length: (_) async => 1024 * 1024 + 1,
          );
      expect(await withTail(1), await withTail(2));
    });
  });
}
