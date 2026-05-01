import 'package:flutter/material.dart';

import 'core/router.dart';
import 'core/theme.dart';

class PlanFlowApp extends StatelessWidget {
  const PlanFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'PlanFlow',
      theme: buildPlanFlowTheme(),
      routerConfig: appRouter,
    );
  }
}
