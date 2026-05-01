import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/env.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // Keep booting when the local env file is absent in scaffolded setups.
  }
  if (AppEnv.supabaseUrl.isNotEmpty && AppEnv.supabaseAnonKey.isNotEmpty) {
    try {
      await Supabase.initialize(
        url: AppEnv.supabaseUrl,
        anonKey: AppEnv.supabaseAnonKey,
      ).timeout(const Duration(seconds: 10));
      AppEnv.markSupabaseInitialized();
    } catch (error) {
      debugPrint('Supabase initialization skipped: $error');
    }
  }
  runApp(const ProviderScope(child: PlanFlowApp()));
}
