// Manual cold-relaunch resume support for the native real-UI guide QA.
//
// SCOPE: MANUAL (operator driven) runs only. The default automated
// `NativeGuideEnvironment.load()` one-use runtime path is NOT changed here.
//
// SECURITY: the recovered session and the bounded manual policy are persisted
// only through flutter_secure_storage (Android encryptedSharedPreferences,
// the same options the production app already uses). No raw access/refresh
// token is written to shared preferences, to the app-private journal, to the
// logs or to any backup, and no failure reason carries a credential.
//
// FAIL CLOSED: every unusable, missing, expired or mismatching state maps to
// a credential-free [ManualResumeFailure] code so the manual entry point can
// paint an actionable recovery screen instead of waiting on a native splash.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'native_guide_budget_ledger.dart';

/// Schema version of the persisted resume record. A mismatch fails closed.
const int kManualResumeVersion = 1;

/// Secure-storage key. Bumping it invalidates every stored record.
const String kManualResumeStorageKey = 'planflow_guide_qa_manual_resume_v1';

/// The manual session window of a fresh run. The effective deadline is
/// `min(sessionStart + window, access token expiry)`.
const Duration kNativeGuideManualSessionWindow = Duration(minutes: 30);

/// The AI cap of the manual run. Manual QA runs are intentionally
/// unlimited within the durable ledger contract; any other value fails closed.
const int kManualResumeMaxAiRequests = kLedgerMaxAiRequests;

/// Upper bound of the whole persisted record (characters).
const int kManualResumeMaxRecordChars = 32768;

/// Upper bound of a single bearer token (characters).
const int kManualResumeMaxTokenChars = 8192;

/// Credential-free failure codes for the manual resume path.
enum ManualResumeFailure {
  secureStorageUnavailable('secure-storage-unavailable'),
  recordMissing('resume-record-missing'),
  recordCorrupt('resume-record-corrupt'),
  uidMismatch('uid-mismatch'),
  backendMismatch('backend-mismatch'),
  budgetMismatch('budget-mismatch'),
  maxRequestsMismatch('max-ai-requests-mismatch'),
  dedicatedAccountMissing('dedicated-account-missing'),
  sessionMissing('session-missing'),
  sessionExpired('session-expired'),
  sessionUidMismatch('session-uid-mismatch'),
  deadlineExpired('deadline-expired'),
  deadlineWidened('deadline-widened');

  const ManualResumeFailure(this.code);

  /// Stable, credential-free code. Safe to show on a recovery screen.
  final String code;
}

/// Raised when the resume state cannot be used. Carries only a failure code
/// and an optional credential-free detail.
class ManualResumeException implements Exception {
  ManualResumeException(this.failure, [this.detail]);

  final ManualResumeFailure failure;

  /// Credential-free detail (shape or platform reason only).
  final String? detail;

  String get code => failure.code;

  @override
  String toString() =>
      'ManualResumeException(${failure.code}${detail == null ? '' : ': $detail'})';
}

/// The bounded manual policy persisted next to the session.
class ManualResumePolicy {
  const ManualResumePolicy({
    required this.uid,
    required this.backendHost,
    required this.budgetId,
    required this.maxAiRequests,
    required this.dedicatedTestAccount,
    required this.originalRunId,
    required this.deadline,
    required this.tokenExpiry,
    required this.directoryPath,
  });

  final String uid;
  final String backendHost;
  final String budgetId;
  final int maxAiRequests;
  final bool dedicatedTestAccount;

  /// Run id of the original (fresh) run. A resume never reuses it.
  final String originalRunId;

  /// Absolute deadline. A restart never extends it.
  final DateTime deadline;

  /// Access token expiry of the persisted session.
  final DateTime tokenExpiry;

  /// App-private directory that holds the durable budget ledger.
  final String directoryPath;

  Map<String, Object?> toJson() => <String, Object?>{
        'uid': uid,
        'backendHost': backendHost,
        'budgetId': budgetId,
        'maxAiRequests': maxAiRequests,
        'dedicatedTestAccount': dedicatedTestAccount,
        'originalRunId': originalRunId,
        'deadlineMs': deadline.millisecondsSinceEpoch,
        'tokenExpiryMs': tokenExpiry.millisecondsSinceEpoch,
        'directoryPath': directoryPath,
      };

