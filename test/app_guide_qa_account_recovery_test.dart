import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/app.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/core/supabase_auth_options.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/services/auth_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const qaPackage = 'com.fluxstudio.planflow.guideqa';

  test('account switch requires an opted-in Android debug QA package', () async {
    var packageReads = 0;
    Future<String> readQaPackage() async {
      packageReads++;
      return qaPackage;
    }

    for (final (optIn, androidDebug) in [(false, true), (true, false)]) {
      expect(
        await canSwitchGuideQaAccount(
          isolatedGuideQa: optIn,
          androidDebug: androidDebug,
          readPackageName: readQaPackage,
        ),
        isFalse,
      );
    }
    expect(packageReads, 0);
    expect(
      await canSwitchGuideQaAccount(
        isolatedGuideQa: true,
        androidDebug: true,
        readPackageName: readQaPackage,
      ),
      isTrue,
    );
    expect(packageReads, 1);
    expect(
      await canSwitchGuideQaAccount(
        isolatedGuideQa: true,
        androidDebug: true,
        readPackageName: () async => 'com.fluxstudio.planflow',
      ),
      isFalse,
    );
    expect(
      await canSwitchGuideQaAccount(
        isolatedGuideQa: true,
        androidDebug: true,
        readPackageName: () async => throw StateError('package unavailable'),
      ),
      isFalse,
    );
  });

  test('guide entry waits for active auth and verified QA identity', () {
    final activeAuth = AuthProvider()..setUser('qa-current');
    final signedOutAuth = AuthProvider();
    final expiredAuth = _ExpiredAuthProvider()..setUser('qa-current');
    addTearDown(activeAuth.dispose);
    addTearDown(signedOutAuth.dispose);
    addTearDown(expiredAuth.dispose);

    expect(
      resolveGuideEntry(
        auth: activeAuth,
        isGuideQa: false,
        qaPackageCheckPending: true,
      ),
      (uid: null, qaAccountMismatch: false),
    );
    expect(
      resolveGuideEntry(
        auth: expiredAuth,
        isGuideQa: true,
        qaPackageCheckPending: false,
      ),
      (uid: null, qaAccountMismatch: false),
    );
    // The QA build omits PLANFLOW_GUIDE_QA_EXPECTED_UID, so the default
    // compile-time value must allow any authenticated account into the guide.
    expect(
      resolveGuideEntry(
        auth: activeAuth,
        isGuideQa: true,
        qaPackageCheckPending: false,
      ),
      (uid: 'qa-current', qaAccountMismatch: false),
    );
    // Local guide startup still requires a live signed-in user.
    expect(
      resolveGuideEntry(
        auth: signedOutAuth,
        isGuideQa: true,
        qaPackageCheckPending: false,
      ),
      (uid: null, qaAccountMismatch: false),
    );
    for (final (qa, expected, uid, mismatch) in [
      (true, '', 'qa-current', false),
      (true, 'qa-current', 'qa-current', false),
      (true, 'other', null, true),
      (false, 'other', 'qa-current', false),
    ]) {
      expect(
        resolveGuideEntry(
          auth: activeAuth,
          isGuideQa: qa,
          qaPackageCheckPending: false,
          expectedQaUid: expected,
        ),
        (uid: uid, qaAccountMismatch: mismatch),
      );
    }
  });

  late AuthProvider auth;
  late _FakeSessionClient service;
  late GuideQaAccountSwitch accountSwitch;

  setUp(() {
    auth = AuthProvider()..setUser('qa-current');
    service = _FakeSessionClient('qa-current');
    accountSwitch = GuideQaAccountSwitch();
  });

  tearDown(() {
    auth.dispose();
    accountSwitch.dispose();
    PlanFlowAuthLocalStorage.endExplicitSignOut();
  });

  test('account switch waits for the provider to confirm sign out', () async {
    var completed = false;
    final result = accountSwitch.signOut(
      uid: 'qa-current',
      auth: auth,
      service: service,
    ).then((signedOut) {
      completed = true;
      return signedOut;
    });

    expect(service.signOutCalls, 1);
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isTrue);
    service.currentSession = null;
    service.logout.complete();
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    auth.setUser(null);
    expect(await result, isTrue);
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isFalse);
  });

  test('account switch cannot sign out a different SDK session', () async {
    final differentSession = _FakeSessionClient('different');
    expect(
      await accountSwitch.signOut(
        uid: 'qa-current',
        auth: auth,
        service: differentSession,
      ),
      isFalse,
    );
    expect(differentSession.signOutCalls, 0);
  });

  test('a confirmed SDK mismatch can use the local sign-out path', () async {
    final currentSession = _FakeSessionClient('qa-sdk');
    var confirmations = 0;
    final result = accountSwitch.signOut(
      uid: 'qa-current',
      auth: auth,
      service: currentSession,
      confirmCurrentAccount: () async {
        confirmations++;
        return true;
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(confirmations, 1);
    expect(currentSession.signOutCalls, 1);
    currentSession.currentSession = null;
    currentSession.logout.complete();
    auth.setUser(null);

    expect(await result, isTrue);
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isFalse);
  });

  test('confirmation cannot sign out an SDK session that changed', () async {
    final currentSession = _FakeSessionClient('qa-sdk');
    final confirmation = Completer<bool>();
    final result = accountSwitch.signOut(
      uid: 'qa-current',
      auth: auth,
      service: currentSession,
      confirmCurrentAccount: () => confirmation.future,
    );
    expect(accountSwitch.canSwitch(auth), isFalse);
    expect(accountSwitch.inFlight, isFalse);
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isFalse);

    // A new login with the same UID can still establish a different session.
    final replacementSession = _FakeSessionClient('qa-sdk').currentSession;
    currentSession.currentSession = replacementSession;
    confirmation.complete(true);

    expect(await result, isFalse);
    expect(currentSession.signOutCalls, 0);
    expect(currentSession.currentSession, same(replacementSession));
    expect(accountSwitch.canSwitch(auth), isTrue);
  });

  test('declined mismatch confirmation leaves the SDK session intact', () async {
    final currentSession = _FakeSessionClient('qa-sdk');
    expect(
      await accountSwitch.signOut(
        uid: 'qa-current',
        auth: auth,
        service: currentSession,
        confirmCurrentAccount: () async => false,
      ),
      isFalse,
    );
    expect(currentSession.signOutCalls, 0);
    expect(accountSwitch.canSwitch(auth), isTrue);
  });

  test('account switch ignores a superseded sign out', () async {
    final result = accountSwitch.signOut(
      uid: 'qa-current',
      auth: auth,
      service: service,
    );
    auth.setUser('different');
    auth.setUser(null);
    service.currentSession = null;
    service.logout.complete();

    expect(await result, isFalse);
    expect(service.signOutCalls, 1);
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isFalse);
  });

  test('account switch lets the recovery screen handle sign-out failure', () async {
    final result = accountSwitch.signOut(
      uid: 'qa-current',
      auth: auth,
      service: service,
    );
    final failure = expectLater(result, throwsStateError);
    service.logout.completeError(StateError('synthetic failure'));
    await failure;

    expect(auth.userId, 'qa-current');
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isFalse);
    expect(accountSwitch.inFlight, isFalse);
  });

  test('late revoke failure allows login when local sign out already succeeded',
      () async {
    final result = accountSwitch.signOut(
      uid: 'qa-current',
      auth: auth,
      service: service,
    );
    service.currentSession = null;
    auth.setUser(null);
    service.logout.completeError(StateError('synthetic revoke failure'));

    expect(await result, isTrue);
    expect(auth.sessionStatus, AuthSessionStatus.signedOut);
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isFalse);
    expect(accountSwitch.inFlight, isFalse);
  });

  test('a new account cannot switch while the previous logout is pending',
      () async {
    final first = accountSwitch.signOut(
      uid: 'qa-current',
      auth: auth,
      service: service,
    );
    expect(PlanFlowAuthLocalStorage.isSessionRemovalAllowed, isTrue);
    service.currentSession = null;
    // AuthProvider consumes the explicit flag when it sees signedOut, which
    // the SDK emits before its pending revoke request completes.
    PlanFlowAuthLocalStorage.endExplicitSignOut();
    auth.setUser(null);
    final next = _FakeSessionClient('qa-next');
    service.currentSession = next.currentSession;
    auth.setUser('qa-next');

    expect(accountSwitch.canSwitch(auth), isFalse);
    expect(
      await accountSwitch.signOut(uid: 'qa-next', auth: auth, service: next),
      isFalse,
    );
    expect(next.signOutCalls, 0);
    service.logout.complete();

    expect(await first, isFalse);
    expect(auth.userId, 'qa-next');
    expect(service.currentSession?.user.id, 'qa-next');
    expect(PlanFlowAuthLocalStorage.isSessionRemovalAllowed, isFalse);
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isFalse);
    expect(accountSwitch.canSwitch(auth), isTrue);
  });

  test('expired account snapshots can sign out without a live session', () async {
    final expired = _ExpiredAuthProvider()..setUser('qa-current');
    addTearDown(expired.dispose);
    expect(accountSwitch.canSwitch(expired), isTrue);
    expect(
      await accountSwitch.signOut(
        uid: 'qa-current',
        auth: expired,
        service: _FakeSessionClient('different'),
      ),
      isFalse,
    );
    service.currentSession = null;
    final result = accountSwitch.signOut(
      uid: 'qa-current',
      auth: expired,
      service: service,
    );
    expect(service.signOutCalls, 1);
    expired.setUser(null);
    service.logout.complete();
    expect(await result, isTrue);
    expect(accountSwitch.canSwitch(expired), isFalse);
  });

  testWidgets('pending QA logout blocks login and Settings after UID changes',
      (tester) async {
    final current = _FakeSessionClient('qa-current');
    final next = _FakeSessionClient('qa-next');
    final settingsFocus = FocusNode();
    addTearDown(settingsFocus.dispose);
    var loginTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: ListenableBuilder(
        listenable: Listenable.merge([auth, accountSwitch]),
        builder: (_, __) => GuideQaAccountSwitchBarrier(
          pending: accountSwitch.inFlight,
          child: Scaffold(
            body: auth.userId == null
                ? TextButton(
                    onPressed: () => loginTaps++,
                    child: const Text('Sign in'),
                  )
                : TextButton(
                    focusNode: settingsFocus,
                    onPressed: () => unawaited(next.signOut()),
                    child: const Text('Settings sign out'),
                  ),
          ),
        ),
      ),
    ));
    bool? switchResult;
    unawaited(accountSwitch
        .signOut(uid: 'qa-current', auth: auth, service: current)
        .then((result) => switchResult = result));
    current.currentSession = null;
    PlanFlowAuthLocalStorage.endExplicitSignOut();
    auth.setUser(null);
    await tester.pump();

    final progress = find.text('계정을 로그아웃하고 있어요. 잠시만 기다려 주세요.');
    expect(progress, findsOneWidget);
    await tester.tap(find.text('Sign in'), warnIfMissed: false);
    expect(loginTaps, 0);

    // Even an external auth event for another account cannot expose the
    // Settings action while the previous request owns the storage guard.
    current.currentSession = next.currentSession;
    auth.setUser('qa-next');
    await tester.pump();
    final settingsSignOut = find.text('Settings sign out');
    expect(settingsFocus.canRequestFocus, isFalse);
    await tester.tap(settingsSignOut, warnIfMissed: false);
    expect(next.signOutCalls, 0);

    current.logout.complete();
    await tester.pump();
    expect(switchResult, isFalse);
    expect(progress, findsNothing);
    expect(settingsFocus.canRequestFocus, isTrue);
    expect(PlanFlowAuthLocalStorage.isSessionRemovalAllowed, isFalse);

    await tester.tap(settingsSignOut);
    expect(next.signOutCalls, 1);
    next.logout.complete();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(PlanFlowAuthLocalStorage.isSessionRemovalAllowed, isFalse);
  });

  testWidgets('only a verified QA package mounts the logout barrier',
      (tester) async {
    final child = TextButton(onPressed: () {}, child: const Text('Settings'));
    for (final (enabled, pending, expected) in [
      (false, false, findsNothing),
      (false, true, findsNothing),
      (true, false, findsOneWidget),
      (true, true, findsOneWidget),
    ]) {
      await tester.pumpWidget(MaterialApp(
        home: GuideQaAccountSwitchBarrier.wrap(
          enabled: enabled,
          pending: pending,
          child: child,
        ),
      ));
      expect(find.byType(GuideQaAccountSwitchBarrier), expected);
    }
  });

  testWidgets('logout can confirm after the former four-second deadline',
      (tester) async {
    final widgetService = _FakeSessionClient('qa-current');
    bool? switchResult;
    unawaited(accountSwitch
        .signOut(uid: 'qa-current', auth: auth, service: widgetService)
        .then((result) => switchResult = result));
    widgetService.currentSession = null;
    widgetService.logout.complete();
    await tester.pump();
    expect(PlanFlowAuthLocalStorage.isSessionRemovalAllowed, isFalse);
    await tester.pump(const Duration(seconds: 5));
    expect(switchResult, isNull);
    expect(accountSwitch.inFlight, isTrue);

    auth.setUser(null);
    await tester.pump();
    expect(switchResult, isTrue);
    expect(accountSwitch.inFlight, isFalse);
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isFalse);
  });

  testWidgets('missing provider confirmation keeps input blocked and can retry',
      (tester) async {
    final widgetService = _FakeSessionClient('qa-current');
    bool? switchResult;
    Future<void> switchAccount() async {
      switchResult = await accountSwitch.signOut(
        uid: 'qa-current',
        auth: auth,
        service: widgetService,
      );
    }

    final guideBarrier = find.descendant(
      of: find.byType(GuideQaAccountSwitchBarrier),
      matching: find.byType(ModalBarrier),
    );
    var settingsTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: ListenableBuilder(
        listenable: accountSwitch,
        builder: (_, __) => GuideQaAccountSwitchBarrier(
          pending: accountSwitch.inFlight,
          onRetry: accountSwitch.needsSignOutRecovery ? switchAccount : null,
          child: Center(
            child: TextButton(
              onPressed: () => settingsTaps++,
              child: const Text('Settings sign out'),
            ),
          ),
        ),
      ),
    ));
    unawaited(switchAccount());
    widgetService.currentSession = null;
    widgetService.logout.complete();
    await tester.pump();
    expect(guideBarrier, findsOneWidget);
    expect(accountSwitch.canSwitch(auth), isFalse);

    await tester.pump(const Duration(seconds: 8));
    expect(switchResult, isFalse);
    expect(auth.userId, 'qa-current');
    expect(guideBarrier, findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('로그아웃을 확인하지 못했어요.'), findsOneWidget);
    expect(accountSwitch.canSwitch(auth), isTrue);
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isTrue);
    expect(PlanFlowAuthLocalStorage.isSessionRemovalAllowed, isFalse);

    final settings = find.text('Settings sign out');
    await tester.tap(settings, warnIfMissed: false);
    expect(settingsTaps, 0);

    widgetService.logout = Completer<void>();
    await tester.tap(find.text('다시 확인'));
    await tester.pump();
    expect(widgetService.signOutCalls, 2);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    auth.setUser(null);
    widgetService.logout.complete();
    await tester.pump();
    expect(switchResult, isTrue);
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isFalse);
    expect(guideBarrier, findsNothing);
    await tester.tap(settings);
    expect(settingsTaps, 1);
  });

  testWidgets('late SDK signedOut clears the old provider snapshot',
      (tester) async {
    final previouslyReady = AppEnv.isSupabaseReady;
    final authEvents = StreamController<AuthState>.broadcast();
    final widgetService = _FakeSessionClient(
      'qa-current',
      authStateChanges: authEvents.stream,
    );
    final listeningAuth = AuthProvider(authService: widgetService);
    addTearDown(() async {
      listeningAuth.dispose();
      await authEvents.close();
      if (!previouslyReady) AppEnv.resetSupabaseInitializationState();
    });

    AppEnv.markSupabaseInitialized();
    listeningAuth.start();
    await tester.pump();
    expect(listeningAuth.sessionStatus, AuthSessionStatus.active);
    expect(listeningAuth.userId, 'qa-current');
    final startupRefreshCount = widgetService.refreshCalls;

    var underlyingTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: ListenableBuilder(
        listenable: accountSwitch,
        builder: (_, __) => GuideQaAccountSwitchBarrier(
          pending: accountSwitch.inFlight,
          onRetry: accountSwitch.needsSignOutRecovery ? () {} : null,
          child: Center(
            child: TextButton(
              onPressed: () => underlyingTaps++,
              child: const Text('Underlying action'),
            ),
          ),
        ),
      ),
    ));
    final logout = accountSwitch.signOut(
      uid: 'qa-current',
      auth: listeningAuth,
      service: widgetService,
    );
    widgetService.currentSession = null;
    widgetService.logout.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));

    expect(await logout, isFalse);
    expect(accountSwitch.needsSignOutRecovery, isTrue);
    expect(listeningAuth.userId, 'qa-current');
    expect(find.text('로그아웃을 확인하지 못했어요.'), findsOneWidget);
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isTrue);
    expect(PlanFlowAuthLocalStorage.isSessionRemovalAllowed, isFalse);
    final underlyingAction = find.text('Underlying action');
    await tester.tap(underlyingAction, warnIfMissed: false);
    expect(underlyingTaps, 0);

    authEvents.add(const AuthState(AuthChangeEvent.signedOut, null));
    await tester.pump();
    expect(listeningAuth.sessionStatus, AuthSessionStatus.signedOut);
    expect(listeningAuth.userId, isNull);
    expect(widgetService.refreshCalls, startupRefreshCount);
    expect(widgetService.signOutCalls, 1);
    expect(accountSwitch.needsSignOutRecovery, isFalse);
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isFalse);
    expect(find.text('로그아웃을 확인하지 못했어요.'), findsNothing);
    await tester.tap(underlyingAction);
    expect(underlyingTaps, 1);
  });

  testWidgets('disposing the account switch cancels its provider wait',
      (tester) async {
    final disposedSwitch = GuideQaAccountSwitch();
    final widgetService = _FakeSessionClient('qa-current');
    bool? switchResult;
    unawaited(disposedSwitch
        .signOut(uid: 'qa-current', auth: auth, service: widgetService)
        .then((result) => switchResult = result));
    widgetService.currentSession = null;
    widgetService.logout.complete();
    await tester.pump();
    expect(disposedSwitch.inFlight, isTrue);

    disposedSwitch.dispose();
    await tester.pump();
    expect(switchResult, isFalse);
    expect(disposedSwitch.inFlight, isFalse);
    expect(auth.userId, 'qa-current');
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isFalse);
  });

  testWidgets('disposing the expired wait releases the sign-out marker',
      (tester) async {
    final disposedSwitch = GuideQaAccountSwitch();
    final widgetService = _FakeSessionClient('qa-current');
    final logout = disposedSwitch.signOut(
      uid: 'qa-current',
      auth: auth,
      service: widgetService,
    );
    widgetService.currentSession = null;
    widgetService.logout.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));

    expect(await logout, isFalse);
    expect(disposedSwitch.needsSignOutRecovery, isTrue);
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isTrue);
    disposedSwitch.dispose();
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isFalse);
    expect(PlanFlowAuthLocalStorage.isSessionRemovalAllowed, isFalse);
    expect(auth.userId, 'qa-current');
  });

  testWidgets('retry does not sign out a replacement SDK session',
      (tester) async {
    final widgetService = _FakeSessionClient('qa-current');
    bool? switchResult;
    unawaited(accountSwitch
        .signOut(uid: 'qa-current', auth: auth, service: widgetService)
        .then((result) => switchResult = result));
    widgetService.currentSession = null;
    widgetService.logout.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    expect(switchResult, isFalse);
    expect(accountSwitch.needsSignOutRecovery, isTrue);

    // A replacement SDK session can have the same UID and no provider event.
    final replacement = _FakeSessionClient('qa-current').currentSession;
    widgetService.currentSession = replacement;
    expect(
      await accountSwitch.signOut(
        uid: 'qa-current',
        auth: auth,
        service: widgetService,
      ),
      isFalse,
    );
    expect(widgetService.currentSession, same(replacement));
    expect(widgetService.signOutCalls, 1);
    expect(auth.userId, 'qa-current');
    expect(accountSwitch.inFlight, isFalse);
    expect(accountSwitch.needsSignOutRecovery, isFalse);
    expect(PlanFlowAuthLocalStorage.isExplicitSignOutInProgress, isFalse);
  });
}

