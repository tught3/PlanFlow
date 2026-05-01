import 'package:flutter/material.dart';

import '../../core/constants.dart';

class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Calendar')),
      body: const SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(AppConstants.defaultPadding),
            child: Text('Calendar placeholder screen.'),
          ),
        ),
      ),
    );
  }
}