  static ManualResumePolicy fromJson(Map<String, Object?> json) {
    const keys = <String>{
      'uid',
      'backendHost',
      'budgetId',
      'maxAiRequests',
      'dedicatedTestAccount',
      'originalRunId',
      'deadlineMs',
      'tokenExpiryMs',
      'directoryPath',
    };
    if (json.keys.toSet().difference(keys).isNotEmpty ||
        keys.any((k) => !json.containsKey(k))) {
      throw ManualResumeException(
          ManualResumeFailure.recordCorrupt, 'policy shape');
    }
    final uid = json['uid'];
    final backendHost = json['backendHost'];
    final budgetId = json['budgetId'];
    final maxAiRequests = json['maxAiRequests'];
    final dedicated = json['dedicatedTestAccount'];
    final originalRunId = json['originalRunId'];
    final deadlineMs = json['deadlineMs'];
    final tokenExpiryMs = json['tokenExpiryMs'];
    final directoryPath = json['directoryPath'];
    if (uid is! String ||
        backendHost is! String ||
        budgetId is! String ||
        maxAiRequests is! int ||
        dedicated is! bool ||
        originalRunId is! String ||
        deadlineMs is! int ||
        tokenExpiryMs is! int ||
        directoryPath is! String) {
      throw ManualResumeException(
          ManualResumeFailure.recordCorrupt, 'policy types');
    }
    if (uid.length > 64 ||
        backendHost.length > 255 ||
        budgetId.length > 64 ||
        originalRunId.length > 64 ||
        directoryPath.length > 512) {
      throw ManualResumeException(
          ManualResumeFailure.recordCorrupt, 'policy bounds');
    }
    return ManualResumePolicy(
      uid: uid,
      backendHost: backendHost,
      budgetId: budgetId,
      maxAiRequests: maxAiRequests,
      dedicatedTestAccount: dedicated,
      originalRunId: originalRunId,
      deadline: DateTime.fromMillisecondsSinceEpoch(deadlineMs, isUtc: true),
      tokenExpiry:
          DateTime.fromMillisecondsSinceEpoch(tokenExpiryMs, isUtc: true),
      directoryPath: directoryPath,
    );
  }
}

/// The persisted resume state: bounded policy + the recovered session.
class ManualResumeRecord {
  const ManualResumeRecord({
    required this.policy,
    required this.session,
    required this.anonKey,
  });

  final ManualResumePolicy policy;

  /// Supabase session map (access token, refresh token, user).
  final Map<String, dynamic> session;

  /// Publishable anon key of the approved backend.
  final String anonKey;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': kManualResumeVersion,
        'policy': policy.toJson(),
        'session': session,
        'anonKey': anonKey,
      };

  String encode() => jsonEncode(toJson());

  static ManualResumeRecord decode(String raw) {
    if (raw.length > kManualResumeMaxRecordChars) {
      throw ManualResumeException(
          ManualResumeFailure.recordCorrupt, 'record too large');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw ManualResumeException(
          ManualResumeFailure.recordCorrupt, 'record json');
    }
    if (decoded is! Map) {
      throw ManualResumeException(
          ManualResumeFailure.recordCorrupt, 'record root');
    }
    final map = Map<String, Object?>.from(decoded);
    const allowed = <String>{'version', 'policy', 'session', 'anonKey'};
    if (map.keys.toSet().difference(allowed).isNotEmpty ||
        allowed.any((k) => !map.containsKey(k)) ||
        map['version'] != kManualResumeVersion ||
        map['policy'] is! Map ||
        map['session'] is! Map ||
        map['anonKey'] is! String) {
      throw ManualResumeException(
          ManualResumeFailure.recordCorrupt, 'record shape');
    }
    final session = Map<String, dynamic>.from(map['session'] as Map);
    final anonKey = map['anonKey'] as String;
    if (anonKey.length > 4096) {
      throw ManualResumeException(
          ManualResumeFailure.recordCorrupt, 'anon key bounds');
    }
    return ManualResumeRecord(
      policy: ManualResumePolicy.fromJson(
          Map<String, Object?>.from(map['policy'] as Map)),
      session: session,
      anonKey: anonKey,
    );
  }
}

