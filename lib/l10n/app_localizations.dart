import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ko.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ko')
  ];

  /// No description provided for @appName.
  ///
  /// In ko, this message translates to:
  /// **'PlanFlow'**
  String get appName;

  /// No description provided for @homeTab.
  ///
  /// In ko, this message translates to:
  /// **'홈'**
  String get homeTab;

  /// No description provided for @calendarTab.
  ///
  /// In ko, this message translates to:
  /// **'일정'**
  String get calendarTab;

  /// No description provided for @settingsTab.
  ///
  /// In ko, this message translates to:
  /// **'설정'**
  String get settingsTab;

  /// No description provided for @loginTitle.
  ///
  /// In ko, this message translates to:
  /// **'로그인'**
  String get loginTitle;

  /// No description provided for @signUpTitle.
  ///
  /// In ko, this message translates to:
  /// **'회원가입'**
  String get signUpTitle;

  /// No description provided for @passwordResetTitle.
  ///
  /// In ko, this message translates to:
  /// **'비밀번호 찾기'**
  String get passwordResetTitle;

  /// No description provided for @loginSubtitle.
  ///
  /// In ko, this message translates to:
  /// **'이메일과 비밀번호로 먼저 로그인하거나, 아래 소셜 계정으로 바로 시작하세요.'**
  String get loginSubtitle;

  /// No description provided for @signUpSubtitle.
  ///
  /// In ko, this message translates to:
  /// **'계정을 만들면 일정 데이터가 사용자별로 안전하게 저장됩니다.'**
  String get signUpSubtitle;

  /// No description provided for @passwordResetSubtitle.
  ///
  /// In ko, this message translates to:
  /// **'가입한 이메일로 비밀번호 재설정 링크를 보내드립니다.'**
  String get passwordResetSubtitle;

  /// No description provided for @emailLogin.
  ///
  /// In ko, this message translates to:
  /// **'이메일 로그인'**
  String get emailLogin;

  /// No description provided for @simpleLogin.
  ///
  /// In ko, this message translates to:
  /// **'간편 로그인'**
  String get simpleLogin;

  /// No description provided for @email.
  ///
  /// In ko, this message translates to:
  /// **'이메일'**
  String get email;

  /// No description provided for @password.
  ///
  /// In ko, this message translates to:
  /// **'비밀번호'**
  String get password;

  /// No description provided for @confirmPassword.
  ///
  /// In ko, this message translates to:
  /// **'비밀번호 확인'**
  String get confirmPassword;

  /// No description provided for @name.
  ///
  /// In ko, this message translates to:
  /// **'이름'**
  String get name;

  /// No description provided for @loginWithEmail.
  ///
  /// In ko, this message translates to:
  /// **'이메일로 로그인'**
  String get loginWithEmail;

  /// No description provided for @signUpWithEmail.
  ///
  /// In ko, this message translates to:
  /// **'이메일로 회원가입'**
  String get signUpWithEmail;

  /// No description provided for @sendPasswordReset.
  ///
  /// In ko, this message translates to:
  /// **'비밀번호 재설정 메일 보내기'**
  String get sendPasswordReset;

  /// No description provided for @forgotPassword.
  ///
  /// In ko, this message translates to:
  /// **'비밀번호를 잊으셨나요?'**
  String get forgotPassword;

  /// No description provided for @backToLogin.
  ///
  /// In ko, this message translates to:
  /// **'로그인으로 돌아가기'**
  String get backToLogin;

  /// No description provided for @googleContinue.
  ///
  /// In ko, this message translates to:
  /// **'Google로 계속하기'**
  String get googleContinue;

  /// No description provided for @kakaoContinue.
  ///
  /// In ko, this message translates to:
  /// **'카카오로 계속하기'**
  String get kakaoContinue;

  /// No description provided for @naverContinue.
  ///
  /// In ko, this message translates to:
  /// **'네이버로 계속하기'**
  String get naverContinue;

  /// No description provided for @appleContinue.
  ///
  /// In ko, this message translates to:
  /// **'Apple로 계속하기'**
  String get appleContinue;

  /// No description provided for @supabaseLoginMissing.
  ///
  /// In ko, this message translates to:
  /// **'Supabase 빌드 설정값을 먼저 주입해야 로그인할 수 있습니다.'**
  String get supabaseLoginMissing;

  /// No description provided for @supabaseSocialMissing.
  ///
  /// In ko, this message translates to:
  /// **'Supabase 빌드 설정값을 주입해야 소셜 로그인을 사용할 수 있습니다.'**
  String get supabaseSocialMissing;

  /// No description provided for @invalidEmail.
  ///
  /// In ko, this message translates to:
  /// **'올바른 이메일을 입력해 주세요.'**
  String get invalidEmail;

  /// No description provided for @shortPassword.
  ///
  /// In ko, this message translates to:
  /// **'비밀번호는 최소 6자 이상이어야 합니다.'**
  String get shortPassword;

  /// No description provided for @passwordMismatch.
  ///
  /// In ko, this message translates to:
  /// **'비밀번호 확인이 일치하지 않습니다.'**
  String get passwordMismatch;

  /// No description provided for @loginSessionFailed.
  ///
  /// In ko, this message translates to:
  /// **'로그인 세션을 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.'**
  String get loginSessionFailed;

  /// No description provided for @signUpEmailSent.
  ///
  /// In ko, this message translates to:
  /// **'인증 메일을 보냈습니다. 이미 가입된 이메일이라면 새 메일이 오지 않을 수 있어요. 기존 계정으로 로그인하거나 비밀번호 찾기를 이용해 주세요.'**
  String get signUpEmailSent;

  /// No description provided for @signUpSessionFailed.
  ///
  /// In ko, this message translates to:
  /// **'회원가입 세션을 확인하지 못했습니다. 로그인으로 다시 시도해 주세요.'**
  String get signUpSessionFailed;

  /// No description provided for @passwordResetSent.
  ///
  /// In ko, this message translates to:
  /// **'비밀번호 재설정 메일을 보냈습니다. 메일함을 확인해 주세요.'**
  String get passwordResetSent;

  /// No description provided for @oauthLaunchFailed.
  ///
  /// In ko, this message translates to:
  /// **'로그인 창을 열지 못했습니다. 브라우저 설정을 확인해 주세요.'**
  String get oauthLaunchFailed;

  /// No description provided for @authInvalidCredentials.
  ///
  /// In ko, this message translates to:
  /// **'이메일 또는 비밀번호가 올바르지 않습니다.'**
  String get authInvalidCredentials;

  /// No description provided for @authEmailNotConfirmed.
  ///
  /// In ko, this message translates to:
  /// **'이메일 인증이 아직 완료되지 않았습니다. 메일함을 확인해 주세요.'**
  String get authEmailNotConfirmed;

  /// No description provided for @authAlreadyRegistered.
  ///
  /// In ko, this message translates to:
  /// **'이미 가입된 이메일입니다. 로그인으로 진행해 주세요.'**
  String get authAlreadyRegistered;

  /// No description provided for @authGenericError.
  ///
  /// In ko, this message translates to:
  /// **'인증 처리 중 문제가 발생했습니다. 설정과 입력값을 확인해 주세요.'**
  String get authGenericError;

  /// No description provided for @voiceInputTitle.
  ///
  /// In ko, this message translates to:
  /// **'음성 입력'**
  String get voiceInputTitle;

  /// No description provided for @voiceInputIntro.
  ///
  /// In ko, this message translates to:
  /// **'말하거나 직접 입력한 뒤 바로 확인하세요.'**
  String get voiceInputIntro;

  /// No description provided for @voiceGuideTitle.
  ///
  /// In ko, this message translates to:
  /// **'이렇게 말해보세요'**
  String get voiceGuideTitle;

  /// No description provided for @voiceGuideFooter.
  ///
  /// In ko, this message translates to:
  /// **'시간, 장소, 반복 표현을 같이 말하면 더 정확해요.'**
  String get voiceGuideFooter;

  /// No description provided for @voiceListenIdle.
  ///
  /// In ko, this message translates to:
  /// **'아래 버튼을 눌러 음성으로 말하거나, 직접 입력해 주세요.'**
  String get voiceListenIdle;

  /// No description provided for @voiceListenActive.
  ///
  /// In ko, this message translates to:
  /// **'온디바이스 음성으로 듣는 중입니다. 완료를 누를 때까지 계속 말할 수 있어요.'**
  String get voiceListenActive;

  /// No description provided for @voiceListenRestarted.
  ///
  /// In ko, this message translates to:
  /// **'음성 인식이 {count}번 이어졌어요. 이전 말은 유지됩니다.'**
  String voiceListenRestarted(int count);

  /// No description provided for @voiceTranscriptTitle.
  ///
  /// In ko, this message translates to:
  /// **'음성 원문 / 직접 입력'**
  String get voiceTranscriptTitle;

  /// No description provided for @voiceInputHint.
  ///
  /// In ko, this message translates to:
  /// **'입력해주세요'**
  String get voiceInputHint;

  /// No description provided for @voiceListeningContinue.
  ///
  /// In ko, this message translates to:
  /// **'계속 듣는 중입니다.'**
  String get voiceListeningContinue;

  /// No description provided for @voiceCheckRecognized.
  ///
  /// In ko, this message translates to:
  /// **'인식된 내용을 확인해 주세요.'**
  String get voiceCheckRecognized;

  /// No description provided for @voicePrimaryStart.
  ///
  /// In ko, this message translates to:
  /// **'음성으로 일정 입력하기'**
  String get voicePrimaryStart;

  /// No description provided for @voiceDone.
  ///
  /// In ko, this message translates to:
  /// **'완료'**
  String get voiceDone;

  /// No description provided for @voiceClearAll.
  ///
  /// In ko, this message translates to:
  /// **'전체 지우기'**
  String get voiceClearAll;

  /// No description provided for @voiceClearAllCompact.
  ///
  /// In ko, this message translates to:
  /// **'전체삭제'**
  String get voiceClearAllCompact;

  /// No description provided for @voiceDeleteLast.
  ///
  /// In ko, this message translates to:
  /// **'마지막 단어 삭제'**
  String get voiceDeleteLast;

  /// No description provided for @voiceDeleteLastCompact.
  ///
  /// In ko, this message translates to:
  /// **'마지막삭제'**
  String get voiceDeleteLastCompact;

  /// No description provided for @voiceManualInput.
  ///
  /// In ko, this message translates to:
  /// **'직접 입력'**
  String get voiceManualInput;

  /// No description provided for @voiceManualInputCompact.
  ///
  /// In ko, this message translates to:
  /// **'직접입력'**
  String get voiceManualInputCompact;

  /// No description provided for @voiceCancelTooltip.
  ///
  /// In ko, this message translates to:
  /// **'음성 입력 취소'**
  String get voiceCancelTooltip;

  /// No description provided for @voiceAutoRestarted.
  ///
  /// In ko, this message translates to:
  /// **'음성 인식이 자동으로 이어졌어요. 완료를 누를 때까지 계속 말해 주세요.'**
  String get voiceAutoRestarted;

  /// No description provided for @voiceNoResult.
  ///
  /// In ko, this message translates to:
  /// **'음성 인식 결과를 확인하지 못했어요. 직접 입력으로 이어가 주세요.'**
  String get voiceNoResult;

  /// No description provided for @voiceFailed.
  ///
  /// In ko, this message translates to:
  /// **'음성 인식을 처리하지 못했어요. 직접 입력으로 이어가 주세요.'**
  String get voiceFailed;

  /// No description provided for @voiceCancelled.
  ///
  /// In ko, this message translates to:
  /// **'음성 입력을 취소했어요. 다시 시작할 수 있습니다.'**
  String get voiceCancelled;

  /// No description provided for @voiceClearedEmpty.
  ///
  /// In ko, this message translates to:
  /// **'입력 내용이 비었어요.'**
  String get voiceClearedEmpty;

  /// No description provided for @voiceDeletedLast.
  ///
  /// In ko, this message translates to:
  /// **'마지막 단어를 지웠어요.'**
  String get voiceDeletedLast;

  /// No description provided for @voiceClearedAll.
  ///
  /// In ko, this message translates to:
  /// **'전체 입력을 지웠어요.'**
  String get voiceClearedAll;

  /// No description provided for @settingsTitle.
  ///
  /// In ko, this message translates to:
  /// **'설정'**
  String get settingsTitle;

  /// No description provided for @resetDefaultsTooltip.
  ///
  /// In ko, this message translates to:
  /// **'기본값으로 되돌리기'**
  String get resetDefaultsTooltip;

  /// No description provided for @regionSettingsTitle.
  ///
  /// In ko, this message translates to:
  /// **'국가/시간'**
  String get regionSettingsTitle;

  /// No description provided for @regionSettingsSubtitle.
  ///
  /// In ko, this message translates to:
  /// **'일정 시간대와 앱 언어 기준을 정합니다.'**
  String get regionSettingsSubtitle;

  /// No description provided for @countryLabel.
  ///
  /// In ko, this message translates to:
  /// **'국가'**
  String get countryLabel;

  /// No description provided for @calendarSyncTitle.
  ///
  /// In ko, this message translates to:
  /// **'캘린더 연동'**
  String get calendarSyncTitle;

  /// No description provided for @backupRestoreTitle.
  ///
  /// In ko, this message translates to:
  /// **'백업 및 복원'**
  String get backupRestoreTitle;

  /// No description provided for @korea.
  ///
  /// In ko, this message translates to:
  /// **'대한민국'**
  String get korea;

  /// No description provided for @unitedStates.
  ///
  /// In ko, this message translates to:
  /// **'미국'**
  String get unitedStates;

  /// No description provided for @japan.
  ///
  /// In ko, this message translates to:
  /// **'일본'**
  String get japan;

  /// No description provided for @unitedKingdom.
  ///
  /// In ko, this message translates to:
  /// **'영국'**
  String get unitedKingdom;

  /// No description provided for @germany.
  ///
  /// In ko, this message translates to:
  /// **'독일'**
  String get germany;

  /// No description provided for @france.
  ///
  /// In ko, this message translates to:
  /// **'프랑스'**
  String get france;

  /// No description provided for @australia.
  ///
  /// In ko, this message translates to:
  /// **'호주'**
  String get australia;

  /// No description provided for @eventCreateTitle.
  ///
  /// In ko, this message translates to:
  /// **'일정 만들기'**
  String get eventCreateTitle;

  /// No description provided for @eventEditTitle.
  ///
  /// In ko, this message translates to:
  /// **'일정 편집'**
  String get eventEditTitle;

  /// No description provided for @save.
  ///
  /// In ko, this message translates to:
  /// **'저장'**
  String get save;

  /// No description provided for @saving.
  ///
  /// In ko, this message translates to:
  /// **'저장 중...'**
  String get saving;

  /// No description provided for @cancel.
  ///
  /// In ko, this message translates to:
  /// **'취소'**
  String get cancel;

  /// No description provided for @apply.
  ///
  /// In ko, this message translates to:
  /// **'적용'**
  String get apply;

  /// No description provided for @titleField.
  ///
  /// In ko, this message translates to:
  /// **'제목'**
  String get titleField;

  /// No description provided for @locationField.
  ///
  /// In ko, this message translates to:
  /// **'장소'**
  String get locationField;

  /// No description provided for @memoField.
  ///
  /// In ko, this message translates to:
  /// **'메모'**
  String get memoField;

  /// No description provided for @suppliesField.
  ///
  /// In ko, this message translates to:
  /// **'준비물'**
  String get suppliesField;

  /// No description provided for @dateTimePickerTitle.
  ///
  /// In ko, this message translates to:
  /// **'날짜와 시간 선택'**
  String get dateTimePickerTitle;

  /// No description provided for @hourLabel.
  ///
  /// In ko, this message translates to:
  /// **'시'**
  String get hourLabel;

  /// No description provided for @minuteLabel.
  ///
  /// In ko, this message translates to:
  /// **'분'**
  String get minuteLabel;

  /// No description provided for @groupEventReportSheetTitle.
  ///
  /// In ko, this message translates to:
  /// **'일정 신고'**
  String get groupEventReportSheetTitle;

  /// No description provided for @groupEventReportSheetSubtitle.
  ///
  /// In ko, this message translates to:
  /// **'공유된 일정에 문제가 있으면 운영자에게 신고해 주세요.'**
  String get groupEventReportSheetSubtitle;

  /// No description provided for @reportReasonInappropriate.
  ///
  /// In ko, this message translates to:
  /// **'부적절한 콘텐츠'**
  String get reportReasonInappropriate;

  /// No description provided for @reportReasonSpam.
  ///
  /// In ko, this message translates to:
  /// **'스팸/광고'**
  String get reportReasonSpam;

  /// No description provided for @reportReasonHarassment.
  ///
  /// In ko, this message translates to:
  /// **'괴롭힘 또는 피해 유발'**
  String get reportReasonHarassment;

  /// No description provided for @reportReasonOther.
  ///
  /// In ko, this message translates to:
  /// **'기타'**
  String get reportReasonOther;

  /// No description provided for @groupEventReportDetailLabel.
  ///
  /// In ko, this message translates to:
  /// **'상세 내용(선택)'**
  String get groupEventReportDetailLabel;

  /// No description provided for @groupEventReportDetailHint.
  ///
  /// In ko, this message translates to:
  /// **'어떤 문제가 있는지 적어 주세요. (최대 500자)'**
  String get groupEventReportDetailHint;

  /// No description provided for @groupEventReportSubmit.
  ///
  /// In ko, this message translates to:
  /// **'신고하기'**
  String get groupEventReportSubmit;

  /// No description provided for @groupEventReportSubmitting.
  ///
  /// In ko, this message translates to:
  /// **'신고 중...'**
  String get groupEventReportSubmitting;

  /// No description provided for @groupEventReportSuccess.
  ///
  /// In ko, this message translates to:
  /// **'신고가 접수되었어요.'**
  String get groupEventReportSuccess;

  /// No description provided for @groupEventReportAlreadyReported.
  ///
  /// In ko, this message translates to:
  /// **'이미 신고 접수됨'**
  String get groupEventReportAlreadyReported;

  /// No description provided for @groupEventReportFailed.
  ///
  /// In ko, this message translates to:
  /// **'신고를 보내지 못했어요. 잠시 후 다시 시도해 주세요.'**
  String get groupEventReportFailed;

  /// No description provided for @groupEventReportActionTooltip.
  ///
  /// In ko, this message translates to:
  /// **'일정 신고'**
  String get groupEventReportActionTooltip;

  /// No description provided for @groupEventReportPolicyLink.
  ///
  /// In ko, this message translates to:
  /// **'신고 정책 및 이용약관'**
  String get groupEventReportPolicyLink;

  /// No description provided for @termsGateTitle.
  ///
  /// In ko, this message translates to:
  /// **'이용약관 동의'**
  String get termsGateTitle;

  /// No description provided for @termsGateBody.
  ///
  /// In ko, this message translates to:
  /// **'그룹에 공유된 일정은 초대된 멤버 모두에게 표시됩니다. 계속하려면 이용약관에 동의해 주세요.'**
  String get termsGateBody;

  /// No description provided for @termsGateViewTerms.
  ///
  /// In ko, this message translates to:
  /// **'이용약관 보기'**
  String get termsGateViewTerms;

  /// No description provided for @termsGateAccept.
  ///
  /// In ko, this message translates to:
  /// **'동의하고 계속하기'**
  String get termsGateAccept;

  /// No description provided for @termsGateLater.
  ///
  /// In ko, this message translates to:
  /// **'나중에'**
  String get termsGateLater;

  /// No description provided for @appUpdateAvailableTitle.
  ///
  /// In ko, this message translates to:
  /// **'업데이트 가능'**
  String get appUpdateAvailableTitle;

  /// No description provided for @appUpdateAvailableMessage.
  ///
  /// In ko, this message translates to:
  /// **'새 버전이 출시되었습니다. App Store에서 업데이트하시겠어요?'**
  String get appUpdateAvailableMessage;

  /// No description provided for @appUpdateLater.
  ///
  /// In ko, this message translates to:
  /// **'나중에'**
  String get appUpdateLater;

  /// No description provided for @appUpdateNow.
  ///
  /// In ko, this message translates to:
  /// **'업데이트'**
  String get appUpdateNow;

  /// No description provided for @appUpdateStoreOpenFailed.
  ///
  /// In ko, this message translates to:
  /// **'App Store를 열지 못했습니다. 나중에 다시 시도해 주세요.'**
  String get appUpdateStoreOpenFailed;

  /// No description provided for @featureTourSkip.
  ///
  /// In ko, this message translates to:
  /// **'건너뛰기'**
  String get featureTourSkip;

  /// No description provided for @featureTourRestart.
  ///
  /// In ko, this message translates to:
  /// **'다시 시작'**
  String get featureTourRestart;

  /// No description provided for @featureTourBack.
  ///
  /// In ko, this message translates to:
  /// **'이전'**
  String get featureTourBack;

  /// No description provided for @featureTourNext.
  ///
  /// In ko, this message translates to:
  /// **'다음'**
  String get featureTourNext;

  /// No description provided for @featureTourFinish.
  ///
  /// In ko, this message translates to:
  /// **'완료'**
  String get featureTourFinish;

  /// No description provided for @featureTourStep.
  ///
  /// In ko, this message translates to:
  /// **'3단계 중 {current}단계'**
  String featureTourStep(int current);

  /// No description provided for @featureTourSample.
  ///
  /// In ko, this message translates to:
  /// **'연습용 예시 · 실제 일정이 아닙니다'**
  String get featureTourSample;

  /// No description provided for @featureTourCreateTitle.
  ///
  /// In ko, this message translates to:
  /// **'연습 일정 만들기'**
  String get featureTourCreateTitle;

  /// No description provided for @featureTourCreateHint.
  ///
  /// In ko, this message translates to:
  /// **'제목을 입력하고 확인하면 다음 단계로 넘어갑니다.'**
  String get featureTourCreateHint;

  /// No description provided for @featureTourTitleLabel.
  ///
  /// In ko, this message translates to:
  /// **'일정 제목'**
  String get featureTourTitleLabel;

  /// No description provided for @featureTourCreateAction.
  ///
  /// In ko, this message translates to:
  /// **'연습 일정 만들기'**
  String get featureTourCreateAction;

  /// No description provided for @featureTourTitleRequired.
  ///
  /// In ko, this message translates to:
  /// **'계속하려면 예시 제목을 입력하세요.'**
  String get featureTourTitleRequired;

  /// No description provided for @featureTourEditTitle.
  ///
  /// In ko, this message translates to:
  /// **'예시 시간 바꾸기'**
  String get featureTourEditTitle;

  /// No description provided for @featureTourEditHint.
  ///
  /// In ko, this message translates to:
  /// **'시간을 고르거나 30분 뒤로 옮겨 보세요.'**
  String get featureTourEditHint;

  /// No description provided for @featureTourChooseTime.
  ///
  /// In ko, this message translates to:
  /// **'시간 선택'**
  String get featureTourChooseTime;

  /// No description provided for @featureTourAddThirty.
  ///
  /// In ko, this message translates to:
  /// **'30분 뒤로'**
  String get featureTourAddThirty;

  /// No description provided for @featureTourConfirmTime.
  ///
  /// In ko, this message translates to:
  /// **'예시 시간 확인'**
  String get featureTourConfirmTime;

  /// No description provided for @featureTourPreviewTitle.
  ///
  /// In ko, this message translates to:
  /// **'알림 미리보기'**
  String get featureTourPreviewTitle;

  /// No description provided for @featureTourPreviewHint.
  ///
  /// In ko, this message translates to:
  /// **'예시일 뿐이며 알람이 설정되지 않습니다.'**
  String get featureTourPreviewHint;

  /// No description provided for @featureTourPrep.
  ///
  /// In ko, this message translates to:
  /// **'준비 알림 · 15분 전'**
  String get featureTourPrep;

  /// No description provided for @featureTourDeparture.
  ///
  /// In ko, this message translates to:
  /// **'출발 알림 · 이동 20분 + 여유 10분'**
  String get featureTourDeparture;

  /// No description provided for @featureTourSampleTime.
  ///
  /// In ko, this message translates to:
  /// **'예시 일정 시간'**
  String get featureTourSampleTime;

  /// No description provided for @featureTourDateLabel.
  ///
  /// In ko, this message translates to:
  /// **'예시 날짜'**
  String get featureTourDateLabel;

  /// No description provided for @featureTourRestarted.
  ///
  /// In ko, this message translates to:
  /// **'연습을 다시 시작했어요'**
  String get featureTourRestarted;

  /// No description provided for @featureTourChooseDate.
  ///
  /// In ko, this message translates to:
  /// **'날짜 선택'**
  String get featureTourChooseDate;

  /// No description provided for @featureTourSaveFailed.
  ///
  /// In ko, this message translates to:
  /// **'완료 표시를 저장하지 못했어요. 다시 시도해 주세요.'**
  String get featureTourSaveFailed;

  /// No description provided for @featureTourSaveRetry.
  ///
  /// In ko, this message translates to:
  /// **'다시 시도'**
  String get featureTourSaveRetry;

  /// No description provided for @voiceTourStep.
  ///
  /// In ko, this message translates to:
  /// **'4단계 중 {current}단계'**
  String voiceTourStep(Object current);

  /// No description provided for @voiceTourPhaseCreateTitle.
  ///
  /// In ko, this message translates to:
  /// **'말로 일정 등록하기'**
  String get voiceTourPhaseCreateTitle;

  /// No description provided for @voiceTourPhaseCreateHint.
  ///
  /// In ko, this message translates to:
  /// **'마이크를 누르고 예시 문장을 말해 보세요. 인식된 일정은 저장을 누르기 전까지 반영되지 않아요.'**
  String get voiceTourPhaseCreateHint;

  /// No description provided for @voiceTourExampleCreate.
  ///
  /// In ko, this message translates to:
  /// **'예시: 내일 오전 9시에 강남역에서 팀장님과 면담'**
  String get voiceTourExampleCreate;

  /// No description provided for @voiceTourPhaseQueryTitle.
  ///
  /// In ko, this message translates to:
  /// **'말로 일정 물어보기'**
  String get voiceTourPhaseQueryTitle;

  /// No description provided for @voiceTourPhaseQueryHint.
  ///
  /// In ko, this message translates to:
  /// **'방금 저장한 일정을 말로 물어봐 보세요.'**
  String get voiceTourPhaseQueryHint;

  /// No description provided for @voiceTourExampleQuery.
  ///
  /// In ko, this message translates to:
  /// **'예시: 내일 일정 보여줘'**
  String get voiceTourExampleQuery;

  /// No description provided for @voiceTourPhaseEditTitle.
  ///
  /// In ko, this message translates to:
  /// **'말로 시간 바꾸기'**
  String get voiceTourPhaseEditTitle;

  /// No description provided for @voiceTourPhaseEditHint.
  ///
  /// In ko, this message translates to:
  /// **'조회된 목록의 첫 번째 일정 시간을 바꿔 보세요. 저장 전까지는 바뀌지 않아요.'**
  String get voiceTourPhaseEditHint;

  /// No description provided for @voiceTourExampleEdit.
  ///
  /// In ko, this message translates to:
  /// **'예시: 첫 번째 일정 오후 1시로 미뤄줘'**
  String get voiceTourExampleEdit;

  /// No description provided for @voiceTourPhaseDetailTitle.
  ///
  /// In ko, this message translates to:
  /// **'저장된 일정 확인하기'**
  String get voiceTourPhaseDetailTitle;

  /// No description provided for @voiceTourPhaseDetailHint.
  ///
  /// In ko, this message translates to:
  /// **'시간을 바꾼 뒤 저장된 일정을 열어 그대로 확인해 보세요.'**
  String get voiceTourPhaseDetailHint;

  /// No description provided for @voiceTourMicStart.
  ///
  /// In ko, this message translates to:
  /// **'마이크로 말하기'**
  String get voiceTourMicStart;

  /// No description provided for @voiceTourMicStop.
  ///
  /// In ko, this message translates to:
  /// **'말 끝내기'**
  String get voiceTourMicStop;

  /// No description provided for @voiceTourCancelMic.
  ///
  /// In ko, this message translates to:
  /// **'취소'**
  String get voiceTourCancelMic;

  /// No description provided for @voiceTourPreparing.
  ///
  /// In ko, this message translates to:
  /// **'준비 중이에요. 잠시만 기다려 주세요.'**
  String get voiceTourPreparing;

  /// No description provided for @voiceTourListening.
  ///
  /// In ko, this message translates to:
  /// **'듣고 있어요'**
  String get voiceTourListening;

  /// No description provided for @voiceTourTranscriptHint.
  ///
  /// In ko, this message translates to:
  /// **'인식된 문장이 여기에 보여요'**
  String get voiceTourTranscriptHint;

  /// No description provided for @voiceTourCreatePreviewTitle.
  ///
  /// In ko, this message translates to:
  /// **'인식된 일정'**
  String get voiceTourCreatePreviewTitle;

  /// No description provided for @voiceTourPreviewTitleLabel.
  ///
  /// In ko, this message translates to:
  /// **'제목'**
  String get voiceTourPreviewTitleLabel;

  /// No description provided for @voiceTourPreviewDate.
  ///
  /// In ko, this message translates to:
  /// **'날짜'**
  String get voiceTourPreviewDate;

  /// No description provided for @voiceTourPreviewTime.
  ///
  /// In ko, this message translates to:
  /// **'시간'**
  String get voiceTourPreviewTime;

  /// No description provided for @voiceTourPreviewLocation.
  ///
  /// In ko, this message translates to:
  /// **'장소'**
  String get voiceTourPreviewLocation;

  /// No description provided for @voiceTourPreviewLocationEmpty.
  ///
  /// In ko, this message translates to:
  /// **'없음'**
  String get voiceTourPreviewLocationEmpty;

  /// No description provided for @voiceTourPreviewNote.
  ///
  /// In ko, this message translates to:
  /// **'아직 저장되지 않았어요. 저장을 눌러야 반영됩니다.'**
  String get voiceTourPreviewNote;

  /// No description provided for @voiceTourSaveCreate.
  ///
  /// In ko, this message translates to:
  /// **'이 일정 저장'**
  String get voiceTourSaveCreate;

  /// No description provided for @voiceTourResultsTitle.
  ///
  /// In ko, this message translates to:
  /// **'저장된 일정'**
  String get voiceTourResultsTitle;

  /// No description provided for @voiceTourResultsEmpty.
  ///
  /// In ko, this message translates to:
  /// **'조회된 일정이 없어요.'**
  String get voiceTourResultsEmpty;

  /// No description provided for @voiceTourEditPreviewTitle.
  ///
  /// In ko, this message translates to:
  /// **'시간 변경 미리보기'**
  String get voiceTourEditPreviewTitle;

  /// No description provided for @voiceTourEditPreviewFrom.
  ///
  /// In ko, this message translates to:
  /// **'기존 시간'**
  String get voiceTourEditPreviewFrom;

  /// No description provided for @voiceTourEditPreviewTo.
  ///
  /// In ko, this message translates to:
  /// **'새 시간'**
  String get voiceTourEditPreviewTo;

  /// No description provided for @voiceTourEditPreviewNote.
  ///
  /// In ko, this message translates to:
  /// **'저장 전까지 기존 시간이 유지됩니다.'**
  String get voiceTourEditPreviewNote;

  /// No description provided for @voiceTourSaveEdit.
  ///
  /// In ko, this message translates to:
  /// **'변경 저장'**
  String get voiceTourSaveEdit;

  /// No description provided for @voiceTourOpenUpdated.
  ///
  /// In ko, this message translates to:
  /// **'저장된 일정 열어 보기'**
  String get voiceTourOpenUpdated;

  /// No description provided for @voiceTourDetailSavedTitle.
  ///
  /// In ko, this message translates to:
  /// **'저장된 일정'**
  String get voiceTourDetailSavedTitle;

  /// No description provided for @voiceTourDetailEventTime.
  ///
  /// In ko, this message translates to:
  /// **'일정 시간'**
  String get voiceTourDetailEventTime;

  /// No description provided for @voiceTourDetailDeparture.
  ///
  /// In ko, this message translates to:
  /// **'출발 시간'**
  String get voiceTourDetailDeparture;

  /// No description provided for @voiceTourDetailPreparation.
  ///
  /// In ko, this message translates to:
  /// **'준비 시간'**
  String get voiceTourDetailPreparation;

  /// No description provided for @voiceTourExampleNote.
  ///
  /// In ko, this message translates to:
  /// **'예시 값이에요. 실제 경로 계산·실제 일정·알림이 만들어지지 않아요. (이동 20분 + 여유 10분, 준비 15분 전)'**
  String get voiceTourExampleNote;

  /// No description provided for @voiceTourFinishLocked.
  ///
  /// In ko, this message translates to:
  /// **'저장된 일정을 열어 확인하면 완료할 수 있어요.'**
  String get voiceTourFinishLocked;

  /// No description provided for @voiceTourErrorPermission.
  ///
  /// In ko, this message translates to:
  /// **'마이크 권한이 필요해요. 권한을 허용한 뒤 다시 시도해 주세요.'**
  String get voiceTourErrorPermission;

  /// No description provided for @voiceTourErrorLocale.
  ///
  /// In ko, this message translates to:
  /// **'현재 언어는 음성 입력으로 연습할 수 없어요.'**
  String get voiceTourErrorLocale;

  /// No description provided for @voiceTourErrorSilence.
  ///
  /// In ko, this message translates to:
  /// **'음성이 인식되지 않았어요. 다시 말해 보세요.'**
  String get voiceTourErrorSilence;

  /// No description provided for @voiceTourErrorUnavailable.
  ///
  /// In ko, this message translates to:
  /// **'지금 음성 입력을 사용할 수 없어요. 잠시 후 다시 시도하거나 직접 입력으로 연습해 보세요.'**
  String get voiceTourErrorUnavailable;

  /// No description provided for @voiceTourUnsupported.
  ///
  /// In ko, this message translates to:
  /// **'문장을 이해하지 못했어요. 예시처럼 날짜와 시간을 함께 말해 주세요.'**
  String get voiceTourUnsupported;

  /// No description provided for @voiceTourTextMode.
  ///
  /// In ko, this message translates to:
  /// **'직접 입력으로 연습'**
  String get voiceTourTextMode;

  /// No description provided for @voiceTourTextLabel.
  ///
  /// In ko, this message translates to:
  /// **'직접 입력 (음성 아님)'**
  String get voiceTourTextLabel;

  /// No description provided for @voiceTourTextHint.
  ///
  /// In ko, this message translates to:
  /// **'예시 문장을 직접 입력하세요. 음성과 같은 방식으로 처리됩니다.'**
  String get voiceTourTextHint;

  /// No description provided for @voiceTourTextSubmit.
  ///
  /// In ko, this message translates to:
  /// **'입력 완료'**
  String get voiceTourTextSubmit;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ko'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ko':
      return AppLocalizationsKo();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
