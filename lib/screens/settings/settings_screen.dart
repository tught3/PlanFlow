import 'package:flutter/material.dart';

import '../../core/constants.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(AppConstants.defaultPadding),
          child: Text('Settings placeholder screen.'),
        ),
      ),
    );
  }
}