/// Result of a manual resume attempt.
class ManualResumeOutcome {
  const ManualResumeOutcome.success(ManualResumeRecord this.record)
      : failure = null;
  const ManualResumeOutcome.failed(ManualResumeFailure this.failure)
      : record = null;

  final ManualResumeRecord? record;
  final ManualResumeFailure? failure;

  bool get isSuccess => record != null;
}

/// Minimal secure storage contract. The production implementation uses
/// flutter_secure_storage; tests use an in-memory double.
abstract class SecureResumeStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

/// Production adapter: flutter_secure_storage with the Android options the
/// app already uses for the auth session backup.
class FlutterSecureResumeStore implements SecureResumeStore {
  FlutterSecureResumeStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
                resetOnError: false,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (error) {
      throw ManualResumeException(ManualResumeFailure.secureStorageUnavailable,
          error.runtimeType.toString());
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (error) {
      throw ManualResumeException(ManualResumeFailure.secureStorageUnavailable,
          error.runtimeType.toString());
    }
  }
}

/// Reads and writes the manual resume record.
class ManualResumeService {
  ManualResumeService({required SecureResumeStore store, String? key})
      : _store = store,
        _key = key ?? kManualResumeStorageKey;

  final SecureResumeStore _store;
  final String _key;

  /// Persists the record. Any storage failure fails closed.
  Future<void> save(ManualResumeRecord record) async {
    final raw = record.encode();
    if (raw.length > kManualResumeMaxRecordChars) {
      throw ManualResumeException(
          ManualResumeFailure.recordCorrupt, 'record too large');
    }
    await _store.write(_key, raw);
  }

  /// Loads and validates the record. A missing record is a failure value, an
  /// unusable storage is an exception; neither ever waits.
  Future<ManualResumeOutcome> load({
    required DateTime now,
    required String expectedBackendHost,
    String? expectedUid,
    bool requireAndroidDirectoryPath = true,
  }) async {
    final String? raw;
    try {
      raw = await _store.read(_key);
    } on ManualResumeException {
      rethrow;
    } catch (error) {
      throw ManualResumeException(ManualResumeFailure.secureStorageUnavailable,
          error.runtimeType.toString());
    }
    if (raw == null || raw.trim().isEmpty) {
      return const ManualResumeOutcome.failed(
          ManualResumeFailure.recordMissing);
    }
    return validateManualResumeRecord(
      raw: raw,
      now: now,
      expectedBackendHost: expectedBackendHost,
      expectedUid: expectedUid,
      requireAndroidDirectoryPath: requireAndroidDirectoryPath,
    );
  }
}

/// Startup mode of the manual entry point.
enum ManualStartupMode {
  /// Default one-use path: wait for the runtime file and consume it once.
  freshOneUse,

  /// Manual cold relaunch: restore the persisted session, never wait.
  manualResume,
}

/// Pure startup decision of the manual entry point.
///
/// * [forceResume] is the explicit manual opt-in (compile-time define).
/// * [runtimeFilePresent] tells whether the one-use runtime file exists now.
/// * [consumedMarkerPresent] tells whether a previous fresh start already
///   consumed that runtime file. Only then is a missing runtime file proof of
///   a cold relaunch instead of a first start.
ManualStartupMode decideManualStartupMode({
  required bool forceResume,
  required bool runtimeFilePresent,
  required bool consumedMarkerPresent,
}) {
  if (forceResume) return ManualStartupMode.manualResume;
  if (consumedMarkerPresent && !runtimeFilePresent) {
    return ManualStartupMode.manualResume;
  }
  return ManualStartupMode.freshOneUse;
}

/// Marker file name written next to the consumed one-use runtime file. Its
/// presence proves that a previous fresh start already consumed the runtime
/// file, so a missing runtime file means a cold relaunch, not a first start.
const String kConsumedRuntimeMarkerName = 'guide-qa-runtime-consumed.json';

