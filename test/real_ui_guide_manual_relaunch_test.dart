// Focused contract tests for the MANUAL cold-relaunch resume path of the
// native real-UI guide QA.
//
// Pure doubles only: fake clock, in-memory secure store, synthetic tokens and
// a temporary directory. No device, no ADB, no network, no Supabase call and
// no private runtime file is touched.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:planflow/core/app_http.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../integration_test/real_ui_guide_manual_app.dart';
import '../integration_test/support/native_guide_budget_ledger.dart';
import '../integration_test/support/real_ui_guide_manual_resume.dart';
import '../integration_test/support/real_ui_guide_native_environment.dart';

const _uid = '11111111-2222-4333-8444-555555555555';
const _otherUid = '99999999-8888-4777-8666-555555555555';
const _backendHost = 'xqvvfnvmytjlblcngipn.supabase.co';
const _budgetId = 'planflow-guide-FRM9-20261021';
const _originalRunId = 'guideqaorig20261021';

String _b64(Map<String, Object?> value) =>
    base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

/// Synthetic JWT with a real payload shape (no signature, never verified).
String _fakeToken({required String uid, required DateTime expiry}) =>
    '${_b64(<String, Object?>{'alg': 'none', 'typ': 'JWT'})}'
    '.${_b64(<String, Object?>{
          'sub': uid,
          'exp': expiry.millisecondsSinceEpoch ~/ 1000
        })}'
    '.sig';

class _FakeSecureStore implements SecureResumeStore {
  _FakeSecureStore([this.value]);

  String? value;
  bool failOnRead = false;
  bool failOnWrite = false;
  int reads = 0;
  int writes = 0;

  @override
  Future<String?> read(String key) async {
    reads++;
    if (failOnRead) throw StateError('secure storage unavailable');
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    if (failOnWrite) throw StateError('secure storage write failed');
    this.value = value;
  }
}

class _FenceTransportTripwire extends HttpOverrides implements HttpClient {
  int attempts = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) => this;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    attempts++;
    throw StateError('The QA fence forwarded a request unexpectedly');
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

