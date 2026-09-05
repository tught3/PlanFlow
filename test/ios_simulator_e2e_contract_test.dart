import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression guard for the PlanFlow iOS Simulator E2E Phase (P1-P12).
///
/// This file reads the real artifacts produced by that phase directly off
/// disk (no mocks) and asserts the invariants the phase established, so a
/// later edit that silently breaks one of them fails this test instead of
/// surfacing much later on a macOS CI runner or in App Store review.
void main() {
  final root = Directory.current;
  File file(String path) => File('${root.path}${Platform.pathSeparator}$path');
  Directory dir(String path) =>
      Directory('${root.path}${Platform.pathSeparator}$path');

  group('P13.1 pre-existing workflow files are byte-for-byte unchanged', () {
    // These SHA-256 digests were computed directly from the files on disk at
    // the time this guard was written (P13). The iOS Simulator E2E phase
    // (P1-P12) only ever added new files (ios-simulator-e2e.yml, new docs,
    // new scripts, new tests) — it never had a reason to touch these four
    // pre-existing workflows. If any of them changes, this test fails and
    // whoever changed it must explain why (and, if legitimate, update the
    // expected digest here deliberately rather than by accident).
    const expectedDigests = <String, String>{
      '.github/workflows/ios-release.yml':
          '6a17ca3740b7a0ae844147a4d8199d637ab312ed56e1d90979ae923cc0bbd54f',
      '.github/workflows/ios-privacy-audit.yml':
          '3307f3b190feffe65d2e0f4696044fd935e6924a3cbd33c33a562034bb615a60',
      '.github/workflows/ios-readiness.yml':
          '4c1853919a18364098b85a6546edddb3ba031c6633ba5fc1d7c6d688cf20547e',
      '.github/workflows/ios-testflight-ingestion.yml':
          '1077068ded33ccb95ebfc32dc50601af704c040a5b63ff24afcda70655eec834',
    };

    for (final entry in expectedDigests.entries) {
      test('${entry.key} matches its recorded SHA-256', () {
        // The digests above are LF-normalized on purpose. These workflows are
        // stored with LF in git, but a Windows checkout (core.autocrlf) hands
        // them to us with CRLF, so hashing the raw bytes would fail on Windows
        // while the tracked content is byte-for-byte identical. Normalizing
        // CRLF -> LF before hashing keeps this a content guard on every host
        // instead of an accidental line-ending guard.
        final bytes = file(entry.key).readAsBytesSync();
        final actual = sha256.convert(_normalizeEol(bytes)).toString();
        expect(
          actual,
          entry.value,
          reason:
              '${entry.key} changed since the iOS Simulator E2E phase (P13) '
              'recorded its digest. This workflow was not supposed to be '
              'touched by that phase; if this change is legitimate, update '
              'the expected digest in this test deliberately. '
              '(Line endings are normalized before hashing, so a CRLF/LF '
              'difference alone cannot cause this failure.)',
        );
      });
    }
  });

  group('P13.2 ios-simulator-e2e.yml has zero hardcoded iOS version literals',
      () {
    test('no dotted-decimal version literal appears outside the '
        'Flutter SDK version line', () {
      final content =
          file('.github/workflows/ios-simulator-e2e.yml').readAsStringSync();
      // Matches e.g. "17.4", "16.0", "15.2.1" — the shape of an iOS version
      // number. scripts/ios/simctl_discover.sh is the only thing allowed to
      // know what iOS versions exist (queried live from `xcrun simctl` on
      // the runner); this workflow file must only ever consume its JSON
      // output, never hardcode a version itself.
      final versionLiteral = RegExp(r'\b\d+\.\d+(\.\d+)?\b');
      final offendingLines = <String>[];
      for (final line in const LineSplitter().convert(content)) {
        // `flutter-version: 3.47.2` pins the Flutter SDK toolchain version,
        // not an iOS runtime/deployment-target version. It is the one
        // legitimate dotted-decimal literal this workflow is allowed to
        // contain.
        if (line.contains('flutter-version')) continue;
        if (versionLiteral.hasMatch(line)) {
          offendingLines.add(line.trim());
        }
      }
      expect(
        offendingLines,
        isEmpty,
        reason: 'Found hardcoded version-like literal(s) in '
            'ios-simulator-e2e.yml outside the flutter-version line: '
            '$offendingLines',
      );
    });
  });

  group('P13.3 simctl_discover.sh queries the live simulator catalog', () {
    test('discovers both runtimes and device types via `simctl list`', () {
      final content =
          file('scripts/ios/simctl_discover.sh').readAsStringSync();
      expect(content, contains('simctl list runtimes'));
      expect(content, contains('simctl list devicetypes'));
    });
  });

  group('P13.4 SIMULATOR_QA_MATRIX.md has >=30 rows and only known '
      'classification values', () {
    // Parses the "|" delimited markdown table without a markdown library:
    // any line starting with "|" whose first cell parses as an integer is
    // treated as a data row (this naturally skips the header row ("# | ...")
    // and the "---" separator row, neither of which starts with a digit).
    List<List<String>> parseNumberedTableRows(String content) {
      final rows = <List<String>>[];
      for (final rawLine in const LineSplitter().convert(content)) {
        final line = rawLine.trim();
        if (!line.startsWith('|')) continue;
        var inner = line.substring(1);
        if (inner.endsWith('|')) {
          inner = inner.substring(0, inner.length - 1);
        }
        final cells = inner.split('|').map((c) => c.trim()).toList();
        if (cells.isEmpty) continue;
        if (int.tryParse(cells.first) == null) continue;
        rows.add(cells);
      }
      return rows;
    }

    test('table has at least 30 numbered data rows', () {
      final content =
          file('docs/ios/SIMULATOR_QA_MATRIX.md').readAsStringSync();
      final rows = parseNumberedTableRows(content);
      expect(rows.length, greaterThanOrEqualTo(30),
          reason: 'Expected >=30 numbered rows in the QA matrix table, '
              'found ${rows.length}');
    });

    test('every row\'s 분류(classification) column is one of the three '
        'known values (or the explicitly documented ATT exception)', () {
      final content =
          file('docs/ios/SIMULATOR_QA_MATRIX.md').readAsStringSync();
      final rows = parseNumberedTableRows(content);
      expect(rows, isNotEmpty);

      // The 분류 (classification) column is index 2:
      // # | 항목명 | 분류 | 이유 | 검증방법 | 릴리스영향도 | ... | 담당FLOW
      const classificationColumnIndex = 2;

      // The document itself documents exactly one exception to the three
      // canonical classifications: item 28 (ATT), whose classification is
      // "확인 필요(별도 문서 참조)" because the matrix explicitly declines to
      // classify it (background investigation found zero
      // app_tracking_transparency usage; see the doc's own summary section).
      // Row 29 also carries a documented CI-pending suffix on
      // SIMULATOR_PARTIAL — startsWith() below accepts that suffix without
      // opening the door to an arbitrary new classification string.
      const attException = '확인 필요(별도 문서 참조)';

      bool isKnownClassification(String value) {
        if (value == attException) return true;
        if (value == 'SIMULATOR_FULL') return true;
        if (value == 'PHYSICAL_DEVICE_REQUIRED') return true;
        if (value.startsWith('SIMULATOR_PARTIAL')) return true;
        return false;
      }

      final offenders = <String>[];
      for (final row in rows) {
        if (row.length <= classificationColumnIndex) {
          offenders.add('row ${row.first}: missing classification column');
          continue;
        }
        final classification = row[classificationColumnIndex];
        if (!isKnownClassification(classification)) {
          offenders.add('row ${row.first}: "$classification"');
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'Found unknown classification value(s) in '
            'SIMULATOR_QA_MATRIX.md: $offenders',
      );
    });
  });

  group('P13.5 docs/ios/templates/** contain no PlanFlow-specific literals',
      () {
    // README.md, PARAMETERS.md and planflow.values.md are intentionally
    // excluded — they are the documentation/example files that are supposed
    // to mention PlanFlow's real bundle id and Supabase ref as a worked
    // example for whoever adapts these templates to a new app. The .tmpl
    // files themselves must stay app-agnostic.
    test('workflow-templates/*.tmpl and checklist-templates/*.tmpl are '
        'free of PlanFlow-specific literals', () {
      final templateDirs = [
        dir('docs/ios/templates/workflow-templates'),
        dir('docs/ios/templates/checklist-templates'),
      ];

      final tmplFiles = <File>[];
      for (final templateDir in templateDirs) {
        for (final entity in templateDir.listSync()) {
          if (entity is File && entity.path.endsWith('.tmpl')) {
            tmplFiles.add(entity);
          }
        }
      }

      expect(tmplFiles, isNotEmpty,
          reason: 'Expected to find at least one .tmpl file under '
              'docs/ios/templates/{workflow,checklist}-templates');

      const forbiddenLiterals = [
        'com.fluxstudio.planflow',
        'xqvvfnvmytjlblcngipn',
      ];

      for (final tmplFile in tmplFiles) {
        final content = tmplFile.readAsStringSync();
        for (final literal in forbiddenLiterals) {
          expect(
            content.contains(literal),
            isFalse,
            reason: '${tmplFile.path} contains the PlanFlow-specific '
                'literal "$literal", but template files under '
                'workflow-templates/ and checklist-templates/ must stay '
                'app-agnostic.',
          );
        }
      }
    });
  });

  group('P13.6 main() behavior seam is unchanged', () {
    test('main() delegates to runPlanFlowApp() and nothing else', () {
      final content = file('lib/main.dart').readAsStringSync();
      final mainBody = RegExp(
        r'Future<void>\s+main\(\)\s+async\s*\{([\s\S]*?)\}',
      ).firstMatch(content);
      expect(mainBody, isNotNull, reason: 'main() function not found');
      final body = mainBody!.group(1)!.trim();
      expect(
        body,
        matches(RegExp(r'^await\s+runPlanFlowApp\(\)\s*;$')),
        reason: 'main() must contain exactly one statement: '
            '"await runPlanFlowApp();" — found: "$body"',
      );
    });

    test('runPlanFlowApp is annotated @visibleForTesting', () {
      final content = file('lib/main.dart').readAsStringSync();
      final declarationIndex =
          content.indexOf(RegExp(r'Future<void>\s+runPlanFlowApp\('));
      expect(declarationIndex, greaterThan(-1),
          reason: 'runPlanFlowApp() declaration not found');
      final preceding = content.substring(0, declarationIndex);
      final lastAnnotationLine =
          const LineSplitter().convert(preceding).reversed.firstWhere(
                (line) => line.trim().isNotEmpty,
                orElse: () => '',
              );
      expect(
        lastAnnotationLine.trim(),
        '@visibleForTesting',
        reason: 'runPlanFlowApp() must be immediately preceded by '
            '@visibleForTesting so integration_test entry points can '
            'inject Riverpod provider overrides.',
      );
    });
  });
}

/// Strips CR bytes that precede an LF so a CRLF checkout hashes to the same
/// digest as the LF content git actually tracks. A bare CR (old-Mac EOL) is
/// left alone, and so is a CR that is not part of a CRLF pair, because those
/// would be genuine content differences rather than a checkout artifact.
List<int> _normalizeEol(List<int> bytes) {
  const cr = 0x0D;
  const lf = 0x0A;
  final out = <int>[];
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == cr && i + 1 < bytes.length && bytes[i + 1] == lf) {
      continue;
    }
    out.add(bytes[i]);
  }
  return out;
}
