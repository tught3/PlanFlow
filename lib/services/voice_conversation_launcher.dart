import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/analytics_service.dart';
import '../core/constants.dart';
import '../core/env.dart';
import '../data/repositories/settings_repository.dart';
import 'remote_config_service.dart';
import 'voice_conversation_ad_gate.dart';
import 'voice_conversation_entitlement.dart';

/// 'AI일정대화(음성 대화 모드)' 진입 로직을 여러 진입점(홈 화면, 공용 FAB 등)에서
/// 재사용할 수 있도록 모아둔 정적 헬퍼.
///
/// `home_screen.dart`의 `_shouldShowVoiceConvButton` / `_resolveVoiceAutoStartSetting`
/// / `_openVoiceConversation`을 동작 변경 없이 그대로 옮긴 것이다.
class VoiceConversationLauncher {
  VoiceConversationLauncher._();

  /// 테스트 전용 오버라이드. null이 아니면 RemoteConfig 조회 없이 이 값을
  /// [shouldShowButton]의 결과로 그대로 사용한다.
  @visibleForTesting
  static bool? debugShowButtonOverride;

  /// AI일정대화 버튼(홈 헤더/공용 FAB 등)을 표시할지 여부.
  /// RemoteConfig 미초기화 등 예외 상황에서는 안전하게 true(기존 동작 유지)로
  /// 폴백한다.
  static bool shouldShowButton() {
    final override = debugShowButtonOverride;
    if (override != null) {
      return override;
    }
    try {
      return RemoteConfigService.voiceConversationButtonEnabled;
    } catch (_) {
      return true; // RemoteConfig 미초기화 시 기본값 동작
    }
  }

  /// 사용자 설정의 '음성대화 자동 시작' 값을 조회한다. Supabase 미준비,
  /// userId 없음, 조회 실패 등 예외 상황에서는 안전하게 false(자동시작
  /// 안 함, 기존 동작과 동일)로 폴백한다.
  static Future<bool> resolveAutoStart(
    String? userId, {
    SettingsRepository? repository,
  }) async {
    if (!AppEnv.isSupabaseReady) {
      return false;
    }
    final normalizedUserId = userId?.trim() ?? '';
    if (normalizedUserId.isEmpty) {
      return false;
    }
    try {
      final resolvedRepository = repository ?? SettingsRepository.supabase();
      final settings = await resolvedRepository.fetchSettings(
        normalizedUserId,
      );
      return settings?.voiceAutoStart ?? false;
    } catch (error, stackTrace) {
      debugPrint('Voice auto-start setting lookup failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  /// AI일정대화(음성 대화 모드) 진입.
  ///
  /// 순서: 분석 로깅 → userId 확인 → autoStart 설정 선조회(광고 게이트의
  /// `onEnterAllowed` 콜백은 동기 VoidCallback이라 그 안에서 await할 수 없으므로
  /// 광고 게이트 호출 이전에 미리 완료해둔다) → 광고 게이트 → 허용 시 대화모드
  /// 라우트로 push(autoStart 여부에 따라 쿼리 유무가 갈린다).
  static Future<void> open(
    BuildContext context, {
    String? userIdOverride,
    SettingsRepository? repository,
  }) async {
    AnalyticsService.logVoiceConvButtonTap();
    final userId = _resolveUserId(userIdOverride);
    if (userId == null || userId.isEmpty) {
      _showSnack(context, '로그인 세션이 없습니다. 다시 로그인해 주세요.');
      return;
    }
    final shouldAutoStart = await resolveAutoStart(
      userId,
      repository: repository,
    );
    if (!context.mounted) return;
    await VoiceConversationAdGate.instance.tryEnterVoiceConversation(
      context: context,
      userId: userId,
      onEnterAllowed: (VoiceConversationEntryGrant grant) {
        if (!context.mounted) return;
        final route = shouldAutoStart
            ? '${AppRoutes.voiceConversation}?autoStart=1'
            : AppRoutes.voiceConversation;
        unawaited(
          context.push(route, extra: <String, dynamic>{'entry_grant': grant}),
        );
      },
    );
  }

  static String? _resolveUserId(String? userIdOverride) {
    final overrideUserId = userIdOverride?.trim();
    if (overrideUserId != null && overrideUserId.isNotEmpty) {
      return overrideUserId;
    }
    return Supabase.instance.client.auth.currentSession?.user.id;
  }

  static void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
