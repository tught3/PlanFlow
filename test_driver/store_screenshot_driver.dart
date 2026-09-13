import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Host-side receiver for binding.takeScreenshot(). This is the provenance
/// boundary: every PNG is emitted by the running Flutter test, while the
/// simulator device remains the source of the native screen dimensions.
Future<void> main() async {
  final output = Platform.environment['OUTPUT_DIR'];
  if (output == null || output.isEmpty) {
    throw StateError('OUTPUT_DIR is required for screenshot capture');
  }
  await integrationDriver(
    onScreenshot: (name, bytes, [args]) async {
      final path = File('$output/$name.png');
      await path.parent.create(recursive: true);
      await path.writeAsBytes(bytes, flush: true);
      return true;
    },
  );
}
