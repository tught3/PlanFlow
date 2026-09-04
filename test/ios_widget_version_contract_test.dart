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
}
