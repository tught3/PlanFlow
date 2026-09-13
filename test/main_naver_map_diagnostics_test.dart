// The plugin intentionally marks its testable native-error factory internal;
// this contract test needs it to exercise each documented error class.
// ignore_for_file: invalid_use_of_internal_member

import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/main.dart';

void main() {
  test('classifies documented Naver auth failures with safe codes', () {
    expect(
      naverMapAuthFailureDiagnostic(
        NAuthFailedException.fromMessageable(
          <String, String>{'code': '401', 'message': 'secret detail'},
        ),
      ),
      'class=unauthorized_client code=401',
    );
    expect(
      naverMapAuthFailureDiagnostic(
        NAuthFailedException.fromMessageable(
          <String, String>{'code': '429', 'message': 'quota detail'},
        ),
      ),
      'class=quota_exceeded code=429',
    );
    expect(
      naverMapAuthFailureDiagnostic(
        NAuthFailedException.fromMessageable(
          <String, String>{'code': '800', 'message': 'client detail'},
        ),
      ),
      'class=client_unspecified code=800',
    );
  });

  test('redacts unknown or malformed native codes and messages', () {
    final diagnostic = naverMapAuthFailureDiagnostic(
      NAuthFailedException.fromMessageable(
        <String, String>{'code': '401\nsecret', 'message': 'private detail'},
      ),
    );

    expect(diagnostic, 'class=auth_failed code=unknown');
    expect(diagnostic, isNot(contains('secret')));
    expect(diagnostic, isNot(contains('private')));
  });
}
