// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'PlanFlow';

  @override
  String get homeTab => 'Home';

  @override
  String get calendarTab => 'Calendar';

  @override
  String get settingsTab => 'Settings';

  @override
  String get loginTitle => 'Log in';

  @override
  String get signUpTitle => 'Sign up';

  @override
  String get passwordResetTitle => 'Find password';

  @override
  String get loginSubtitle =>
      'Log in with email and password, or start with a social account below.';

  @override
  String get signUpSubtitle =>
      'Create an account to keep your schedule data safely separated by user.';

  @override
  String get passwordResetSubtitle =>
      'We will send a password reset link to your registered email.';

  @override
  String get emailLogin => 'Email login';

  @override
  String get simpleLogin => 'Quick login';

  @override
  String get email => 'Email';

  @override
  String get password => 'Password';

  @override
  String get confirmPassword => 'Confirm password';

  @override
  String get name => 'Name';

  @override
  String get loginWithEmail => 'Log in with email';

  @override
  String get signUpWithEmail => 'Sign up with email';

  @override
  String get sendPasswordReset => 'Send password reset email';

  @override
  String get forgotPassword => 'Forgot your password?';

  @override
  String get backToLogin => 'Back to login';

  @override
  String get googleContinue => 'Continue with Google';

  @override
  String get kakaoContinue => 'Continue with Kakao';

  @override
  String get naverContinue => 'Continue with Naver';

  @override
  String get supabaseLoginMissing =>
      'Supabase build settings are required before login.';

  @override
  String get supabaseSocialMissing =>
      'Supabase build settings are required before social login.';

  @override
  String get invalidEmail => 'Please enter a valid email.';

  @override
  String get shortPassword => 'Password must be at least 6 characters.';

  @override
  String get passwordMismatch => 'Password confirmation does not match.';

  @override
  String get loginSessionFailed =>
      'Could not verify the login session. Please try again shortly.';

  @override
  String get signUpEmailSent =>
      'We sent a sign-up email. Please complete verification from your inbox.';

  @override
  String get signUpSessionFailed =>
      'Could not verify the sign-up session. Please try logging in again.';

  @override
  String get passwordResetSent =>
      'We sent a password reset email. Please check your inbox.';

  @override
  String get oauthLaunchFailed =>
      'Could not open the login window. Please check your browser settings.';

  @override
  String get authInvalidCredentials => 'Email or password is incorrect.';

  @override
  String get authEmailNotConfirmed =>
      'Email verification is not complete yet. Please check your inbox.';

  @override
  String get authAlreadyRegistered =>
      'This email is already registered. Please log in instead.';

  @override
  String get authGenericError =>
      'Authentication failed. Please check your settings and input.';

  @override
  String get voiceInputTitle => 'Voice input';

  @override
  String get voiceInputIntro => 'Speak or type, then review right away.';

  @override
  String get voiceGuideTitle => 'Try saying this';

  @override
  String get voiceGuideFooter =>
      'Including time, place, and repeat details makes it more accurate.';

  @override
  String get voiceListenIdle =>
      'Tap the button below to speak, or type directly.';

  @override
  String get voiceListenActive =>
      'Listening on-device. You can keep speaking until you tap Done.';

  @override
  String voiceListenRestarted(int count) {
    return 'Voice recognition continued $count times. Previous speech is kept.';
  }

  @override
  String get voiceTranscriptTitle => 'Voice text / direct input';

  @override
  String get voiceInputHint => 'Type here';

  @override
  String get voiceListeningContinue => 'Still listening.';

  @override
  String get voiceCheckRecognized => 'Please review the recognized text.';

  @override
  String get voicePrimaryStart => 'Enter schedule by voice';

  @override
  String get voiceDone => 'Done';

  @override
  String get voiceClearAll => 'Clear all';

  @override
  String get voiceClearAllCompact => 'Clear';

  @override
  String get voiceDeleteLast => 'Delete last word';

  @override
  String get voiceDeleteLastCompact => 'Last';

  @override
  String get voiceManualInput => 'Direct input';

  @override
  String get voiceManualInputCompact => 'Type';

  @override
  String get voiceCancelTooltip => 'Cancel voice input';

  @override
  String get voiceAutoRestarted =>
      'Voice recognition continued automatically. Keep speaking until you tap Done.';

  @override
  String get voiceNoResult =>
      'No voice result was recognized. Continue by typing directly.';

  @override
  String get voiceFailed =>
      'Could not process voice input. Continue by typing directly.';

  @override
  String get voiceCancelled =>
      'Voice input was cancelled. You can start again.';

  @override
  String get voiceClearedEmpty => 'Input was cleared.';

  @override
  String get voiceDeletedLast => 'Deleted the last word.';

  @override
  String get voiceClearedAll =>
      'Cleared all input. Speak again or type directly.';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get resetDefaultsTooltip => 'Reset to defaults';

  @override
  String get regionSettingsTitle => 'Country / Time';

  @override
  String get regionSettingsSubtitle =>
      'Choose the schedule time zone and app language.';

  @override
  String get countryLabel => 'Country';

  @override
  String get calendarSyncTitle => 'Calendar sync';

  @override
  String get backupRestoreTitle => 'Backup and restore';

  @override
  String get korea => 'South Korea';

  @override
  String get unitedStates => 'United States';

  @override
  String get japan => 'Japan';

  @override
  String get unitedKingdom => 'United Kingdom';

  @override
  String get germany => 'Germany';

  @override
  String get france => 'France';

  @override
  String get australia => 'Australia';

  @override
  String get eventCreateTitle => 'Create event';

  @override
  String get eventEditTitle => 'Edit event';

  @override
  String get save => 'Save';

  @override
  String get saving => 'Saving...';

  @override
  String get cancel => 'Cancel';

  @override
  String get apply => 'Apply';

  @override
  String get titleField => 'Title';

  @override
  String get locationField => 'Location';

  @override
  String get memoField => 'Memo';

  @override
  String get suppliesField => 'Supplies';

  @override
  String get dateTimePickerTitle => 'Choose date and time';

  @override
  String get hourLabel => 'Hour';

  @override
  String get minuteLabel => 'Minute';
}
