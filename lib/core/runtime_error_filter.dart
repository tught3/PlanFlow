import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// 네트워크 단절(오프라인) 계열 예외인지 판별한다.
///
/// Supabase/Postgrest는 호스트 조회 실패 시 SocketException 또는 http
/// ClientException을 던지는데, 이는 앱 버그가 아니라 단말 네트워크 상태 문제다.
bool isNetworkRuntimeError(Object? error) {
  if (error is SocketException || error is TimeoutException) {
    return true;
  }
  final text = error.toString();
  return text.contains('SocketException') ||
      text.contains('Failed host lookup') ||
      text.contains('ClientException') ||
      text.contains('Connection closed') ||
      text.contains('Connection reset') ||
      text.contains('Network is unreachable');
}

/// 앱 시작 직후/백그라운드 전환/엔진 detach 시 플랫폼 채널이 일시적으로 끊겨
/// 발생하는 channel-error / MissingPluginException 계열인지 판별한다.
bool isTransientChannelRuntimeError(Object? error) {
  if (error is MissingPluginException) {
    return true;
  }
  final text = error.toString();
  return text.contains('channel-error') ||
      text.contains('Unable to establish connection on channel');
}

bool shouldDropFromCrashlytics(Object? error) => isNetworkRuntimeError(error);

bool shouldReportNonFatalToCrashlytics(Object? error) =>
    isTransientChannelRuntimeError(error);
