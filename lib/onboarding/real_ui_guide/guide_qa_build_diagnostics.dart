import 'package:flutter/foundation.dart';

/// Records only the two compile-time QA flags. Call once on guide host startup.
/// This diagnostic is omitted from release and non-isolated builds.
void logGuideQaBuildDefines() {
  if (kDebugMode &&
      const bool.fromEnvironment('PLANFLOW_ISOLATED_GUIDE_QA')) {
    const guideQa = bool.fromEnvironment('PLANFLOW_GUIDE_QA');
    const isolated = bool.fromEnvironment('PLANFLOW_ISOLATED_GUIDE_QA');
    debugPrint('PLANFLOW_GUIDE_QA_BUILD_DEFINES '
        'PLANFLOW_GUIDE_QA=$guideQa PLANFLOW_ISOLATED_GUIDE_QA=$isolated');
  }
}
