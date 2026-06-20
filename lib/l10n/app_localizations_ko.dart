// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Korean (`ko`).
class AppLocalizationsKo extends AppLocalizations {
  AppLocalizationsKo([String locale = 'ko']) : super(locale);

  @override
  String get appName => 'PlanFlow';

  @override
  String get homeTab => '홈';

  @override
  String get calendarTab => '일정';

  @override
  String get settingsTab => '설정';

  @override
  String get loginTitle => '로그인';

  @override
  String get signUpTitle => '회원가입';

  @override
  String get passwordResetTitle => '비밀번호 찾기';

  @override
  String get loginSubtitle => '이메일과 비밀번호로 먼저 로그인하거나, 아래 소셜 계정으로 바로 시작하세요.';

  @override
  String get signUpSubtitle => '계정을 만들면 일정 데이터가 사용자별로 안전하게 저장됩니다.';

  @override
  String get passwordResetSubtitle => '가입한 이메일로 비밀번호 재설정 링크를 보내드립니다.';

  @override
  String get emailLogin => '이메일 로그인';

  @override
  String get simpleLogin => '간편 로그인';

  @override
  String get email => '이메일';

  @override
  String get password => '비밀번호';

  @override
  String get confirmPassword => '비밀번호 확인';

  @override
  String get name => '이름';

  @override
  String get loginWithEmail => '이메일로 로그인';

  @override
  String get signUpWithEmail => '이메일로 회원가입';

  @override
  String get sendPasswordReset => '비밀번호 재설정 메일 보내기';

  @override
  String get forgotPassword => '비밀번호를 잊으셨나요?';

  @override
  String get backToLogin => '로그인으로 돌아가기';

  @override
  String get googleContinue => 'Google로 계속하기';

  @override
  String get kakaoContinue => '카카오로 계속하기';

  @override
  String get naverContinue => '네이버로 계속하기';

  @override
  String get supabaseLoginMissing => 'Supabase 빌드 설정값을 먼저 주입해야 로그인할 수 있습니다.';

  @override
  String get supabaseSocialMissing =>
      'Supabase 빌드 설정값을 주입해야 소셜 로그인을 사용할 수 있습니다.';

  @override
  String get invalidEmail => '올바른 이메일을 입력해 주세요.';

  @override
  String get shortPassword => '비밀번호는 최소 6자 이상이어야 합니다.';

  @override
  String get passwordMismatch => '비밀번호 확인이 일치하지 않습니다.';

  @override
  String get loginSessionFailed => '로그인 세션을 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.';

  @override
  String get signUpEmailSent =>
      '인증 메일을 보냈습니다. 이미 가입된 이메일이라면 새 메일이 오지 않을 수 있어요. 기존 계정으로 로그인하거나 비밀번호 찾기를 이용해 주세요.';

  @override
  String get signUpSessionFailed => '회원가입 세션을 확인하지 못했습니다. 로그인으로 다시 시도해 주세요.';

  @override
  String get passwordResetSent => '비밀번호 재설정 메일을 보냈습니다. 메일함을 확인해 주세요.';

  @override
  String get oauthLaunchFailed => '로그인 창을 열지 못했습니다. 브라우저 설정을 확인해 주세요.';

  @override
  String get authInvalidCredentials => '이메일 또는 비밀번호가 올바르지 않습니다.';

  @override
  String get authEmailNotConfirmed => '이메일 인증이 아직 완료되지 않았습니다. 메일함을 확인해 주세요.';

  @override
  String get authAlreadyRegistered => '이미 가입된 이메일입니다. 로그인으로 진행해 주세요.';

  @override
  String get authGenericError => '인증 처리 중 문제가 발생했습니다. 설정과 입력값을 확인해 주세요.';

  @override
  String get voiceInputTitle => '음성 입력';

  @override
  String get voiceInputIntro => '말하거나 직접 입력한 뒤 바로 확인하세요.';

  @override
  String get voiceGuideTitle => '이렇게 말해보세요';

  @override
  String get voiceGuideFooter => '시간,장소,반복 표현을 같이 할수록 정확해지고 편하게 AI와 대화도가능합니다';

  @override
  String get voiceListenIdle => '아래 버튼을 눌러 음성으로 말하거나, 직접 입력해 주세요.';

  @override
  String get voiceListenActive => '온디바이스 음성으로 듣는 중입니다. 완료를 누를 때까지 계속 말할 수 있어요.';

  @override
  String voiceListenRestarted(int count) {
    return '음성 인식이 $count번 이어졌어요. 이전 말은 유지됩니다.';
  }

  @override
  String get voiceTranscriptTitle => '음성 원문 / 직접 입력';

  @override
  String get voiceInputHint => '입력해주세요';

  @override
  String get voiceListeningContinue => '계속 듣는 중입니다.';

  @override
  String get voiceCheckRecognized => '인식된 내용을 확인해 주세요.';

  @override
  String get voicePrimaryStart => '음성으로 일정 입력하기';

  @override
  String get voiceDone => '완료';

  @override
  String get voiceClearAll => '전체 지우기';

  @override
  String get voiceClearAllCompact => '전체삭제';

  @override
  String get voiceDeleteLast => '마지막 단어 삭제';

  @override
  String get voiceDeleteLastCompact => '마지막삭제';

  @override
  String get voiceManualInput => '직접 입력';

  @override
  String get voiceManualInputCompact => '직접입력';

  @override
  String get voiceCancelTooltip => '음성 입력 취소';

  @override
  String get voiceAutoRestarted => '음성 인식이 자동으로 이어졌어요. 완료를 누를 때까지 계속 말해 주세요.';

  @override
  String get voiceNoResult => '음성 인식 결과를 확인하지 못했어요. 직접 입력으로 이어가 주세요.';

  @override
  String get voiceFailed => '음성 인식을 처리하지 못했어요. 직접 입력으로 이어가 주세요.';

  @override
  String get voiceCancelled => '음성 입력을 취소했어요. 다시 시작할 수 있습니다.';

  @override
  String get voiceClearedEmpty => '입력 내용이 비었어요.';

  @override
  String get voiceDeletedLast => '마지막 단어를 지웠어요.';

  @override
  String get voiceClearedAll => '전체 입력을 지웠어요.';

  @override
  String get settingsTitle => '설정';

  @override
  String get resetDefaultsTooltip => '기본값으로 되돌리기';

  @override
  String get regionSettingsTitle => '국가/시간';

  @override
  String get regionSettingsSubtitle => '일정 시간대와 앱 언어 기준을 정합니다.';

  @override
  String get countryLabel => '국가';

  @override
  String get calendarSyncTitle => '캘린더 연동';

  @override
  String get backupRestoreTitle => '백업 및 복원';

  @override
  String get korea => '대한민국';

  @override
  String get unitedStates => '미국';

  @override
  String get japan => '일본';

  @override
  String get unitedKingdom => '영국';

  @override
  String get germany => '독일';

  @override
  String get france => '프랑스';

  @override
  String get australia => '호주';

  @override
  String get eventCreateTitle => '일정 만들기';

  @override
  String get eventEditTitle => '일정 편집';

  @override
  String get save => '저장';

  @override
  String get saving => '저장 중...';

  @override
  String get cancel => '취소';

  @override
  String get apply => '적용';

  @override
  String get titleField => '제목';

  @override
  String get locationField => '장소';

  @override
  String get memoField => '메모';

  @override
  String get suppliesField => '준비물';

  @override
  String get dateTimePickerTitle => '날짜와 시간 선택';

  @override
  String get hourLabel => '시';

  @override
  String get minuteLabel => '분';
}