ManualResumeRecord _record({
  required DateTime deadline,
  required DateTime tokenExpiry,
  required String directoryPath,
  String uid = _uid,
  String backendHost = _backendHost,
  String budgetId = _budgetId,
  int maxAiRequests = kManualResumeMaxAiRequests,
  bool dedicatedTestAccount = true,
  String originalRunId = _originalRunId,
  String? sessionUid,
  String? sessionUserId,
}) {
  final sessionUidValue = sessionUid ?? uid;
  return ManualResumeRecord(
    policy: ManualResumePolicy(
      uid: uid,
      backendHost: backendHost,
      budgetId: budgetId,
      maxAiRequests: maxAiRequests,
      dedicatedTestAccount: dedicatedTestAccount,
      originalRunId: originalRunId,
      deadline: deadline,
      tokenExpiry: tokenExpiry,
      directoryPath: directoryPath,
    ),
    session: <String, dynamic>{
      'access_token': _fakeToken(uid: sessionUidValue, expiry: tokenExpiry),
      'refresh_token': 'synthetic-refresh-token',
      'token_type': 'bearer',
      'user': <String, dynamic>{'id': sessionUserId ?? sessionUidValue},
    },
    anonKey: 'synthetic-anon-key',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.utc(2026, 10, 21, 12);
  final tokenExpiry = now.add(const Duration(minutes: 45));

  group('deadline policy', () {
    test('effective deadline is min(session window, token expiry)', () {
      final windowed = computeManualResumeDeadline(
        sessionStartedAt: now,
        tokenExpiry: now.add(const Duration(hours: 3)),
      );
      expect(windowed, now.add(kNativeGuideManualSessionWindow));
      // banned-ok: Computes a deadline using test inputs.
      final tokenBound = computeManualResumeDeadline(
        sessionStartedAt: now,
        tokenExpiry: now.add(const Duration(minutes: 5)),
      );
      expect(tokenBound, now.add(const Duration(minutes: 5)));
    });
  });

  group('startup decision', () {
    test('a cold relaunch never waits for the one-use runtime file', () {
      expect(
        decideManualStartupMode(
          forceResume: false,
          runtimeFilePresent: false,
          consumedMarkerPresent: true,
        ),
        ManualStartupMode.manualResume,
      );
      expect(
        decideManualStartupMode(
          forceResume: true,
          runtimeFilePresent: true,
          consumedMarkerPresent: false,
        ),
        ManualStartupMode.manualResume,
      );
    });

    test('a fresh start keeps the default one-use path', () {
      expect(
        decideManualStartupMode(
          forceResume: false,
          runtimeFilePresent: true,
          consumedMarkerPresent: true,
        ),
        ManualStartupMode.freshOneUse,
      );
      expect(
        decideManualStartupMode(
          forceResume: false,
          runtimeFilePresent: false,
          consumedMarkerPresent: false,
        ),
        ManualStartupMode.freshOneUse,
      );
    });
  });

  group('consumed-marker locator (real Android default paths)', () {
    // The configured default runtime path of the guide QA app on Android.
    // Its parent directory ends with '/files' WITHOUT a trailing segment,
    // which is exactly the shape the previous host-side guard rejected.
    const defaultRuntimePath =
        '/data/user/0/com.fluxstudio.planflow.guideqa/files/'
        'guide-qa-runtime.json';

    test('the exact default runtime path ending in files yields the marker',
        () {
      // Regression: the shipped guard required the PARENT directory to
      // contain '/files/', but the real default parent ends with '/files',
      // so the marker was never located (and never written) on the device
      // and every cold relaunch degraded to the 45 s one-use wait.
      expect(
        consumedMarkerPathForRuntime(defaultRuntimePath),
        '/data/user/0/com.fluxstudio.planflow.guideqa/files/'
        '$kConsumedRuntimeMarkerName',
      );
    });

    test('a runtime file nested under files puts the marker beside it', () {
      expect(
        consumedMarkerPathForRuntime(
            '/data/user/0/com.fluxstudio.planflow.guideqa/files/'
            'sub/guide-qa-runtime.json'),
        '/data/user/0/com.fluxstudio.planflow.guideqa/files/sub/'
        '$kConsumedRuntimeMarkerName',
      );
    });

    test('paths outside the app-private files tree are rejected', () {
      for (final path in [
        '',
        'guide-qa-runtime.json',
        '/storage/emulated/0/Android/data/'
            'com.fluxstudio.planflow.guideqa/files/guide-qa-runtime.json',
        '/data/user/0/com.fluxstudio.planflow.guideqa/cache/'
            'guide-qa-runtime.json',
        '/data/user/0/com.fluxstudio.planflow.guideqa/databases/'
            'guide-qa-runtime.json',
        '/data/user/0/com.fluxstudio.planflow.guideqa/shared_prefs/'
            'guide-qa-runtime.json',
      ]) {
        expect(consumedMarkerPathForRuntime(path), isNull, reason: path);
      }
    });

    test('dot-dot segments are rejected even inside the files tree', () {
      expect(
        consumedMarkerPathForRuntime(
            '/data/user/0/com.fluxstudio.planflow.guideqa/files/../'
            'guide-qa-runtime.json'),
        isNull,
      );
      expect(
        consumedMarkerPathForRuntime(
            '/data/user/0/com.fluxstudio.planflow.guideqa/files/'
            'sub/../guide-qa-runtime.json'),
        isNull,
      );
    });

    test('non-posix or malformed paths are rejected', () {
      for (final path in [
        r'C:\data\user\0\com.fluxstudio.planflow.guideqa\files'
            r'\guide-qa-runtime.json',
        '/data/user/0/com.fluxstudio.planflow.guideqa/files\\'
            'guide-qa-runtime.json',
        '/data/user/0//com.fluxstudio.planflow.guideqa/files/'
            'guide-qa-runtime.json',
        '/data/user/0/com.fluxstudio.planflow.guideqa/files/',
        '/data/user/0/com.fluxstudio.planflow.guideqa/files//'
            'guide-qa-runtime.json',
        '/data/user/0/pkg/filesx/guide-qa-runtime.json',
      ]) {
        expect(consumedMarkerPathForRuntime(path), isNull, reason: path);
      }
    });
  });

  group('android app-private directory validation (real default path)', () {
    // The real native environment persists `directory.path` of the Android
    // app-private files dir: it ENDS with '/files' and has no trailing
    // segment. The strict validator used to require '/files/' here, so a
    // genuine cold resume degraded to recordCorruptRecovery even when the
    // consumed marker was located correctly.
    const defaultDirectoryPath =
        '/data/user/0/com.fluxstudio.planflow.guideqa/files';
    const defaultRuntimePath =
        '/data/user/0/com.fluxstudio.planflow.guideqa/files/'
        'guide-qa-runtime.json';

    Future<ManualResumeOutcome> validate(
      String directoryPath, {
      bool requireAndroidDirectoryPath = true,
    }) async {
      final record = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: tokenExpiry,
        directoryPath: directoryPath,
      );
      // Pure validation: no Android directory and no real FS are touched.
      return validateManualResumeRecord(
        raw: record.encode(),
        now: now,
        expectedBackendHost: _backendHost,
        requireAndroidDirectoryPath: requireAndroidDirectoryPath,
      );
    }

    test('the real default directory ending in /files is accepted', () async {
      final outcome = await validate(defaultDirectoryPath);
      expect(outcome.isSuccess, isTrue,
          reason: 'a real cold resume must not fail closed on its own path');
      expect(outcome.failure, isNull);
      expect(outcome.record!.policy.directoryPath, defaultDirectoryPath);
    });

    test('a runtime file and its directory resolve together on device shape',
        () async {
      // Both halves of the real cold-resume evidence chain must accept the
      // SAME actual Android path, not a fake boolean or an unchecked branch.
      final marker = consumedMarkerPathForRuntime(defaultRuntimePath);
      expect(marker, '$defaultDirectoryPath/$kConsumedRuntimeMarkerName');
      final markerDirectory = marker!.substring(0, marker.lastIndexOf('/'));
      expect(markerDirectory, defaultDirectoryPath);

      final dirOutcome = await validate(markerDirectory);
      final runtimeOutcome =
          await validate(markerDirectory, requireAndroidDirectoryPath: true);
      expect(dirOutcome.isSuccess, isTrue);
      expect(runtimeOutcome.isSuccess, isTrue);
      expect(
        decideManualStartupMode(
          forceResume: false,
          runtimeFilePresent: false,
          consumedMarkerPresent: marker.isNotEmpty,
        ),
        ManualStartupMode.manualResume,
      );
    });

    test('a directory nested under files is accepted', () async {
      final outcome = await validate('$defaultDirectoryPath/guideqa-sub');
      expect(outcome.isSuccess, isTrue);
    });

    test('look-alike and foreign directories are rejected', () async {
      for (final path in [
        '/data/user/0/com.fluxstudio.planflow.guideqa/filesx',
        '/data/user/0/com.fluxstudio.planflow.guideqa/files/..',
        '/data/user/0/com.fluxstudio.planflow.guideqa/cache',
        '/data/user/0/com.fluxstudio.planflow.guideqa/databases',
        '/data/user/0/com.fluxstudio.planflow.guideqa/shared_prefs',
        '/data/user/0/com.fluxstudio.planflow.guideqa',
        '/data/user/1/com.fluxstudio.planflow.guideqa/files',
        '/data/data/com.fluxstudio.planflow.guideqa/files',
        '/storage/emulated/0/Android/data/'
            'com.fluxstudio.planflow.guideqa/files',
        '/data/user/0/com.fluxstudio.planflow.guideqa/files/',
        '/data/user/0//com.fluxstudio.planflow.guideqa/files',
        r'\data\user\0\com.fluxstudio.planflow.guideqa\files',
        '/data/user/0/com.fluxstudio.planflow.guideqa\\files',
        'data/user/0/com.fluxstudio.planflow.guideqa/files',
        '',
      ]) {
        final outcome = await validate(path);
        expect(outcome.isSuccess, isFalse, reason: path);
        expect(outcome.failure, ManualResumeFailure.recordCorrupt,
            reason: path);
      }
    });

    test('the relaxed shape keeps every later policy gate intact', () async {
      final expired = _record(
        deadline: now.subtract(const Duration(seconds: 1)),
        tokenExpiry: tokenExpiry,
        directoryPath: defaultDirectoryPath,
      );
      final expiredOutcome = validateManualResumeRecord(
        raw: expired.encode(),
        now: now,
        expectedBackendHost: _backendHost,
      );
      expect(expiredOutcome.failure, ManualResumeFailure.deadlineExpired);

      final wrongUid = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: tokenExpiry,
        directoryPath: defaultDirectoryPath,
        maxAiRequests: 5,
      );
      final wrongUidOutcome = validateManualResumeRecord(
        raw: wrongUid.encode(),
        now: now,
        expectedBackendHost: _backendHost,
      );
      expect(wrongUidOutcome.failure, ManualResumeFailure.maxRequestsMismatch);
    });
  });

  group('cold icon relaunch with the consumed marker', () {
    const defaultRuntimePath =
        '/data/user/0/com.fluxstudio.planflow.guideqa/files/'
        'guide-qa-runtime.json';

    test('force-stop + launcher icon (no runtime reinjection) resumes', () {
      // The fresh run consumed and deleted the one-use runtime file and
      // wrote the consumed marker next to it: a launcher-icon cold relaunch
      // must resume instead of waiting 45 s for a file nobody will write
      // again. The marker locator must work for the real default path for
      // this selector input to be reachable at all on the device.
      final marker = consumedMarkerPathForRuntime(defaultRuntimePath);
      expect(marker, isNotNull);
      expect(
        decideManualStartupMode(
          forceResume: false,
          runtimeFilePresent: false,
          consumedMarkerPresent: true,
        ),
        ManualStartupMode.manualResume,
      );
    });
  });

  group('missing-marker fallback after the one-use wait', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('manual-missing-marker');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('only the runtime-missing timeout may trigger the fallback', () {
      expect(isRuntimeMissingTimeout(StateError('Runtime missing')), isTrue);
      expect(isRuntimeMissingTimeout(StateError('Run identity already used')),
          isFalse);
      expect(
          isRuntimeMissingTimeout(StateError(
              'Runtime scope rejected; AppEnv has no runtime setter')),
          isFalse);
      expect(
          isRuntimeMissingTimeout(
              StateError('App-private Android runtime path required')),
          isFalse);
      expect(
          isRuntimeMissingTimeout(
              ManualResumeException(ManualResumeFailure.recordMissing)),
          isFalse);
      expect(isRuntimeMissingTimeout(Exception('Runtime missing')), isFalse);
    });

    test('a runtime-missing timeout falls back to the secure resume', () async {
      final record = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
      );
      var freshCalls = 0;
      var resumeCalls = 0;
      final env = await openFreshWithMissingMarkerFallback(
        loadFresh: () async {
          freshCalls++;
          throw StateError('Runtime missing');
        },
        loadManualResume: () async {
          resumeCalls++;
          return NativeGuideEnvironment.loadManualResume(
            store: _FakeSecureStore(record.encode()),
            now: now,
            expectedBackendHost: _backendHost,
            requireAndroidDirectoryPath: false,
          );
        },
      );
      expect(freshCalls, 1,
          reason: 'the fresh one-use wait must always run first');
      expect(resumeCalls, 1);
      expect(env.uid, _uid);
      expect(env.runId, isNot(_originalRunId));
      expect(env.sessionDeadline, now.add(const Duration(minutes: 30)));
    });

    test('other fresh-load failures never fall back', () async {
      var resumeCalls = 0;
      await expectLater(
        openFreshWithMissingMarkerFallback(
          loadFresh: () async {
            throw StateError('Run identity already used');
          },
          loadManualResume: () async {
            resumeCalls++;
            throw StateError('unreachable');
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(resumeCalls, 0);
    });

    test('a failing fallback stays fail closed (no usable state)', () async {
      await expectLater(
        openFreshWithMissingMarkerFallback(
          loadFresh: () async {
            throw StateError('Runtime missing');
          },
          loadManualResume: () => NativeGuideEnvironment.loadManualResume(
            store: _FakeSecureStore(null), // no usable persisted state
            now: now,
            expectedBackendHost: _backendHost,
            requireAndroidDirectoryPath: false,
          ),
        ),
        throwsA(isA<ManualResumeException>().having(
            (e) => e.failure, 'failure', ManualResumeFailure.recordMissing)),
      );
      expect(
        tmp.listSync().where((f) => f.path.contains('native-guide-')),
        isEmpty,
        reason: 'a failed fallback must never leave run files behind',
      );
    });
  });

  group('secure record validation', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('manual-resume-record');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<ManualResumeOutcome> load(_FakeSecureStore store,
            {String? expectedUid}) =>
        ManualResumeService(store: store).load(
          now: now,
          expectedBackendHost: _backendHost,
          expectedUid: expectedUid,
          requireAndroidDirectoryPath: false,
        );

    test('a valid record loads and keeps its policy', () async {
      final record = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
      );
      final store = _FakeSecureStore(record.encode());
      final outcome = await load(store);
      expect(outcome.isSuccess, isTrue);
      expect(outcome.failure, isNull);
      expect(outcome.record!.policy.uid, _uid);
      expect(outcome.record!.policy.backendHost, _backendHost);
      expect(outcome.record!.policy.budgetId, _budgetId);
      expect(outcome.record!.policy.maxAiRequests, kLedgerMaxAiRequests);
      expect(outcome.record!.policy.dedicatedTestAccount, isTrue);
      expect(outcome.record!.policy.deadline,
          now.add(const Duration(minutes: 30)));
      expect(store.reads, 1);
    });

    test('a missing record fails fast without any wait', () async {
      final outcome = await load(_FakeSecureStore(null));
      expect(outcome.isSuccess, isFalse);
      expect(outcome.failure, ManualResumeFailure.recordMissing);
    });

    test('an unusable secure store fails closed immediately', () async {
      final store = _FakeSecureStore(null)..failOnRead = true;
      await expectLater(
        load(store),
        throwsA(isA<ManualResumeException>().having((e) => e.failure, 'failure',
            ManualResumeFailure.secureStorageUnavailable)),
      );
    });

    test('a corrupt record fails closed', () async {
      final outcome = await load(_FakeSecureStore('{not json'));
      expect(outcome.failure, ManualResumeFailure.recordCorrupt);
    });

    test('an expired session fails closed', () async {
      final expired = now.subtract(const Duration(minutes: 1));
      final record = _record(
        deadline: now.add(const Duration(minutes: 10)),
        tokenExpiry: expired,
        directoryPath: tmp.path,
      );
      final outcome = await load(_FakeSecureStore(record.encode()));
      expect(outcome.failure, ManualResumeFailure.sessionExpired);
    });

    test('an expired deadline fails closed', () async {
      final record = _record(
        deadline: now.subtract(const Duration(seconds: 1)),
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
      );
      final outcome = await load(_FakeSecureStore(record.encode()));
      expect(outcome.failure, ManualResumeFailure.deadlineExpired);
    });

    test('a widened deadline fails closed', () async {
      final record = _record(
        deadline: tokenExpiry.add(const Duration(minutes: 5)),
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
      );
      final outcome = await load(_FakeSecureStore(record.encode()));
      expect(outcome.failure, ManualResumeFailure.deadlineWidened);
    });

    test('a mismatching uid fails closed', () async {
      final record = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
      );
      final outcome =
          await load(_FakeSecureStore(record.encode()), expectedUid: _otherUid);
      expect(outcome.failure, ManualResumeFailure.uidMismatch);
    });

    test('a session uid mismatch fails closed', () async {
      final record = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
        sessionUid: _otherUid,
      );
      final outcome = await load(_FakeSecureStore(record.encode()));
      expect(outcome.failure, ManualResumeFailure.sessionUidMismatch);
    });

    test('a session user id mismatch fails closed', () async {
      final record = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
        sessionUserId: _otherUid,
      );
      final outcome = await load(_FakeSecureStore(record.encode()));
      expect(outcome.failure, ManualResumeFailure.sessionUidMismatch);
    });

    test('a mismatching backend fails closed', () async {
      final record = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
        backendHost: 'other-backend.supabase.co',
      );
      final outcome = await load(_FakeSecureStore(record.encode()));
      expect(outcome.failure, ManualResumeFailure.backendMismatch);
    });

    test('a budget id outside the fixed task regex fails closed', () async {
      final record = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
        budgetId: 'planflow-guide-OTHER-20261021',
      );
      final outcome = await load(_FakeSecureStore(record.encode()));
      expect(outcome.failure, ManualResumeFailure.budgetMismatch);
    });

    test('an AI cap other than the QA ledger cap fails closed', () async {
      final record = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
        maxAiRequests: 5,
      );
      final outcome = await load(_FakeSecureStore(record.encode()));
      expect(outcome.failure, ManualResumeFailure.maxRequestsMismatch);
    });

    test('a missing dedicated opt-in fails closed', () async {
      final record = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
        dedicatedTestAccount: false,
      );
      final outcome = await load(_FakeSecureStore(record.encode()));
      expect(outcome.failure, ManualResumeFailure.dedicatedAccountMissing);
    });
  });

  group('manual cold resume (environment level)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('manual-resume-env');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<NativeGuideEnvironment> resume(_FakeSecureStore store) =>
        NativeGuideEnvironment.loadManualResume(
          store: store,
          now: now,
          expectedBackendHost: _backendHost,
          requireAndroidDirectoryPath: false,
        );

    test('a valid cold resume keeps uid, backend, budget and deadline',
        () async {
      final deadline = now.add(const Duration(minutes: 30));
      final record = _record(
        deadline: deadline,
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
      );
      final env = await resume(_FakeSecureStore(record.encode()));
      expect(env.uid, _uid);
      expect(env.host, _backendHost);
      expect(env.budgetId, _budgetId);
      expect(env.sessionDeadline, deadline);
      expect(env.runId, isNot(_originalRunId));
      expect(env.runId, matches(RegExp(r'^[a-zA-Z0-9_-]{8,64}$')));
      expect(env.runId.length, lessThanOrEqualTo(64));
    });

    test('every restart gets a new run id and never a new deadline', () async {
      final deadline = now.add(const Duration(minutes: 30));
      final record = _record(
        deadline: deadline,
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
      );
      final store = _FakeSecureStore(record.encode());
      final first = await resume(store);
      final second = await resume(store);
      expect(second.runId, isNot(first.runId));
      expect(first.sessionDeadline, deadline);
      expect(second.sessionDeadline, deadline);
      expect(
          second.sessionDeadline.isBefore(now.add(const Duration(minutes: 31))),
          isTrue);
    });

    test('an unusable secure store never starts a run', () async {
      final store = _FakeSecureStore(null)..failOnRead = true;
      await expectLater(
        resume(store),
        throwsA(isA<ManualResumeException>().having((e) => e.failure, 'failure',
            ManualResumeFailure.secureStorageUnavailable)),
      );
      expect(
        tmp.listSync().where((f) => f.path.contains('native-guide-')),
        isEmpty,
      );
    });

    test('an expired session writes nothing at all', () async {
      final record = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: now.subtract(const Duration(minutes: 1)),
        directoryPath: tmp.path,
      );
      await expectLater(
        resume(_FakeSecureStore(record.encode())),
        throwsA(isA<ManualResumeException>()),
      );
      expect(tmp.listSync(), isEmpty);
    });

    test('a missing ledger stays fail closed and is never created', () async {
      final record = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
      );
      final env = await resume(_FakeSecureStore(record.encode()));
      final ledger = File(budgetLedgerPath(tmp, _budgetId));
      expect(await ledger.exists(), isFalse);
      await expectLater(env.run<void>(() async {}), throwsA(anything));
      expect(await ledger.exists(), isFalse,
          reason: 'the ledger must never be auto-created or reset');
    });

    test('a corrupt ledger stays fail closed and keeps its bytes', () async {
      final record = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
      );
      final env = await resume(_FakeSecureStore(record.encode()));
      final ledger = File(budgetLedgerPath(tmp, _budgetId));
      await ledger.writeAsString('{"broken":true}');
      await expectLater(env.run<void>(() async {}), throwsA(anything));
      expect(await ledger.readAsString(), '{"broken":true}');
    });

    test('a valid ledger keeps its consumption across the cold resume',
        () async {
      final record = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
      );
      final ledger = File(budgetLedgerPath(tmp, _budgetId));
      await writeBudgetLedgerAtomic(
        file: ledger,
        snapshot: parseBudgetLedger(jsonEncode(<String, Object?>{
          'version': 1,
          'budgetId': _budgetId,
          'uid': _uid,
          'maxAiRequests': kLedgerMaxAiRequests,
          'aiRequests': 1,
          'usedPhases': <String>['create'],
          'createAttempted': true,
          'createdId': _uid,
        })),
      );
      final env = await resume(_FakeSecureStore(record.encode()));
      await env.run<void>(() async {
        expect(env.aiRequests, 1);
        expect(env.usedPhases, contains('create'));
        expect(env.createAttempted, isTrue);
        expect(env.createdId, _uid);
        // Manual QA runs allow phase reuse up to the shared ledger cap.
        expect(reasonForReserveAi(env.ledgerSnapshot, 'create'), isNull);
        expect(reasonForReserveAi(env.ledgerSnapshot, 'query'), isNull);
      });
      final after = await loadBudgetLedger(
        file: ledger,
        expectedBudgetId: _budgetId,
        expectedUid: _uid,
      );
      expect(after.aiRequests, 1);
      expect(after.usedPhases, <String>['create']);
    });

    test('a resumed run starts unarmed: no phase, no AI permit', () async {
      final record = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
      );
      final env = await resume(_FakeSecureStore(record.encode()));
      expect(env.phase, 'bootstrap');
      expect(env.permit.current, isFalse);
      expect(env.permit.reservations, 0);
      expect(env.verifiedUid, isFalse);
    });
  });

  group('manual CLOSE fail-closed ordering', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('manual-close-order');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<NativeGuideEnvironment> resumed() async {
      final record = _record(
        deadline: now.add(const Duration(minutes: 30)),
        tokenExpiry: tokenExpiry,
        directoryPath: tmp.path,
      );
      return NativeGuideEnvironment.loadManualResume(
        store: _FakeSecureStore(record.encode()),
        now: now,
        expectedBackendHost: _backendHost,
        requireAndroidDirectoryPath: false,
      );
    }

    test('latch precedes cleanup and the tree swap precedes the return',
        () async {
      final steps = <String>[];
      await runManualCloseSequence(
        latchEnvironment: () async {
          expect(steps, isEmpty, reason: 'the latch must be the first step');
          steps.add('latch');
        },
        writeClosedReply: () async {
          expect(steps, ['latch'],
              reason: 'harness cleanup must not run before the latch');
          steps.add('reply');
        },
        journalClosed: () async {
          expect(steps, ['latch', 'reply']);
          steps.add('journal');
        },
        paintClosedScreen: () {
          expect(steps, ['latch', 'reply', 'journal'],
              reason: 'the write-enabled tree must be replaced before run() '
                  'returns and lifts the fence');
          steps.add('screen');
        },
      );
      expect(steps, ['latch', 'reply', 'journal', 'screen']);
    });

    test('a real CLOSE latches the run and journals CLOSED inside the fence',
        () async {
      final env = await resumed();
      final ledger = File(budgetLedgerPath(tmp, _budgetId));
      await writeBudgetLedgerAtomic(
        file: ledger,
        snapshot: parseBudgetLedger(jsonEncode(<String, Object?>{
          'version': 1,
          'budgetId': _budgetId,
          'uid': _uid,
          'maxAiRequests': kLedgerMaxAiRequests,
          'aiRequests': 0,
          'usedPhases': <String>[],
          'createAttempted': false,
          'createdId': null,
        })),
      );
      var closedScreenShown = false;
      await env.run<void>(() async {
        await runManualCloseSequence(
          latchEnvironment: () async {
            env.failed = true;
          },
          writeClosedReply: () async {},
          journalClosed: () => env.journal('CLOSED'),
          paintClosedScreen: () => closedScreenShown = true,
        );
      });
      expect(env.failed, isTrue,
          reason: 'the run must stay latched after CLOSE');
      expect(closedScreenShown, isTrue,
          reason: 'the closed screen must be painted before run() returns');
      final journalPath = '${tmp.path}/native-guide-${env.runId}.json';
      // Cleanup clears config, but must retain the intentional terminal event.
      await env.close();
      final journal = jsonDecode(await File(journalPath).readAsString())
          as Map<String, dynamic>;
      expect(journal['event'], 'CLOSED');
      expect(journal['failed'], isTrue);
      expect(journal['aiRequests'], 0,
          reason: 'CLOSE must not touch the AI budget');
    });

    test('the sixth AI request is never forwarded and latches AI_CAP_EXCEEDED',
        () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final env = await resumed();
      final ledger = File(budgetLedgerPath(tmp, _budgetId));
      await writeBudgetLedgerAtomic(
        file: ledger,
        snapshot: parseBudgetLedger(jsonEncode({
          'version': 1,
          'budgetId': _budgetId,
          'uid': _uid,
          'maxAiRequests': kLedgerMaxAiRequests,
          'aiRequests': 5,
          'usedPhases': ['query'],
          'createAttempted': false,
          'createdId': null,
        })),
      );
      await Supabase.initialize(
        url: 'https://planflow-cap-test.invalid',
        anonKey: 'synthetic-anon-key',
        httpClient: MockClient((_) async {
          throw StateError('Unexpected Supabase auth transport');
        }),
        authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
          localStorage: EmptyLocalStorage(),
        ),
      );
      final expiry = DateTime.now().add(const Duration(hours: 1));
      final journalFile = File('${tmp.path}/native-guide-${env.runId}.json');
      final tripwire = _FenceTransportTripwire();
      final previousOverrides = HttpOverrides.current;
      try {
        await Supabase.instance.client.auth.recoverSession(jsonEncode({
          'access_token': _fakeToken(uid: _uid, expiry: expiry),
          'refresh_token': 'synthetic-refresh-token',
          'token_type': 'bearer',
          'expires_in': 3600,
          'user': {'id': _uid, 'aud': 'authenticated'},
        }));
        env.verifiedUid = true;
        env.phase = 'create';
        const session = 'test-session';
        final expiresAt = DateTime.utc(2030).toIso8601String();
        expect(env.permit.observe('begin_real_ui_guide', {}, {
          'status': 'granted',
          'session_id': session,
          'phase': 'create',
          'revision': 4,
          'expires_at': expiresAt,
        }, _uid, 'create'), isTrue);
        expect(env.permit.observe('authorize_real_ui_guide_operation', {
          'p_session_id': session,
          'p_phase': 'create',
          'p_revision': 4,
          'p_kind': 'scheduleParse',
          'p_operation': 'createParse',
          'p_operation_id': 'test-operation',
        }, {
          'status': 'granted',
          'grant_id': 'test-grant',
          'expires_at': expiresAt,
        }, _uid, 'create'), isTrue);

        HttpOverrides.global = tripwire;
        await env.run<void>(() async {
          final client = AppHttp.create();
          try {
            await expectLater(
              client.post(
                Uri.https(env.host, '/functions/v1/openai-proxy'),
                body: '{}',
              ),
              throwsStateError,
            );
            expect(env.failed, isTrue);
            expect(env.aiRequests, 5);
            await expectLater(
              client.get(Uri.https(env.host, '/auth/v1/user')),
              throwsStateError,
            );
            await env.journal('CLOSED');
          } finally {
            client.close();
          }
        });
      } finally {
        HttpOverrides.global = previousOverrides;
        await env.close();
      }
      expect(tripwire.attempts, 0);
      expect((await ledger.readAsString()), contains('"aiRequests":5'));
      final journal = jsonDecode(await journalFile.readAsString())
          as Map<String, dynamic>;
      expect(journal['event'], 'AI_CAP_EXCEEDED');
      expect(journal['failed'], isTrue);
      expect(journal['aiRequests'], 5);
      expect(
        journal['http'],
        contains(equals({
          'denyReason': 'ai_cap_exceeded',
          'forwarded': false,
        })),
      );
    });

    for (final scenario in <(String, List<String>, String)>[
      (
        'timeout survives cleanup',
        ['MANUAL_SESSION_TIMEOUT'],
        'MANUAL_SESSION_TIMEOUT'
      ),
      ('an error after CLOSED stays a failure', ['CLOSED', 'FAIL'], 'FAIL'),
    ]) {
      test(scenario.$1, () async {
        final env = await resumed();
        final ledger = File(budgetLedgerPath(tmp, _budgetId));
        await writeBudgetLedgerAtomic(
          file: ledger,
          snapshot: parseBudgetLedger(jsonEncode(<String, Object?>{
            'version': 1,
            'budgetId': _budgetId,
            'uid': _uid,
            'maxAiRequests': kLedgerMaxAiRequests,
            'aiRequests': 0,
            'usedPhases': <String>[],
            'createAttempted': false,
            'createdId': null,
          })),
        );
        final journalFile = File('${tmp.path}/native-guide-${env.runId}.json');
        await env.run<void>(() async {
          env.failed = true;
          for (final event in scenario.$2) {
            await env.journal(event);
          }
        });
        await env.close();
        final entry = jsonDecode(await journalFile.readAsString())
            as Map<String, dynamic>;
        expect(entry['event'], scenario.$3);
        expect(entry['failed'], isTrue);
        expect(entry['aiRequests'], 0);
        expect((await ledger.readAsString()), contains('"aiRequests":0'));
      });
    }

    testWidgets(
        'the closed screen replaces the write-enabled tree and stays '
        'noninteractive', (tester) async {
      await tester.pumpWidget(const _WriteEnabledDummy());
      expect(find.text('WRITE-ENABLED OLD UI'), findsOneWidget);
      await runManualCloseSequence(
        latchEnvironment: () async {},
        writeClosedReply: () async {},
        journalClosed: () async {},
        paintClosedScreen: () =>
            runApp(const GuideQaRecoveryApp(reason: 'closed-for-test')),
      );
      await tester.pump();
      expect(find.byType(_WriteEnabledDummy), findsNothing);
      expect(find.byType(GuideQaRecoveryApp), findsOneWidget);
      expect(find.byType(EditableText), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(ElevatedButton), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(GestureDetector), findsNothing);
      expect(find.byType(InkWell), findsNothing);
    });
  });

  group('manual startup waiting view', () {
    testWidgets('paints QA 연결 확인 중 first, then recovery on loader failure',
        (tester) async {
      final completer = Completer<NativeGuideEnvironment>();
      var loaderCalls = 0;
      final startup = awaitManualGuideEnvironment(() async {
        loaderCalls++;
        return completer.future;
      });
      await tester.pump();
      expect(find.text('QA 연결 확인 중'), findsOneWidget);
      expect(find.byType(GuideQaStartupApp), findsOneWidget);
      expect(find.byType(GuideQaRecoveryApp), findsNothing);
      expect(find.byType(EditableText), findsNothing);
      expect(find.byType(GestureDetector), findsNothing);
      // The loader stays pending: only the waiting view is visible. Fixed
      // pumps only, never an endOfFrame/pumpAndSettle wait that could hang
      // while background frames are disabled.
      expect(loaderCalls, 1);

      completer.completeError(StateError('Runtime missing'));
      final env = await startup;
      await tester.pump();
      expect(env, isNull);
      expect(find.byType(GuideQaStartupApp), findsNothing);
      expect(find.byType(GuideQaRecoveryApp), findsOneWidget);
      expect(find.textContaining('could not be restored'), findsOneWidget);
    });
  });
}

class _WriteEnabledDummy extends StatelessWidget {
  const _WriteEnabledDummy();

  @override
  Widget build(BuildContext context) => const Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: Color(0xFF202830),
          child: Center(child: Text('WRITE-ENABLED OLD UI')),
        ),
      );
}
