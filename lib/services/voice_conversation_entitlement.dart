import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import 'remote_config_service.dart';

/// [VoiceConversationEntryGrant]가 진입을 허용한 근거.
///
/// 이 값은 분석 파라미터/UI 분기에만 쓰이는 제한된 열거형이다. 자유텍스트를
/// 절대 담지 않는다.
enum EntitlementSource {
  /// 최초 누적 무료 횟수 소비.
  initialFree,

  /// 일일 무료 횟수 소비.
  dailyFree,

  /// 리워드 광고 시청 완료.
  adRewarded,

  /// 광고가 실패했지만 RemoteConfigService.rewardAdFailurePolicy
  /// = 'free_pass' 정책에 따라 무료 진입이 허용된 경우.
  adFailedFreePass,

  /// 음성 대화 리워드 광고 kill switch가 꺼져 있어 무조건 무료 진입.
  remoteDisabled,

  /// 동의/네트워크 상태상 광고 요청 자체가 불가능해(canRequestAds=false)
  /// 무료 진입이 허용된 경우.
  adsUnavailableFreePass,
}

/// 음성 대화 모드 진입이 승인된 시점의 스냅샷.
///
/// immutable 값객체. [sessionId]는 이 진입 시도 1건을 유일하게 식별하며,
/// 이후 [VoiceConversationEntitlementService.consume]에 그대로 전달되어
/// 서버 측 멱등 처리(같은 세션으로 중복 소비 방지)의 키로 쓰인다.
@immutable
class VoiceConversationEntryGrant {
  const VoiceConversationEntryGrant({
    required this.sessionId,
    required this.source,
    required this.initialRemainingAtGate,
    required this.dailyRemainingAtGate,
  });

  /// 이 진입 시도를 유일하게 식별하는 문자열.
  final String sessionId;

  /// 진입이 승인된 근거.
  final EntitlementSource source;

  /// 게이트 통과 시점에 [VoiceConversationEntitlementService.peek]로 조회한
  /// 최초 무료 잔여 횟수(정보용, consume 이후 실제 값과 다를 수 있음).
  final int initialRemainingAtGate;

  /// 게이트 통과 시점의 일일 무료 잔여 횟수(정보용).
  final int dailyRemainingAtGate;

  @override
  String toString() =>
      'VoiceConversationEntryGrant(sessionId: $sessionId, source: $source, '
      'initialRemainingAtGate: $initialRemainingAtGate, '
      'dailyRemainingAtGate: $dailyRemainingAtGate)';
}

/// [VoiceConversationEntitlementService.peek]의 조회 결과.
///
/// 부작용 없는 읽기 전용 스냅샷이다.
@immutable
class VoiceConversationEntitlementPeek {
  const VoiceConversationEntitlementPeek({
    required this.initialRemaining,
    required this.dailyRemaining,
    required this.requiresAd,
  });

  /// 최초 누적 무료 잔여 횟수.
  final int initialRemaining;

  /// 일일 무료 잔여 횟수.
  final int dailyRemaining;

  /// true면 무료 잔여 횟수가 모두 소진되어 광고가 필요함.
  final bool requiresAd;

  @override
  String toString() =>
      'VoiceConversationEntitlementPeek(initialRemaining: $initialRemaining, '
      'dailyRemaining: $dailyRemaining, requiresAd: $requiresAd)';
}

/// [VoiceConversationEntitlementService.consume]의 소비 결과.
@immutable
class VoiceConversationConsumeResult {
  const VoiceConversationConsumeResult({
    required this.source,
    required this.initialRemaining,
    required this.dailyRemaining,
  });

  /// RPC가 반환한 원본 소비 출처 문자열.
  /// `'initial_free'` / `'daily_free'` / `'ad_required'` 중 하나.
  final String source;

  /// 소비 반영 후 최초 무료 잔여 횟수.
  final int initialRemaining;

  /// 소비 반영 후 일일 무료 잔여 횟수.
  final int dailyRemaining;

  @override
  String toString() =>
      'VoiceConversationConsumeResult(source: $source, '
      'initialRemaining: $initialRemaining, dailyRemaining: $dailyRemaining)';
}

/// 음성 대화 모드의 최초/일일 무료 사용 엔타이틀먼트를 조회·소비하는 서비스.
///
/// 실제 판정(RPC 호출)만 담당하며, 광고 다이얼로그 표시나 화면 전환 같은
/// UI 흐름은 이 서비스를 사용하는 Gate 로직이 책임진다.
///
/// 설계 메모(fail-open):
/// - [peek]/[consume] 모두 실패 시 예외를 던지지 않고 null을 반환한다.
/// - [peek] 실패: 아직 아무 것도 소비되지 않은 조회 단계이므로, null을 받은
///   호출부가 "정보 없음"으로 보수적으로(광고 요구 등) 처리할 수 있게 한다.
/// - [consume] 실패: 이미 Gate에서 진입이 승인된 뒤에 호출되므로, 여기서
///   실패해도 사용자의 음성 명령 처리를 막으면 안 된다. 실패의 유일한
///   부작용은 "잔여 횟수가 정확히 차감되지 않을 수 있음"이며 사용자 경험에는
///   영향이 없다.
class VoiceConversationEntitlementService {
  VoiceConversationEntitlementService._();

