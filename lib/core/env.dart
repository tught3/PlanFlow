import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppEnv {
  static String get supabaseUrl => dotenv.env['SUPABASE_URL'] ?? '';
  static String get supabaseAnonKey => dotenv.env['SUPABASE_ANON_KEY'] ?? '';
  static String get openAiApiKey => dotenv.env['OPENAI_API_KEY'] ?? '';
  static String get googleAndroidClientId =>
      dotenv.env['GOOGLE_ANDROID_CLIENT_ID'] ?? '';

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty &&
      supabaseAnonKey.isNotEmpty &&
      openAiApiKey.isNotEmpty;
}
