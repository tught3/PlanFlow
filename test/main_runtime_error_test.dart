import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/main.dart' as planflow_main;

void main() {
  test('classifies Postgrest host lookup failures as non-fatal runtime errors',
      () {
    expect(
      planflow_main.isNonFatalRuntimeError(
        const SocketException(
          'Failed host lookup: xqvvfnvmytjlblcngipn.supabase.co',
        ),
      ),
      isTrue,
    );

    expect(
      planflow_main.isNonFatalRuntimeError(
        Exception(
          'PostgrestException(message: SocketException: failed host lookup: '
          'xqvvfnvmytjlblcngipn.supabase.co)',
        ),
      ),
      isTrue,
    );
  });
}
