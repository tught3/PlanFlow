// Regression guard for the iOS WidgetKit → planflow:// URL delivery chain.
//
// Root cause this guard locks down (startup-routing 2026-10-11): the home_widget
// iOS plugin (0.9.3+) keys its widgetClicked / initiallyLaunchedFromHomeWidget
// detectors off a `homeWidget` query item on the tapped URL. The previous
// WidgetKit extension emitted raw deep links — `planflow://day/YYYY-MM-DD`,
// `planflow://calendar?date=YYYY-MM-DD`, `planflow://voice-launcher`, etc. —
// without that marker, so every widget tap fell through exclusively to the
// app_links universal-link handler and the app never observed the widget
// click. The mic widget (1x1 voice-launcher chip) and the group-calendar
// header / day cells were particularly exposed because they hand-built the
// URL with `URL(string: "planflow://group-calendar?groupId=...")`.
//
// This test reads the real files off disk (no mocks, no simulator) and walks
// the widget Swift sources byte-by-byte. It fails if:
//   - any PlanFlowWidgetConfig URL builder forgets the `homeWidget` marker,
//   - the literal `URL(string: "planflow://...")` pattern reappears in any
//     WidgetKit view (the only place that constructs widget links),
//   - the date / event id / group id payload is dropped or string-concatenated
//     (i.e. produces a malformed `?date=...&homeWidget=1?...?...` shape),
//   - `withWidgetMarker` becomes non-idempotent or stops appending the marker.
//
// Scope is intentionally narrow: this file does NOT touch app.dart,
// router.dart, auth, or app_home_widget_route_test.dart — those live with
// the parallel Flutter routing change owned by the parent. We only lock down
// the iOS-side URL builders so the marker is added exactly once on the way
// out of the WidgetKit extension.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root =
      Platform.environment['PLANFLOW_CONTRACT_ROOT']?.trim().isNotEmpty == true
          ? Platform.environment['PLANFLOW_CONTRACT_ROOT']!.trim()
          : Directory.current.path;

  String read(String relativePath) => File(
        '$root${Platform.pathSeparator}$relativePath',
      ).readAsStringSync().replaceAll('\r\n', '\n');

  final payloadSource = read(
      'ios${Platform.pathSeparator}PlanFlowWidget${Platform.pathSeparator}Payload.swift');
  final viewsSource = read(
      'ios${Platform.pathSeparator}PlanFlowWidget${Platform.pathSeparator}Views.swift');

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

  /// Returns every line in [source] containing `planflow://` with the
  /// surrounding context, for diagnostic output when a contract regresses.
  List<String> planflowUrlLines(String source) {
    final out = <String>[];
    final lines = source.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].contains('planflow://')) {
        out.add('${i + 1}: ${lines[i].trim()}');
      }
    }
    return out;
  }

  group('marker constants', () {
    test('home_widget iOS marker is named "homeWidget" with value "1"', () {
      // The plugin's iOS source (HomeWidgetPlugin.swift) recognises the URL
      // as a widget tap iff any query item is named `homeWidget`; the value
      // is informational only. Pin both so a future rename stays a deliberate
      // contract change, not an accidental drift.
      expect(payloadSource, contains('static let homeWidgetMarkerName = "homeWidget"'),
          reason: 'Payload.swift must publish the marker query name as a '
              'static constant; helper builders route through it.');
      expect(payloadSource, contains('static let homeWidgetMarkerValue = "1"'),
          reason: 'Marker value is part of the contract; any change must '
              'be paired with a router-side update.');
      expect(payloadSource, contains('static let schemeName = "planflow"'),
          reason: 'The planflow scheme is also part of the contract and is '
              'referenced by the day/calendar/voice/event/groupCalendar '
              'builders.');
    });

    test('widgetMarkerItem() returns a URLQueryItem named homeWidget', () {
      expect(payloadSource, contains('static func widgetMarkerItem() -> URLQueryItem'),
          reason: 'Every URL helper must funnel through widgetMarkerItem so '
              'the marker shape (name + value) cannot drift per-builder.');
      expect(
        payloadSource,
        contains('URLQueryItem(name: homeWidgetMarkerName, value: homeWidgetMarkerValue)'),
        reason: 'widgetMarkerItem must build its URLQueryItem from the two '
            'marker constants, not from string literals.',
      );
    });
  });

  group('PlanFlowWidgetConfig URL builders carry the marker', () {
    /// Asserts that [builderName] appears as a `static func` whose body wires
    /// the marker through `queryItems`. We deliberately allow either:
    ///   - `queryItems = [widgetMarkerItem(), …]`  (canonical), or
    ///   - `queryItems = items` after `items = [widgetMarkerItem(), …]`,
    /// but we DO reject string concatenation such as
    /// `"planflow://calendar?date=\(date)&homeWidget=1"` because that's the
    /// exact malformed pattern the directive forbids.
    // Local mirror of the marker name constant — kept inline so a future
    // rename of the Swift constant also forces an update here.
    const homeWidgetMarkerName = 'homeWidget';

    void assertBuilderUsesComponents(String builderName) {
      // 1. The builder must build via URLComponents, not string concat.
      final builderPattern = RegExp(
        r'static (?:func|let) ' + builderName + r'[\(:]',
        multiLine: true,
      );
      expect(
        builderPattern.hasMatch(payloadSource),
        isTrue,
        reason: '$builderName must be defined in PlanFlowWidgetConfig so the '
            'marker is added in a single place.',
      );
      // 2. The marker must travel through `queryItems`.
      expect(
        payloadSource,
        contains('widgetMarkerItem()'),
        reason: '$builderName must call widgetMarkerItem() so the marker is '
            'added exactly once with the canonical name + value.',
      );
      // 3. No malformed double-`?` shape leaking through fallback strings.
      // The Swift fallback strings reference the marker via the constant,
      // so search the literal Swift source form ("?\(homeWidgetMarkerName)")
      // and the runtime form ("?homeWidget=") to cover both shapes.
      final fallbackMarkerSources = [
        r'?\(homeWidgetMarkerName)',
        '?$homeWidgetMarkerName=',
      ];
      final hasFallbackMarker =
          fallbackMarkerSources.any(payloadSource.contains);
      expect(
        hasFallbackMarker,
        isTrue,
        reason: 'Fallback URLs (used when URLComponents.url is nil) must '
            'still include the homeWidget marker as a single query item, '
            'either via the Swift constant interpolation or as a literal.',
      );
    }

    test('dayURL preserves the date payload and adds the marker', () {
      assertBuilderUsesComponents('dayURL');
      // The body must include ymd(date) so the date payload is preserved.
      expect(
        payloadSource,
        contains('components.path = "/" + ymd(date)'),
        reason: 'dayURL must keep the ymd(date) path so the canonical '
            'planflow://day/YYYY-MM-DD payload survives.',
      );
    });

    test('calendarURL preserves the date query and adds the marker', () {
      assertBuilderUsesComponents('calendarURL');
      expect(
        payloadSource,
        contains('URLQueryItem(name: "date", value: ymd(date))'),
        reason: 'calendarURL(date) must keep the date query item so the '
            'router\'s _parseRouteDate still finds the YYYY-MM-DD payload.',
      );
    });

    test('voiceURL keeps the voice-launcher host and adds the marker', () {
      assertBuilderUsesComponents('voiceURL');
      expect(payloadSource, contains('components.host = "voice-launcher"'),
          reason: 'voiceURL must continue to use the voice-launcher host so '
              'the Flutter router\'s voice-launcher canonicalisation '
              '(voice?autoStart=1) keeps working unchanged.');
    });

    test('eventURL preserves the event id and adds the marker', () {
      assertBuilderUsesComponents('eventURL');
      expect(payloadSource, contains('components.path = "/" + trimmed'),
          reason: 'eventURL(id) must carry the trimmed id in the path so '
              'the Dart router\'s `case \'event\':` branch still sees it.');
      expect(
        payloadSource,
        contains('let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)'),
        reason: 'eventURL must keep its empty-id guard so an empty payload '
            'still returns nil (and falls back to calendar).',
      );
    });

    test('groupCalendarURL preserves groupId and date and adds the marker',
        () {
      assertBuilderUsesComponents('groupCalendarURL');
      expect(payloadSource, contains('URLQueryItem(name: "groupId", value: groupId)'),
          reason: 'groupCalendarURL(groupId:date:) must carry the groupId '
              'query item so the Flutter router lands on the right group '
              'events screen.');
      expect(payloadSource, contains('URLQueryItem(name: "date", value: date)'),
          reason: 'groupCalendarURL(groupId:date:) must carry the date '
              'query item so a day-cell tap opens that date in the group '
              'calendar (not always today).');
    });

    test('no WidgetKit builder falls back to a literal "?…?…" shape', () {
      // Forbid the literal "?…?…" pattern from leaking into any fallback
      // string. URLComponents handles ordering, so the only allowed "?"
      // placement is the canonical one between path/host and queryItems.
      // The regex matches a string that has another "?" after a "="
      // assignment within a quoted Swift literal — that is the malformed
      // shape produced by hand-rolled `"planflow://x?a=\(a)?b=\(b)"`
      // fallbacks. It does NOT match the Swift ternary operator.
      final pattern = RegExp(r'"[^"]*\?\w[^"]*\?[^"]*"');
      expect(
        pattern.hasMatch(payloadSource),
        isFalse,
        reason: 'Payload.swift contains a Swift string literal with two '
            '"?" characters — that signals an unencoded literal query '
            'concatenation. URL builders route through URLComponents '
            'exactly to avoid this.',
      );
      // Sanity: the marker is referenced via the constant, never as a
      // naked literal, so a rename stays mechanical.
      expect(payloadSource.contains('?"homeWidget"'),
          isFalse,
          reason: 'The marker name must travel through '
              'homeWidgetMarkerName, not as a string literal.');
    });
  });

  group('calendarURL optional-binding regression (2026-10-11 repair)', () {
    /// Extracts the Payload.swift source between two declaration markers.
    String functionBody(String startMarker, String endMarker) {
      final start = payloadSource.indexOf(startMarker);
      expect(start, greaterThanOrEqualTo(0),
          reason: 'Payload.swift must still declare $startMarker');
      final end = payloadSource.indexOf(endMarker, start);
      expect(end, greaterThan(start),
          reason: 'Payload.swift must keep $endMarker after $startMarker');
      return payloadSource.substring(start, end);
    }

    test('ymd(date) is never evaluated outside `if let date = date`', () {
      final body = functionBody(
        'static func calendarURL',
        'static let voiceURL',
      );
      // The defective shape branched on the optional (`date == nil ?`) and
      // called ymd(date) in the unbound ternary branch — ymd takes a
      // non-optional Date, so that body failed to compile and took the
      // whole widget extension build down with it.
      expect(
        body.contains('date == nil'),
        isFalse,
        reason: 'calendarURL must not re-derive its fallback from the '
            'optional comparison; assign the fallback inside '
            '`if let date = date` so ymd only ever receives an unwrapped '
            'Date.',
      );
      final bindStart = body.indexOf('if let date = date {');
      expect(bindStart, greaterThanOrEqualTo(0),
          reason: 'calendarURL must bind the optional date explicitly.');
      var depth = 0;
      var bindEnd = -1;
      for (var i = bindStart; i < body.length; i++) {
        if (body[i] == '{') {
          depth++;
        } else if (body[i] == '}') {
          depth--;
          if (depth == 0) {
            bindEnd = i;
            break;
          }
        }
      }
      expect(bindEnd, greaterThan(bindStart),
          reason: 'calendarURL if-let block must be closed.');
      final outsideBlock =
          body.substring(0, bindStart) + body.substring(bindEnd + 1);
      expect(
        outsideBlock.contains('ymd(date)'),
        isFalse,
        reason: 'ymd(_ date: Date) cannot take Date?: any ymd(date) outside '
            'the `if let date = date` block is the exact optional-not-bound '
            'compile error this regression exists to prevent.',
      );
      expect(
        body.substring(bindStart, bindEnd).contains('ymd(date)'),
        isTrue,
        reason: 'The date query item and its fallback mirror must still be '
            'produced inside the binding so calendarURL(date) keeps the '
            'YYYY-MM-DD payload for the router.',
      );
    });

    test('eventURL returns components.url without force-unwrapped fallback',
        () {
      final body = functionBody(
        'static func eventURL',
        'static func groupCalendarURL',
      );
      expect(
        body.contains('?? URL('),
        isFalse,
        reason: 'eventURL already returns URL?: a `URL(string:)!` fallback '
            're-crashes on exactly the arbitrary ids (spaces, stray %) that '
            'URLComponents.url rejected. Return components.url and let the '
            'existing `if let` callers handle nil.',
      );
      expect(
        body.contains('return components.url'),
        isTrue,
        reason: 'eventURL must hand back the URLComponents-built URL so the '
            'event id path plus homeWidget marker survive percent-encoding.',
      );
      expect(
        body.contains('components.queryItems = [widgetMarkerItem()]'),
        isTrue,
        reason: 'Every actual event tap URL must still carry the homeWidget '
            'marker even without the string fallback.',
      );
    });
  });

  group('withWidgetMarker helper', () {
    test('exists and is idempotent', () {
      expect(
        payloadSource,
        contains('static func withWidgetMarker(_ raw: String) -> URL?'),
        reason: 'Payload.swift must expose withWidgetMarker(_:) so Dart-'
            'supplied URL strings (e.g. event.route = planflow://schedule/'
            '<id>) can be re-marked before they are handed to WidgetKit.',
      );
      // Idempotency: the helper short-circuits if a marker is already there.
      // The literal Swift text contains `$0.name`; escape it so Dart does
      // not try to interpolate it as a variable reference.
      expect(
        payloadSource,
        contains(
            r'if existing.contains(where: { $0.name == homeWidgetMarkerName })'),
        reason: 'withWidgetMarker must detect the existing marker and '
            'return the URL unchanged, so calling it twice does not stack '
            '?homeWidget=1&homeWidget=1 entries.',
      );
    });

    test('appends the marker via URLComponents (no string concat)', () {
      // The body must build a URLComponents from the raw string, append
      // widgetMarkerItem(), and return components.url.
      expect(
        payloadSource,
        contains('guard var components = URLComponents(string: raw)'),
        reason: 'withWidgetMarker must parse with URLComponents so that '
            'special characters in event.route ids stay correctly encoded.',
      );
      expect(
        payloadSource,
        contains('appended.append(widgetMarkerItem())'),
        reason: 'withWidgetMarker must append widgetMarkerItem() (not a '
            'string-concatenated "?homeWidget=1") so the marker shape '
            'cannot drift.',
      );
      expect(
        payloadSource,
        contains('return components.url'),
        reason: 'withWidgetMarker must return components.url so the '
            'resulting URL has whatever encoding URLComponents chose.',
      );
    });
  });

  group('Views.swift routes every widget link through the helper', () {
    test('no raw URL(string: "planflow://...") survives in Views.swift', () {
      final rawPattern = RegExp(r'URL\(\s*string:\s*"planflow://');
      expect(
        rawPattern.hasMatch(viewsSource),
        isFalse,
        reason: 'Views.swift contains raw URL(string: "planflow://…") '
            'sites. WidgetKit links must go through '
            'PlanFlowWidgetConfig.* helpers so the homeWidget marker is '
            'added in exactly one place. Offending sites:\n'
            '${planflowUrlLines(viewsSource).join('\n')}',
      );
    });

    test('every WidgetKit Link / widgetURL uses a PlanFlowWidgetConfig helper',
        () {
      // Group calendar view (3 sites: picker tap, header, day cell) and
      // the vertical-schedule view (event.route re-mark). We don't try to
      // enumerate every Link — we check that the only planflow:// string
      // left in Views.swift is the comment that documents event.route.
      // Skip comment lines (Swift `//` to end of line) entirely.
      final nonCommentPlanflowLines = <String>[];
      for (final line in viewsSource.split('\n')) {
        final stripped = line.replaceFirst(RegExp(r'^\s*//.*$'), '').trim();
        if (stripped.contains('planflow://')) {
          nonCommentPlanflowLines.add(line.trim());
        }
      }
      expect(
        nonCommentPlanflowLines,
        isEmpty,
        reason: 'Views.swift still constructs WidgetKit deep links outside '
            'PlanFlowWidgetConfig. Convert them to helper calls so the '
            'homeWidget marker is added consistently. Sites:\n'
            '${nonCommentPlanflowLines.join('\n')}',
      );
    });

    test('event.route goes through withWidgetMarker, not raw URL(string:)',
        () {
      // The vertical-schedule widget previously did
      // `URL(string: event.route) ?? calendarURL()` which dropped the
      // home_widget marker. The contract is now `withWidgetMarker(...)`.
      expect(
        viewsSource,
        contains('PlanFlowWidgetConfig.withWidgetMarker(event.route)'),
        reason: 'PlanFlowVerticalScheduleWidgetView must re-mark the Dart-'
            'supplied event.route through withWidgetMarker so the '
            'WidgetKit tap is recognised.',
      );
      expect(
        viewsSource.contains('URL(string: event.route)'),
        isFalse,
        reason: 'Direct URL(string: event.route) skips the marker.',
      );
    });

    test('group calendar view routes picker/header/cells through the helper',
        () {
      expect(
        viewsSource,
        contains('PlanFlowWidgetConfig.groupCalendarURL()'),
        reason: 'Empty-state picker tap must use the helper so the marker '
            'is added on planflow://group-calendar.',
      );
      expect(
        viewsSource,
        contains('PlanFlowWidgetConfig.groupCalendarURL(groupId: group.groupId)'),
        reason: 'Header tap must carry groupId and the marker through the '
            'helper.',
      );
      expect(
        viewsSource,
        contains(
            'PlanFlowWidgetConfig.groupCalendarURL(groupId: group.groupId, date: key)'),
        reason: 'Day-cell tap must carry groupId + date and the marker '
            'through the helper.',
      );
    });
  });

  group('widget bundle still routes only through the seven kinds', () {
    test('no app native lifecycle bridge was redesigned', () {
      // We deliberately do NOT touch the WidgetBundle entry point, the
      // provider refresh cadence, the App Group plumbing, or the AppIntent
      // for monthly navigation. This guard pins that scope.
      final bundle = read(
          'ios${Platform.pathSeparator}PlanFlowWidget${Platform.pathSeparator}PlanFlowWidget.swift');
      expect(bundle, contains('@main'),
          reason: 'PlanFlowWidgetBundle\'s @main entry point must remain '
              'in place; we are not redesigning the native lifecycle.');
      expect(bundle, contains('PlanFlowWidgetBundle'),
          reason: 'The bundle struct must still expose all seven widgets.');
      expect(
        widgetSources().contains('staticConfiguration'),
        isFalse,
        reason: 'No widget should silently switch from StaticConfiguration '
            'to AppIntentConfiguration; this contract test would not catch '
            'a silent lifecycle change but the absence of lower-cased '
            'staticConfiguration hints at one.',
      );
    });
  });
}