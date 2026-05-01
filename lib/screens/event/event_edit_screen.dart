import 'package:flutter/material.dart';

import '../../core/constants.dart';

class EventEditScreen extends StatelessWidget {
  const EventEditScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Event Edit')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          children: const [
            Text('Event edit placeholder screen.'),
            SizedBox(height: 24),
            TextField(
              decoration: InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: AppConstants.sectionSpacing),
            TextField(
              decoration: InputDecoration(
                labelText: 'Location',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