/// True only for a POSIX path inside the canonical Android app-private
/// `files` tree of the current UID: `/data/user/0/<package>/files` with
/// optional further segments below it.
///
/// Pure string shape only (no host `dart:io` normalization), so it reads the
/// same on Windows hosts and on the device. It accepts the real persisted
/// app-private directory that ENDS with `/files` (no trailing segment) as
/// well as anything nested below `files/`. It rejects a relative path,
/// `/data/user/1/...`, `/data/data/...`, external storage, every `..`
/// segment, `.` segments, non-POSIX backslashes, doubled slashes, a trailing
/// slash and look-alikes such as `filesx` or `files-extra`.
bool isAndroidAppPrivateFilesPath(String path) {
  if (path.isEmpty) return false;
  if (!path.startsWith(kAndroidAppPrivateRoot)) return false;
  if (path.contains('..')) return false;
  if (path.contains('\\')) return false;
  if (path.contains('//')) return false;
  final afterRoot = path.substring(kAndroidAppPrivateRoot.length);
  if (afterRoot.isEmpty) return false;
  final segments = afterRoot.split('/');
  // [<package>, 'files', ...optional deeper segments]
  if (segments.length < 2) return false;
  if (segments[0].isEmpty || segments[0] == '.') return false;
  if (segments[1] != 'files') return false;
  if (segments.any((s) => s.isEmpty || s == '.')) return false;
  return true;
}

/// Canonical Android app-private root of the current (owner) UID.
const String kAndroidAppPrivateRoot = '/data/user/0/';

/// POSIX-absolute shape of a device path. `dart:io` judges absoluteness with
/// the HOST style, so a Windows host calls `/data/user/0/...` relative and
/// would fail a genuine device record closed. This pure check keeps the
/// validator faithful to the on-device shape without normalizing the string.
bool isPosixAbsolutePath(String path) => path.startsWith('/');

/// Pure, host-independent locator of the consumed-marker file path for a
/// configured one-use runtime path.
///
/// The runtime path is an Android app-private POSIX path
/// (`/data/user/0/<package>/files/<file>`). This helper works on the raw
/// string only, so host `dart:io` path normalization (e.g. Windows
/// backslash parents in unit tests) can never mask the real on-device
/// shape. It accepts the real default runtime path whose directory ends
/// with `/files` (no trailing segment) as well as files nested deeper
/// under `files/`, mirroring the one-use loader's own acceptance guard
/// (`/data/user/0/` prefix, inside `files/`, no `..`). It rejects paths
/// outside `/data/user/0/`, anything outside the `files` tree (cache,
/// databases, shared_prefs, external storage), every `..` segment,
/// non-POSIX separators, doubled slashes and paths without a file name.
/// Returns `null` for every rejected path; the caller then simply has no
/// marker hint.
String? consumedMarkerPathForRuntime(String runtimePath) {
  if (!isAndroidAppPrivateFilesPath(runtimePath)) return null;
  // A file name must follow the `/files` directory itself.
  if (runtimePath.endsWith('/files')) return null;
  final slash = runtimePath.lastIndexOf('/');
  return '${runtimePath.substring(0, slash)}/$kConsumedRuntimeMarkerName';
}

/// True only for the one-use load failure that means "the runtime file
/// never appeared within its wait window" (`StateError('Runtime missing')`).
/// The manual entry point uses it to gate the narrow missing-marker
/// fallback to the validated secure resume; every other fresh-load
/// failure stays fail-closed with its original error.
bool isRuntimeMissingTimeout(Object error) =>
    error is StateError && error.message == 'Runtime missing';

/// Effective deadline of a fresh run: the earlier of the session window and
/// the access token expiry. A restart never extends it.
DateTime computeManualResumeDeadline({
  required DateTime sessionStartedAt,
  required DateTime tokenExpiry,
  Duration sessionWindow = kNativeGuideManualSessionWindow,
}) {
  final windowEnd = sessionStartedAt.add(sessionWindow);
  return tokenExpiry.isBefore(windowEnd) ? tokenExpiry : windowEnd;
}

