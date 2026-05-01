import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';

class VoiceInputScreen extends StatelessWidget {
  const VoiceInputScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Voice Input')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Voice input placeholder screen.'),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => context.go(AppRoutes.confirm),
                icon: const Icon(Icons.check),
                label: const Text('Go to confirm'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
