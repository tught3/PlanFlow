import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../data/models/app_feature.dart';
import '../data/repositories/app_repository.dart';
import '../services/app_service.dart';
import '../providers/app_provider.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = AppProvider(const AppService(InMemoryAppRepository()))
      ..bootstrap();
    final features = provider.features;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(AppConstants.defaultPadding),
        children: [
          Text(
            AppConstants.appName,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'The initial scaffold is ready. We can connect real workflow logic next.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          ...features.map((feature) => _FeatureCard(feature: feature)),
        ],
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.feature});

  final AppFeature feature;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text(feature.title),
        subtitle: Text(feature.description),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).pushNamed(feature.route),
      ),
    );
  }
}
