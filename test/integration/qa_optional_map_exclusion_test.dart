import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../../integration_test/support/native_guide_budget_ledger.dart';

void main() {
  test('optional map exclusion requires every explicit QA fence', () {
    for (var bits = 0; bits < 16; bits++) {
      expect(
          skipOptionalMapForQa(
            debug: bits & 1 != 0,
            guideQa: bits & 2 != 0,
            isolatedQa: bits & 4 != 0,
            skipMap: bits & 8 != 0,
          ),
          bits == 15);
    }
  });

  test('map exclusion validates shape first and never forwards or unlatches',
      () {
    final source =
        File('integration_test/support/real_ui_guide_native_environment.dart')
            .readAsStringSync();
    final validation = source.indexOf('if (mapReason != null) e.deny();');
    final skip = source.indexOf('if (skipOptionalMapForQa(', validation);
    final forwardedCounter = source.indexOf('e.mapProxyCalls += 1;', skip);
    final transport = source.indexOf('e.transport.send(forwarded)', skip);
    expect(validation, greaterThanOrEqualTo(0));
    expect(skip, greaterThan(validation));
    expect(forwardedCounter, greaterThan(skip));
    expect(transport, greaterThan(forwardedCounter));
    final branch = source.substring(skip, forwardedCounter);
    expect(branch, contains("'forwarded': false"));
    expect(branch,
        contains('throw const NativeGuideOptionalBackgroundBlocked();'));
    expect(branch, isNot(contains('e.failed = false')));
    expect(branch, isNot(contains('e.transport')));
    expect(source, contains('on NativeGuideOptionalBackgroundBlocked'));
  });
}
