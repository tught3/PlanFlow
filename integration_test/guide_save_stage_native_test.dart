// Native entry adapter only. Adds no assertions, fakes or screens; it reuses
// the actual guide save-stage host+editor fixture under the integration_test
// binding so the same real host/editor sequence can be exercised on a device.
import 'package:integration_test/integration_test.dart';

import '../test/screens/guide_save_stage_actual_mount_test.dart' as fixture;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  fixture.main();
}
