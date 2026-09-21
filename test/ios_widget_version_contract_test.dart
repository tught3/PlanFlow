import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Regression guard for the PlanFlowWidgetExtension bundle version chain.
///
/// Root cause this guard locks down (iOS Simulator E2E run 1, all four
/// devices): `ios/PlanFlowWidget/Info.plist` resolves
/// `CFBundleShortVersionString` from `$(MARKETING_VERSION)` and
/// `CFBundleVersion` from `$(CURRENT_PROJECT_VERSION)`, but the widget target
/// had no `MARKETING_VERSION` at all and pointed `CURRENT_PROJECT_VERSION` at
/// `$(FLUTTER_BUILD_NUMBER)` — a variable that is only defined in
/// `Generated.xcconfig`, which the widget's xcconfig chain deliberately does
/// not include (it is a native extension, not a Flutter target). Both keys
/// therefore compiled to empty/unresolved values and `xcrun simctl install`
/// rejected the app with "Failed to create app extension placeholder /
/// Invalid placeholder attributes".
///
/// `ios-release.yml` never hit this because it passes `MARKETING_VERSION` and
/// `CURRENT_PROJECT_VERSION` on the `xcodebuild archive` command line, which
/// overrides project-file values for every target.
///
/// This test reads the real files off disk (no mocks) and walks the xcconfig
/// `#include` chain, so it fails if either key is removed, or if it is pointed
/// at a variable that the widget's own configuration chain cannot resolve to a
/// literal.
///
/// The repository root is injectable via `PLANFLOW_CONTRACT_ROOT` so the same
/// parser can be pointed at a materialized older revision of `ios/` to prove
/// this guard actually rejects the broken state (see the phase report).
void main() {
  final root = Platform.environment['PLANFLOW_CONTRACT_ROOT']?.trim().isNotEmpty
          == true
      ? Platform.environment['PLANFLOW_CONTRACT_ROOT']!.trim()
      : Directory.current.path;

  String readFile(String relativePath) =>
      File('$root${Platform.pathSeparator}$relativePath')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');

  /// Parses `KEY = VALUE` assignments out of an xcconfig file, following
  /// `#include "..."` and `#include? "..."` directives depth-first, exactly the
  /// way xcodebuild layers them (later assignments win).
  Map<String, String> resolveXcconfig(
    String fileName, {
    Set<String>? visited,
  }) {
    final seen = visited ?? <String>{};
    if (!seen.add(fileName)) return <String, String>{};

    final file = File('$root${Platform.pathSeparator}ios'
        '${Platform.pathSeparator}Flutter${Platform.pathSeparator}$fileName');
    if (!file.existsSync()) return <String, String>{};

    final settings = <String, String>{};
    final includePattern = RegExp(r'^\s*#include\??\s+"([^"]+)"');
    final assignPattern = RegExp(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$');

    for (final rawLine in file.readAsStringSync().replaceAll('\r\n', '\n').split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('//')) continue;

      final include = includePattern.firstMatch(rawLine);
      if (include != null) {
        settings.addAll(resolveXcconfig(include.group(1)!, visited: seen));
        continue;
      }

      final assign = assignPattern.firstMatch(rawLine);
      if (assign != null) {
        settings[assign.group(1)!] = assign.group(2)!.trim();
      }
    }
    return settings;
  }

  final pbxproj =
      readFile('ios${Platform.pathSeparator}Runner.xcodeproj'
          '${Platform.pathSeparator}project.pbxproj');

  // Every XCBuildConfiguration block, keyed by its configuration name.
  final blockPattern = RegExp(
    r'\n\t\t[0-9A-Fa-f]+ /\* (\w+) \*/ = \{\n'
    r'\t\t\tisa = XCBuildConfiguration;\n'
    r'(.*?)\n\t\t\};',
    dotAll: true,
  );

  // The widget extension configurations are the ones building
  // PlanFlowWidget/Info.plist. Identifying them structurally (rather than by
  // hard-coded object UUID) keeps the guard valid if Xcode rewrites UUIDs.
  final widgetConfigs = <String, String>{};
  for (final match in blockPattern.allMatches(pbxproj)) {
    final body = match.group(2)!;
    if (body.contains('INFOPLIST_FILE = PlanFlowWidget/Info.plist;')) {
      widgetConfigs[match.group(1)!] = body;
    }
  }

  String? settingOf(String body, String key) {
    final match =
        RegExp('^\\s*$key = (.*);\\s*\$', multiLine: true).firstMatch(body);
    if (match == null) return null;
    var value = match.group(1)!.trim();
    if (value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }

  String baseXcconfigOf(String body) {
    final match =
        RegExp(r'baseConfigurationReference = [0-9A-Fa-f]+ /\* ([^*]+?) \*/;')
            .firstMatch(body);
    expect(
      match,
      isNotNull,
      reason: 'A widget build configuration has no baseConfigurationReference; '
          'its version variables could not be resolved from any xcconfig.',
    );
    return match!.group(1)!.trim();
  }

  test('Info.plist still sources the widget version from build settings', () {
    final plist = readFile(
        'ios${Platform.pathSeparator}PlanFlowWidget${Platform.pathSeparator}Info.plist');
    expect(plist, contains(r'<string>$(MARKETING_VERSION)</string>'));
    expect(plist, contains(r'<string>$(CURRENT_PROJECT_VERSION)</string>'));
  });

  test('all three PlanFlowWidgetExtension configurations are present', () {
    expect(
      widgetConfigs.keys.toSet(),
      {'Debug', 'Release', 'Profile'},
      reason: 'Expected exactly the Debug/Release/Profile build configurations '
          'of the PlanFlowWidgetExtension target in project.pbxproj.',
    );
  });

  for (final configName in const ['Debug', 'Release', 'Profile']) {
    for (final key in const ['MARKETING_VERSION', 'CURRENT_PROJECT_VERSION']) {
      test('$configName defines $key and it resolves to a literal', () {
        final body = widgetConfigs[configName];
        expect(
          body,
          isNotNull,
          reason: 'PlanFlowWidgetExtension $configName configuration missing.',
        );

        final value = settingOf(body!, key);
        expect(
          value,
          isNotNull,
          reason: '$key is missing from the PlanFlowWidgetExtension '
              '$configName build settings. PlanFlowWidget/Info.plist '
              'references it, so an absent value makes simctl reject the app '
              'with "Invalid placeholder attributes".',
        );

        final reference = RegExp(r'^\$\(([A-Za-z_][A-Za-z0-9_]*)\)$')
            .firstMatch(value!.trim());
        expect(
          reference,
          isNotNull,
          reason: '$key of $configName should reference a single xcconfig '
              'variable, got "$value".',
        );

        final variable = reference!.group(1)!;
        final resolved = resolveXcconfig(baseXcconfigOf(body))[variable];
        expect(
          resolved,
          isNotNull,
          reason: '$key of $configName points at \$($variable), but that '
              'variable is not defined anywhere in the widget xcconfig include '
              'chain, so it expands to an empty string at build time. '
              '(This is exactly the FLUTTER_BUILD_NUMBER failure: it lives in '
              'Generated.xcconfig, which the widget target does not include.)',
        );
        expect(
          resolved,
          isNot(contains(r'$(')),
          reason: '\$($variable) must resolve to a literal, got "$resolved".',
        );
        expect(resolved!.trim(), isNotEmpty);
      });
    }
  }

  test('widget version literals stay in sync with pubspec.yaml', () {
    final pubspecVersion = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$',
            multiLine: true)
        .firstMatch(readFile('pubspec.yaml'));
    expect(pubspecVersion, isNotNull,
        reason: 'pubspec.yaml version: must stay in X.Y.Z+N form.');

    final settings = resolveXcconfig(baseXcconfigOf(widgetConfigs['Release']!));
    expect(settings['PLANFLOW_WIDGET_MARKETING_VERSION'],
        pubspecVersion!.group(1));
    expect(settings['PLANFLOW_WIDGET_BUILD_NUMBER'], pubspecVersion.group(2));
  });

  group('widget schedule payload v2 contract', () {
    String contract() => readFile(
        'lib${Platform.pathSeparator}services${Platform.pathSeparator}'
        'widget_schedule_contract.dart');

    test('schema version is bumped to 2', () {
      expect(
        contract(),
        contains('static const int currentSchemaVersion = 2;'),
        reason: 'widget_schedule_payload_v2 requires the Dart contract to '
            'declare schemaVersion 2.',
      );
    });

    test('v2 adds month/week projections without removing v1 keys', () {
      final source = contract();
      // v1 keys stay.
      expect(source, contains("'holidayDates'"));
      expect(source, contains("'dayCounts'"));
      // v2 additive keys.
      expect(source, contains('WidgetMonthPayload'));
      expect(source, contains('WidgetMonthCellPayload'));
      expect(source, contains('WidgetWeekPayload'));
      expect(source, contains('WidgetWeekDayPayload'));
      expect(source, contains("'segment'"));
      expect(source, contains("'showTitle'"));
    });

    test('home widget service dual-writes v2 alongside v1', () {
      final service = readFile('lib${Platform.pathSeparator}services'
          '${Platform.pathSeparator}home_widget_service.dart');
      expect(service, contains("'widget_schedule_payload_v1'"));
      expect(service, contains("'widget_schedule_payload_v2'"),
          reason: 'The v2 key must be written from the same Dart schedule '
              'truth, never a second source.');
    });
  });

  group('WidgetKit bundle lists all seven Android widget counterparts', () {
    /// (Swift kind, Android provider class) pairs.
    const expectedKinds = <(String, String)>[
      ('PlanFlowWidget', 'PlanFlowHomeWidgetProvider'),
      ('PlanFlowMonthlyWidget', 'PlanFlowMonthlyWidgetProvider'),
      ('PlanFlowVerticalScheduleWidget', 'PlanFlowVerticalScheduleWidgetProvider'),
      ('PlanFlowWeeklyWidget', 'PlanFlowWeeklyWidgetProvider'),
      ('PlanFlowWeeklyListWidget', 'PlanFlowWeeklyListWidgetProvider'),
      ('PlanFlowMicWidget', 'PlanFlowMicWidgetProvider'),
      ('PlanFlowGroupCalendarWidget', 'PlanFlowGroupCalendarWidgetProvider'),
    ];

    String widgetSources() {
      final dir = Directory(
          '$root${Platform.pathSeparator}ios'
          '${Platform.pathSeparator}PlanFlowWidget');
      return dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.swift'))
          .map((file) => file.readAsStringSync().replaceAll('\r\n', '\n'))
          .join('\n');
    }

    test('bundle registers exactly the seven widget kinds', () {
      final source = widgetSources();
      for (final kind in expectedKinds.map((pair) => pair.$1)) {
        expect(
          source,
          contains('kind: "$kind"'),
          reason: '$kind must be registered in the PlanFlowWidgetBundle so '
              'the iOS widget gallery offers all seven Android counterparts.',
        );
      }
      // Dart writes the iOS kind for the group widget refresh.
      final groupService = readFile('lib${Platform.pathSeparator}features'
          '${Platform.pathSeparator}groups${Platform.pathSeparator}services'
          '${Platform.pathSeparator}group_calendar_widget_service.dart');
      expect(groupService, contains("'PlanFlowGroupCalendarWidget'"));
    });

    test('monthly widget offers the iOS 27 portrait extra-large family without dropping legacy sizes', () {
      final source = widgetSources();
      expect(source, contains('planFlowMonthlySupportedFamilies'));
      expect(source, contains('.systemMedium'));
      expect(source, contains('.systemLarge'));
      expect(source, contains('.systemExtraLargePortrait'));
      expect(source, contains('#if compiler(>=6.4)'));
      expect(source, contains('#available(iOSApplicationExtension 27.0, *)'));
      expect(source, contains('usesExtraLargePortraitLayout'));
      expect(
        source,
        contains('family == .systemExtraLargePortrait'),
        reason: 'The tall monthly layout must only activate for the new iOS 27 portrait family.',
      );
    });

    test('payload decoder keeps the v1 fallback and deep-link hosts', () {
      final source = widgetSources();
      expect(source, contains('widget_schedule_payload_v1'),
          reason: 'The decoder must fall back to the v1 payload key so old '
              'data keeps rendering.');
      expect(source, contains('widget_schedule_payload_v2'));
      expect(source, contains('planflow://voice-launcher'));
      expect(source, contains('planflow://calendar'));
      expect(source, contains('planflow://event/'));
      expect(source, contains('planflow://day/'));
      expect(source, contains('planflow://group-calendar'));
      expect(source, contains('containerBackground(for: .widget)'),
          reason: 'iOS 17+ widgets must declare a container background '
              '(fixes the accidental black container).');
    });
  });
}
