import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  const TtsService();

  static final FlutterTts _flutterTts = FlutterTts();

  static const String _language = 'ko-KR';
  static const double _speechRate = 0.48;
  static const double _pitch = 1.0;

  Future<void> speak(String text) async {
    final message = text.trim();
    if (message.isEmpty) {
      return;
    }

    await _flutterTts.awaitSpeakCompletion(true);
    await _flutterTts.setLanguage(_language);
    await _flutterTts.setSpeechRate(_speechRate);
    await _flutterTts.setPitch(_pitch);
    await _flutterTts.speak(message);
  }
}