  static final VoiceConversationEntitlementService instance =
      VoiceConversationEntitlementService._();

  /// 테스트/QA가 RPC 호출을 우회해 결과를 주입할 수 있도록 하는 백도어.
  /// null이면 실제 Supabase RPC를 호출한다.
  VoiceConversationEntitlementDelegate? _delegateForTest;
  set delegateForTest(VoiceConversationEntitlementDelegate? value) {
    _delegateForTest = value;
  }

  /// 현재 잔여 무료 횟수를 부작용 없이 조회한다.
  ///
  /// Supabase 미준비 상태이거나 RPC 호출이 실패하면 null을 반환한다.
  Future<VoiceConversationEntitlementPeek?> peek() async {
    final delegate = _delegateForTest;
    if (delegate != null) {
      return delegate.peek();
    }
    return _peek();
  }

  /// [sessionId] 1건에 대해 무료 사용을 실제로 소비한다.
  ///
  /// 같은 [sessionId]로 재호출하면 서버 측에서 멱등 처리되어 추가 차감이
  /// 발생하지 않는다(supabase/migrations의 `on conflict ... do nothing` /
  /// `v_row.voice_conversation_last_session_id = p_session_id` 가드 참조).
  ///
  /// Supabase 미준비 상태이거나 RPC 호출이 실패하면 null을 반환한다.
  Future<VoiceConversationConsumeResult?> consume(String sessionId) async {
    final delegate = _delegateForTest;
    if (delegate != null) {
      return delegate.consume(sessionId);
    }
    return _consume(sessionId);
  }

  // ── Data Access (Supabase RPC) ─────────────────────────────────────

  Future<VoiceConversationEntitlementPeek?> _peek() async {
    if (!AppEnv.isSupabaseReady || !AppEnv.hasValidSupabaseConfig) {
      return null;
    }
    try {
      final client = Supabase.instance.client;
      final response = await client.rpc(
        'voice_conversation_entitlement_peek',
        params: <String, dynamic>{
          'p_initial_limit':
              RemoteConfigService.voiceConversationInitialFreeCount,
          // 제품 정책: 최초 3회 이후에는 매일 무료 없이 광고가 필요하다.
          'p_daily_limit': 0,
        },
      );
      final row = _firstRow(response);
      if (row == null) {
        return null;
      }
      return VoiceConversationEntitlementPeek(
        initialRemaining: _readInt(row['initial_remaining']),
        dailyRemaining: _readInt(row['daily_remaining']),
        requiresAd: _readBool(row['requires_ad']),
      );
    } catch (error, stackTrace) {
      debugPrint('VoiceConversationEntitlementService._peek failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  Future<VoiceConversationConsumeResult?> _consume(String sessionId) async {
    if (!AppEnv.isSupabaseReady || !AppEnv.hasValidSupabaseConfig) {
      return null;
    }
    try {
      final client = Supabase.instance.client;
      final response = await client.rpc(
        'consume_voice_conversation_free_usage',
        params: <String, dynamic>{
          'p_session_id': sessionId,
          'p_initial_limit':
              RemoteConfigService.voiceConversationInitialFreeCount,
          'p_daily_limit': 0,
        },
      );
      final row = _firstRow(response);
      if (row == null) {
        return null;
      }
      return VoiceConversationConsumeResult(
        source: row['source']?.toString() ?? '',
        initialRemaining: _readInt(row['initial_remaining']),
        dailyRemaining: _readInt(row['daily_remaining']),
      );
    } catch (error, stackTrace) {
      debugPrint('VoiceConversationEntitlementService._consume failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  /// Supabase RPC(테이블 반환 함수)는 보통 `List<dynamic>`(행 목록)을
  /// 반환하지만, 클라이언트/버전에 따라 단일 `Map`으로 올 수도 있어 둘 다
  /// 방어적으로 처리한다.
  Map<String, dynamic>? _firstRow(dynamic response) {
    if (response is List && response.isNotEmpty) {
      final first = response.first;
      if (first is Map) {
        return Map<String, dynamic>.from(first);
      }
      return null;
    }
    if (response is Map) {
      return Map<String, dynamic>.from(response);
    }
    return null;
  }

  int _readInt(dynamic raw) {
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  bool _readBool(dynamic raw) {
    if (raw is bool) {
      return raw;
    }
    return raw?.toString().toLowerCase() == 'true';
  }
}

/// [VoiceConversationEntitlementService]의 RPC 호출을 테스트/QA가 주입할 수
/// 있도록 하는 인터페이스.
abstract class VoiceConversationEntitlementDelegate {
  Future<VoiceConversationEntitlementPeek?> peek();
  Future<VoiceConversationConsumeResult?> consume(String sessionId);
}

/// [VoiceConversationEntryGrant.sessionId] 생성기.
///
/// 충돌 가능성이 사실상 0인 유니크 문자열을 만든다. 프로젝트에 이미
/// `uuid` 패키지 의존성이 없으므로(pubspec.yaml 확인됨) 새 의존성을 추가하지
/// 않고 시각(마이크로초) + 프로세스 내 단조 증가 카운터 조합으로 생성한다.
class VoiceConversationSessionIdGenerator {
  VoiceConversationSessionIdGenerator._();

  static int _counter = 0;

  static String next() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final counter = _counter++;
    return 'voice_conv_session_${now}_$counter';
  }
}