class _ExpiredAuthProvider extends AuthProvider {
  @override
  bool get hasActiveSession => false;

  @override
  AuthSessionStatus get sessionStatus => userId == null
      ? AuthSessionStatus.signedOut
      : AuthSessionStatus.reauthRequired;
}

class _FakeSessionClient implements AuthSessionClient {
  _FakeSessionClient(String uid, {this.authStateChanges = const Stream.empty()})
      : currentSession = Session(
          accessToken: 'synthetic',
          tokenType: 'bearer',
          user: User(
            id: uid,
            appMetadata: const {},
            userMetadata: const {},
            aud: 'authenticated',
            createdAt: '2026-01-01T00:00:00Z',
          ),
        );

  @override
  Session? currentSession;
  @override
  User? get currentUser => currentSession?.user;
  @override
  final Stream<AuthState> authStateChanges;
  Completer<void> logout = Completer<void>();
  int signOutCalls = 0;
  int refreshCalls = 0;

  @override
  Future<void> signOut() {
    signOutCalls++;
    return PlanFlowAuthLocalStorage.runWithSessionRemovalAllowed(
      () => logout.future,
    );
  }

  @override
  Future<void> ensureProfile([User? user]) async {}
  @override
  Future<void> refreshSession() async {
    refreshCalls++;
  }
}
