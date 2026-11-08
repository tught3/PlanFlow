// Native entry adapter only. Adds no assertions, fakes or screens; it reuses
// the existing guide editor mount fixture under the integration_test binding.
import 'package:integration_test/integration_test.dart';

import '../test/screens/guide_editor_actual_mount_regression_test.dart' as fixture;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  fixture.main();
}