/// Extracts the access token expiry from the session claims.
DateTime? manualResumeTokenExpiry(Map<String, dynamic> session) {
  final token = session['access_token'];
  if (token is! String ||
      token.isEmpty ||
      token.length > kManualResumeMaxTokenChars) {
    return null;
  }
  final parts = token.split('.');
  if (parts.length < 2) return null;
  try {
    final claims =
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
            as Map<String, dynamic>;
    final exp = claims['exp'];
    if (exp is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch((exp * 1000).round(),
        isUtc: true);
  } catch (_) {
    return null;
  }
}

/// Pure validation of a persisted record. Returns the first failure code.
ManualResumeOutcome validateManualResumeRecord({
  required String raw,
  required DateTime now,
  required String expectedBackendHost,
  String? expectedUid,
  bool requireAndroidDirectoryPath = true,
}) {
  ManualResumeRecord record;
  try {
    record = ManualResumeRecord.decode(raw);
  } on ManualResumeException catch (error) {
    return ManualResumeOutcome.failed(error.failure);
  }
  final policy = record.policy;

  if (!kUidRegex.hasMatch(policy.uid)) {
    return const ManualResumeOutcome.failed(ManualResumeFailure.uidMismatch);
  }
  if (expectedUid != null && expectedUid != policy.uid) {
    return const ManualResumeOutcome.failed(ManualResumeFailure.uidMismatch);
  }
  if (policy.backendHost != expectedBackendHost) {
    return const ManualResumeOutcome.failed(
        ManualResumeFailure.backendMismatch);
  }
  if (!kBudgetIdRegex.hasMatch(policy.budgetId)) {
    return const ManualResumeOutcome.failed(ManualResumeFailure.budgetMismatch);
  }
  if (policy.maxAiRequests != kManualResumeMaxAiRequests) {
    return const ManualResumeOutcome.failed(
        ManualResumeFailure.maxRequestsMismatch);
  }
  if (!policy.dedicatedTestAccount) {
    return const ManualResumeOutcome.failed(
        ManualResumeFailure.dedicatedAccountMissing);
  }
  if (!RegExp(r'^[a-zA-Z0-9_-]{8,64}$').hasMatch(policy.originalRunId)) {
    return const ManualResumeOutcome.failed(ManualResumeFailure.recordCorrupt);
  }
  if (policy.directoryPath.isEmpty ||
      !(isPosixAbsolutePath(policy.directoryPath) ||
          Directory(policy.directoryPath).isAbsolute) ||
      policy.directoryPath.contains('..')) {
    return const ManualResumeOutcome.failed(ManualResumeFailure.recordCorrupt);
  }
  if (requireAndroidDirectoryPath &&
      !isAndroidAppPrivateFilesPath(policy.directoryPath)) {
    return const ManualResumeOutcome.failed(ManualResumeFailure.recordCorrupt);
  }
  // The deadline may never be pushed forward, and it may never outlive the
  // access token of the persisted session.
  if (!policy.deadline.isAfter(now)) {
    return const ManualResumeOutcome.failed(
        ManualResumeFailure.deadlineExpired);
  }
  if (!policy.tokenExpiry.isAfter(now)) {
    return const ManualResumeOutcome.failed(ManualResumeFailure.sessionExpired);
  }
  if (policy.deadline.isAfter(policy.tokenExpiry)) {
    return const ManualResumeOutcome.failed(
        ManualResumeFailure.deadlineWidened);
  }
  // banned-ok: Computes expiry from the runtime session.
  final tokenExpiry = manualResumeTokenExpiry(record.session);
  if (tokenExpiry == null) {
    return const ManualResumeOutcome.failed(ManualResumeFailure.sessionMissing);
  }
  if (!tokenExpiry.isAfter(now)) {
    return const ManualResumeOutcome.failed(ManualResumeFailure.sessionExpired);
  }
  if (tokenExpiry.millisecondsSinceEpoch !=
      policy.tokenExpiry.millisecondsSinceEpoch) {
    return const ManualResumeOutcome.failed(
        ManualResumeFailure.deadlineWidened);
  }
  // banned-ok: Reads a field from the runtime session.
  final accessToken = record.session['access_token'];
  if (accessToken is! String ||
      accessToken.isEmpty ||
      accessToken.length > kManualResumeMaxTokenChars) {
    return const ManualResumeOutcome.failed(ManualResumeFailure.sessionMissing);
  }
  try {
    final parts = accessToken.split('.');
    final claims =
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
            as Map<String, dynamic>;
    if (claims['sub'] != policy.uid) {
      return const ManualResumeOutcome.failed(
          ManualResumeFailure.sessionUidMismatch);
    }
  } catch (_) {
    return const ManualResumeOutcome.failed(ManualResumeFailure.sessionMissing);
  }
  final user = record.session['user'];
  if (user is! Map || user['id'] != policy.uid) {
    return const ManualResumeOutcome.failed(
        ManualResumeFailure.sessionUidMismatch);
  }
  return ManualResumeOutcome.success(record);
}
