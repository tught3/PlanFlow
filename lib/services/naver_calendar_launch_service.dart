import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

class NaverCalendarLaunchService {
  const NaverCalendarLaunchService();

  static const String naverCalendarPackage = 'com.nhn.android.calendar';

  Future<NaverCalendarLaunchResult> openNaverCalendar() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        const intent = AndroidIntent(
          action: 'android.intent.action.MAIN',
          package: naverCalendarPackage,
          flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
        );
        await intent.launch();
        return const NaverCalendarLaunchResult.opened();
      } catch (error, stackTrace) {
        debugPrint('Naver Calendar app launch failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        return _openInstallFallback();
      }
    }

    final opened = await launchUrl(
      Uri.parse('https://calendar.naver.com'),
      mode: LaunchMode.externalApplication,
    );
    if (opened) {
      return const NaverCalendarLaunchResult(
        success: true,
        message: '네이버 캘린더 웹을 열었습니다.',
      );
    }
    return const NaverCalendarLaunchResult(
      success: false,
      message: '네이버 캘린더를 열지 못했습니다.',
    );
  }

  Future<NaverCalendarLaunchResult> _openInstallFallback() async {
    final marketUri = Uri.parse('market://details?id=$naverCalendarPackage');
    final marketOpened = await launchUrl(
      marketUri,
      mode: LaunchMode.externalApplication,
    );
    if (marketOpened) {
      return const NaverCalendarLaunchResult(
        success: false,
        message: '네이버 캘린더 앱이 없어 Play 스토어를 열었습니다.',
      );
    }

    final webOpened = await launchUrl(
      Uri.parse(
        'https://play.google.com/store/apps/details?id=$naverCalendarPackage',
      ),
      mode: LaunchMode.externalApplication,
    );
    return NaverCalendarLaunchResult(
      success: false,
      message: webOpened
          ? '네이버 캘린더 앱 설치 페이지를 열었습니다.'
          : '네이버 캘린더 앱을 열지 못했습니다. 설치 여부를 확인해 주세요.',
    );
  }
}

class NaverCalendarLaunchResult {
  const NaverCalendarLaunchResult({
    required this.success,
    required this.message,
  });

  const NaverCalendarLaunchResult.opened()
      : success = true,
        message = '네이버 캘린더 앱을 열었습니다. 내보내기에서 공유 대상을 PlanFlow로 선택해 주세요.';

  final bool success;
  final String message;
}
