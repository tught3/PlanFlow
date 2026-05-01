import 'package:flutter/material.dart';

import 'core/constants.dart';
import 'core/router.dart';
import 'core/theme.dart';

class PlanFlowApp extends StatelessWidget {
  const PlanFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PlanFlow',
      theme: buildPlanFlowTheme(),
      initialRoute: AppRoutes.root,
      onGenerateRoute: AppRouter.onGenerateRoute,
    );
  }
}
