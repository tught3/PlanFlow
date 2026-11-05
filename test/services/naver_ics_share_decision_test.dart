import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/launch_signal_ledger.dart';
import 'package:planflow/services/naver_ics_share_filter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late LaunchSignalLedger ledger;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    ledger = LaunchSignalLedger();
    directory = await Directory.systemTemp.createTemp('ics-share-decision-');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<File> createFile(String name, String contents) async {
    final file = File('${directory.path}${Platform.pathSeparator}$name');
    return file.writeAsString(contents);
  }

  test('empty paths have no candidate and leave the ledger untouched',
      () async {
    expect(
      await decideIcsShare(source: 'initial', paths: [], ledger: ledger),
      IcsShareDecision.noCandidate,
    );
    expect(prefs.getKeys(), isEmpty);
  });

  test('missing initial file is skipped and leaves the ledger untouched',
      () async {
    final missing = File('${directory.path}${Platform.pathSeparator}missing');
    expect(
      await decideIcsShare(
        source: 'initial',
        paths: [missing.path],
        ledger: ledger,
      ),
      IcsShareDecision.skipMissingFile,
    );
    expect(prefs.getKeys(), isEmpty);
  });

  test('initial share routes once for identical content even after rename',
      () async {
    final original = await createFile('original.ics', 'calendar content');
    final copy = await original.copy(
      '${directory.path}${Platform.pathSeparator}copy.ics',
    );

    expect(
      await decideIcsShare(
        source: 'initial',
        paths: [original.path],
        ledger: ledger,
      ),
      IcsShareDecision.route,
    );
    for (final file in [original, copy]) {
      expect(
        await decideIcsShare(
          source: 'initial',
          paths: [file.path],
          ledger: ledger,
        ),
        IcsShareDecision.skipAlreadyHandled,
      );
    }
  });

  test('initial shares with different content each route', () async {
    final first = await createFile('first.ics', 'first calendar');
    final second = await createFile('second.ics', 'second calendar');

    for (final file in [first, second]) {
      expect(
        await decideIcsShare(
          source: 'initial',
          paths: [file.path],
          ledger: ledger,
        ),
        IcsShareDecision.route,
      );
    }
  });

  test('stream share routes repeatedly and records its content key', () async {
    final file = await createFile('stream.ics', 'calendar content');
    final key = await LaunchSignalLedger.computeShareKey([file.path]);
    expect(key, isNotNull);

    for (var i = 0; i < 2; i++) {
      expect(
        await decideIcsShare(
          source: 'stream',
          paths: [file.path],
          ledger: ledger,
        ),
        IcsShareDecision.route,
      );
      expect(await ledger.hasShareKey(key!), isTrue);
    }
  });

  test('stream share with a missing file still routes', () async {
    final missing = File('${directory.path}${Platform.pathSeparator}missing');
    expect(
      await decideIcsShare(
        source: 'stream',
        paths: [missing.path],
        ledger: ledger,
      ),
      IcsShareDecision.route,
    );
    expect(prefs.getKeys(), isEmpty);
  });
}
