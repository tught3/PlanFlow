import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:planflow/core/runtime_error_filter.dart';

void main() {
  group('runtime Crashlytics filtering', () {
    test('drops Supabase/Postgrest network failures from Crashlytics', () {
      expect(
          shouldDropFromCrashlytics(const SocketException('offline')), isTrue);
      expect(
        shouldDropFromCrashlytics(
          http.ClientException(
            'with SocketException: Failed host lookup: '
            "'xqvvfnvmytjlblcngipn.supabase.co'",
          ),
        ),
        isTrue,
      );
      expect(
          shouldDropFromCrashlytics(TimeoutException('slow network')), isTrue);
    });

    test('keeps transient channel failures as non-fatal reports', () {
      expect(shouldDropFromCrashlytics(MissingPluginException()), isFalse);
      expect(
        shouldReportNonFatalToCrashlytics(MissingPluginException()),
        isTrue,
      );
      expect(
        shouldReportNonFatalToCrashlytics(Exception('channel-error')),
        isTrue,
      );
    });

    test('keeps real programming errors reportable as fatal', () {
      final error = StateError('real bug');

      expect(shouldDropFromCrashlytics(error), isFalse);
      expect(shouldReportNonFatalToCrashlytics(error), isFalse);
    });
  });
}
