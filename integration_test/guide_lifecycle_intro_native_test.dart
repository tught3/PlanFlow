// Native-only test binding: render assertions after injected hidden states.
// Observers and lifecycleState remain real; app suspend assertions still apply.
import 'package:integration_test/integration_test.dart';

import '../test/screens/guide_editor_actual_mount_regression_test.dart'
    as editor;
import '../test/screens/legacy_intro_screen_test.dart' as intro;
import '../test/onboarding/real_ui_guide_lifecycle_pause_test.dart'
    as lifecycle;
import '../test/onboarding/voice_correction_example_test.dart' as correction;
import '../test/widgets/real_ui_guide_viewport_test.dart' as viewport;
import '../test/screens/real_ui_guide_parse_quota_test.dart' as quota;

class _NativeLifecycleRegressionBinding
    extends IntegrationTestWidgetsFlutterBinding {
  // Scheduler otherwise drops LiveBinding.pump frames for hidden/paused/detached.
  @override
  bool get framesEnabled => true;
}

void main() {
  _NativeLifecycleRegressionBinding();
  editor.main();
  intro.main();
  lifecycle.main();
  correction.main();
  viewport.main();
  quota.main();
}
