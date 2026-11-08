// Native adapter for ONLY the real ConfirmScreen save-stage regression.
//
// It imports the focused registration function instead of the whole
// ConfirmScreen widget suite, so unrelated test setup and fake channels are
// not started on the device.
import 'package:integration_test/integration_test.dart';

import '../test/screens/confirm_screen_test.dart' as confirm_suite;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  confirm_suite.registerConfirmScreenGuideSaveStageTests();
}
