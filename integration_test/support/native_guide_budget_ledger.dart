// Pure helper for the bounded test-only AI/event-create ledger. No HTTP, no DB,
// no Flutter binding; safe to import from the harness and from unit tests.
//
// Contract (parent-owned):
//   * runtime config adds budgetId='planflow-guide-FRM9-20261021' as the
//     fixed task identifier; this helper validates the format.
//   * parent provisions ${directory.path}/native-guide-budget-${budgetId}.json
//     exactly once after AI0 journals; this code never auto-creates the file.
//   * under an existing exclusive run lock, call `loadBudgetLedger` to read
//     and validate. wrong id/uid/max/unknown values/corruption/missing =>
//     fail closed.
//   * `writeBudgetLedgerAtomic` is the only persistence path: temp write +
//     flush + rename. if the rename (or any prior step) fails, the caller
//     must fail closed.
//   * on run failure/close, the helper never resets or deletes the ledger.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Canonical regex for the fixed QA task id. Accepts the historical example
/// `planflow-guide-FRM9-20261021` and any same-shape future id; rejects any
/// other shape and any extra characters.
final RegExp kBudgetIdRegex = RegExp(r'^planflow-guide-FRM9-([0-9]{4,8})$');

/// Allowed AI phase strings. Any other value in `usedPhases` fails closed.
const Set<String> kAllowedAiPhases = {'create', 'query', 'change'};

/// Canonical expected UID format (RFC 4122 hex with hyphens, case insensitive).
final RegExp kUidRegex = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// Schema version this helper understands. Mismatch => fail closed.
const int kLedgerVersion = 1;

/// Cap on AI reservations per budget lifetime. Hard-coded by the contract; the
/// loader rejects any other value.
/// 사용자 전용 QA 앱이라 AI 호출 횟수 제한을 두지 않는다.
const int kLedgerMaxAiRequests = 1000000;

class BudgetLedgerSnapshot {
  const BudgetLedgerSnapshot({
    required this.budgetId,
    required this.uid,
    required this.aiRequests,
    this.maxAiRequests = kLedgerMaxAiRequests,
    required this.usedPhases,
    required this.createAttempted,
    required this.createdId,
  });

  /// Caller-side helper: produces a brand-new snapshot with no consumption.
  /// Used only when a parent script needs to mint an initial json externally;
  /// this file never auto-creates anything on disk.
  static BudgetLedgerSnapshot initial({
    required String budgetId,
    required String uid,
  }) {
    return BudgetLedgerSnapshot(
      budgetId: budgetId,
      uid: uid,
      aiRequests: 0,
      maxAiRequests: kLedgerMaxAiRequests,
      usedPhases: const <String>[],
      createAttempted: false,
      createdId: null,
    );
  }

  final String budgetId;
  final String uid;
  final int aiRequests;
  final int maxAiRequests;
  final List<String> usedPhases;
  final bool createAttempted;
  final String? createdId;

  BudgetLedgerSnapshot copyWith({
    int? aiRequests,
    int? maxAiRequests,
    List<String>? usedPhases,
    bool? createAttempted,
    String? createdId,
    bool clearCreatedId = false,
  }) {
    return BudgetLedgerSnapshot(
      budgetId: budgetId,
      uid: uid,
      aiRequests: aiRequests ?? this.aiRequests,
      maxAiRequests: maxAiRequests ?? this.maxAiRequests,
      usedPhases: usedPhases ?? this.usedPhases,
      createAttempted: createAttempted ?? this.createAttempted,
      createdId: clearCreatedId ? null : (createdId ?? this.createdId),
    );
  }

  /// Map form strictly equals the documented schema. No extra keys emitted;
  /// missing keys would fail the loader so all are required here.
  Map<String, Object?> toJson() => <String, Object?>{
        'version': kLedgerVersion,
        'budgetId': budgetId,
        'uid': uid,
        'maxAiRequests': maxAiRequests,
        'aiRequests': aiRequests,
        'usedPhases': usedPhases,
        'createAttempted': createAttempted,
        'createdId': createdId,
      };

  String encode() => jsonEncode(toJson());
}

/// Pure parse + validate. Throws [FormatException] describing the first
/// failure; any failure must be treated as fail-closed by the caller.
BudgetLedgerSnapshot parseBudgetLedger(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    throw FormatException('ledger json invalid: ${e.message}');
  }
  if (decoded is! Map) {
    throw const FormatException('ledger root must be object');
  }
  final map = decoded;

  // Exact schema: reject any extra keys.
  const allowedKeys = <String>{
    'version',
    'budgetId',
    'uid',
    'maxAiRequests',
    'aiRequests',
    'usedPhases',
    'createAttempted',
    'createdId',
  };
  final extra = map.keys.where((k) => !allowedKeys.contains(k)).toList();
  if (extra.isNotEmpty) {
    throw FormatException('ledger has unknown keys: ${extra.join(',')}');
  }
  for (final k in allowedKeys) {
    if (!map.containsKey(k)) {
      throw FormatException('ledger missing required key: $k');
    }
  }

  final version = map['version'];
  if (version is! int || version != kLedgerVersion) {
    throw FormatException('ledger version must equal $kLedgerVersion');
  }

  final budgetId = map['budgetId'];
  if (budgetId is! String || !kBudgetIdRegex.hasMatch(budgetId)) {
    throw const FormatException('ledger budgetId failed regex');
  }

  final uid = map['uid'];
  if (uid is! String || !kUidRegex.hasMatch(uid)) {
    throw const FormatException('ledger uid failed UUID regex');
  }

  final maxAiRequests = map['maxAiRequests'];
  // 원장마다 상한을 직접 선언한다(사용자 전용 QA 앱은 사실상 무제한).
  if (maxAiRequests is! int || maxAiRequests < 1) {
    throw const FormatException('ledger maxAiRequests must be a positive int');
  }

  final aiRequests = map['aiRequests'];
  if (aiRequests is! int || aiRequests < 0 || aiRequests > maxAiRequests) {
    throw FormatException('ledger aiRequests out of range [0, $maxAiRequests]');
  }

  final usedPhasesRaw = map['usedPhases'];
  if (usedPhasesRaw is! List) {
    throw const FormatException('ledger usedPhases must be list');
  }
  final usedPhases = <String>[];
  for (final entry in usedPhasesRaw) {
    if (entry is! String ||
        !kAllowedAiPhases.contains(entry) ||
        usedPhases.contains(entry)) {
      throw FormatException('ledger usedPhases invalid entry: $entry');
    }
    usedPhases.add(entry);
  }
  // 같은 단계를 여러 번 쓸 수 있으므로 usedPhases 는 aiRequests 보다 작을 수 있다.
  if (usedPhases.length > aiRequests) {
    throw FormatException(
        'ledger usedPhases length ${usedPhases.length} exceeds aiRequests $aiRequests');
  }

  final createAttempted = map['createAttempted'];
  if (createAttempted is! bool) {
    throw const FormatException('ledger createAttempted must be bool');
  }

  final createdIdRaw = map['createdId'];
  String? createdId;
  if (createdIdRaw != null) {
    if (createdIdRaw is! String ||
        createdIdRaw.isEmpty ||
        !kUidRegex.hasMatch(createdIdRaw)) {
      throw FormatException('ledger createdId invalid: $createdIdRaw');
    }
    createdId = createdIdRaw;
  }
  // Hard contract: persistent createAttempted=true with unknown id forbids
  // any retry; we do not normalize that state away here.
  if (createAttempted && createdId == null) {
    // Allowed by schema as a fail-closed signal.
  }
  // Inconsistent corrupted state: an event id without a corresponding
  // reservation cannot be honored. Refuse the whole ledger.
  if (createdId != null && !createAttempted) {
    throw const FormatException(
        'ledger createdId set while createAttempted=false; corrupted state');
  }

  return BudgetLedgerSnapshot(
    budgetId: budgetId,
    uid: uid,
    aiRequests: aiRequests,
    maxAiRequests: maxAiRequests,
    usedPhases: List<String>.unmodifiable(usedPhases),
    createAttempted: createAttempted,
    createdId: createdId,
  );
}

/// Filesystem path helper. Kept pure-ish so the loader can be tested against
/// `Directory.systemTemp.createTempSync()`.
String budgetLedgerPath(Directory directory, String budgetId) =>
    '${directory.path}/native-guide-budget-$budgetId.json';

/// Read and validate. Any failure => throws; the caller fails closed.
///
/// [expectedBudgetId] must match the runtime config's budget id field. The
/// regex already validates shape; we additionally reject any id that does not
/// equal the expected exact string.
Future<BudgetLedgerSnapshot> loadBudgetLedger({
  required File file,
  required String expectedBudgetId,
  required String expectedUid,
}) async {
  if (!await file.exists()) {
    throw const FormatException(
        'ledger file missing; parent must provision once');
  }
  final size = await file.length();
  if (size <= 0 || size > 8192) {
    throw FormatException('ledger file size invalid: $size');
  }
  final text = await file.readAsString();
  final snap = parseBudgetLedger(text);
  if (snap.budgetId != expectedBudgetId) {
    throw FormatException(
        'ledger budgetId mismatch: ${snap.budgetId} != $expectedBudgetId');
  }
  if (snap.uid != expectedUid) {
    throw FormatException('ledger uid mismatch: ${snap.uid} != $expectedUid');
  }
  return snap;
}

/// Atomic durable write: temp file -> flush -> rename onto target. On any
/// failure, the target file is left untouched and the exception bubbles; the
/// caller must fail closed. Caller is responsible for holding the run lock.
Future<void> writeBudgetLedgerAtomic({
  required File file,
  required BudgetLedgerSnapshot snapshot,
}) async {
  // Validate again before persisting; in-memory snapshots are trusted but
  // pinned here so a corrupt re-serialization cannot slip through.
  parseBudgetLedger(snapshot.encode());

  final parent = file.parent;
  if (!await parent.exists()) {
    throw const FileSystemException('ledger parent directory missing');
  }

  // Process id is available via dart:io; suffix the temp file with it plus
  // microsecond timestamp to avoid name collisions across same-process writers.
  final idSuffix = '$pid-${DateTime.now().microsecondsSinceEpoch}';
  final tmpPath = '${file.path}.tmp.$idSuffix';
  final tmp = File(tmpPath);

  try {
    final raf = await tmp.open(mode: FileMode.write);
    try {
      await raf.writeString(snapshot.encode());
      await raf.flush();
    } finally {
      await raf.close();
    }
    // Rename is the atomic step. dart:io `rename` over an existing target
    // replaces the destination on POSIX and on Windows when same-volume.
    await tmp.rename(file.path);
  } finally {
    // Best-effort cleanup if rename failed.
    if (await tmp.exists()) {
      try {
        await tmp.delete();
      } on FileSystemException {
        // Lock holder will deal with any straggler.
      }
    }
  }
}

/// Restricted set of read tables for the harness. Deny by default.
const Set<String> kAllowedReadTables = {'events', 'user_settings', 'users'};

/// Exact wire shapes of the SupabaseVoiceCorrectionRuleGateway reads
/// (R2 audit JX9aD8bqcYuRzpoQ). These are exact read-contract branches, NOT
/// blanket allowlist entries: any deviation from the gateway's query is a
/// deny. GET-only is enforced by the environment; POST/PATCH/DELETE on these
/// tables stay fatal there (they never reach [readTableReason]).
const String kVoicePersonalRuleTable = 'voice_correction_rules';
const String kVoiceCommonRuleTable = 'voice_common_correction_rules';
const String kVoicePersonalRuleSelect = 'id, user_id, stage, field_name, '
    'from_text, to_text, context_before, context_after, confidence_count, '
    'reject_count, enabled, is_sensitive, created_at, updated_at';
const String kVoiceCommonRuleSelect = 'id, stage, field_name, from_text, '
    'to_text, context_before, context_after, support_count, conflict_count, '
    'confidence_score, enabled, created_at, updated_at';

/// supabase-dart은 select를 쉼표 뒤 공백 없이 보낸다.
/// 같은 컴럼 집합인지만 보고, 공백 차이로 차단하지 않는다.
String _compactSelect(String? value) =>
    (value ?? '').replaceAll(RegExp(r'\s+'), '');

/// order는 클라이언트 버전에 따라 nulls last/first 접미가 붙는다.
bool _sameOrder(String? actual, String expected) {
  if (actual == expected) {
    return true;
  }
  return actual == '$expected.nullslast' || actual == '$expected.nullsfirst';
}

bool _sameQueryKeys(Iterable<String> keys, Set<String> expected) =>
    keys.length == expected.length && keys.every(expected.contains);

/// Personal rules: exact fetchPersonalRules wire only — pinned projection,
/// user_id=eq.<own uid>, enabled=eq.true, order=confidence_count.desc,
/// limit=200. Missing/cross uid, select *, extra keys, wrong filters/order/
/// limit are all denies.
String? _personalRuleReadReason(Map<String, String> query, String uid) {
  const expected = <String>{'select', 'user_id', 'enabled', 'order', 'limit'};
  if (!_sameQueryKeys(query.keys, expected)) {
    return 'voice_correction_rules read must use exactly '
        'select/user_id/enabled/order/limit';
  }
  if (_compactSelect(query['select']) !=
      _compactSelect(kVoicePersonalRuleSelect)) {
    return 'voice_correction_rules select projection mismatch';
  }
  if (query['user_id'] != 'eq.$uid') {
    return 'voice_correction_rules requires user_id=eq.<own uid>';
  }
  if (query['enabled'] != 'eq.true') {
    return 'voice_correction_rules requires enabled=eq.true';
  }
  if (!_sameOrder(query['order'], 'confidence_count.desc')) {
    return 'voice_correction_rules requires order=confidence_count.desc';
  }
  if (query['limit'] != '200') {
    return 'voice_correction_rules requires limit=200';
  }
  return null;
}

/// Trusted common rules: exact fetchTrustedCommonRules wire only — public
/// read with NO user_id scoping (shared rows are the product behavior when
/// the voiceCommonLearningOptIn setting makes the client fetch them).
String? _commonRuleReadReason(Map<String, String> query) {
  const expected = <String>{
    'select',
    'enabled',
    'support_count',
    'conflict_count',
    'confidence_score',
    'order',
    'limit',
  };
  if (!_sameQueryKeys(query.keys, expected)) {
    return 'voice_common_correction_rules read must use exactly select/'
        'enabled/support_count/conflict_count/confidence_score/order/limit '
        'with no user_id';
  }
  if (_compactSelect(query['select']) !=
      _compactSelect(kVoiceCommonRuleSelect)) {
    return 'voice_common_correction_rules select projection mismatch';
  }
  if (query['enabled'] != 'eq.true') {
    return 'voice_common_correction_rules requires enabled=eq.true';
  }
  if (query['support_count'] != 'gte.5') {
    return 'voice_common_correction_rules requires support_count=gte.5';
  }
  if (query['conflict_count'] != 'eq.0') {
    return 'voice_common_correction_rules requires conflict_count=eq.0';
  }
  if (query['confidence_score'] != 'gte.0.85') {
    return 'voice_common_correction_rules requires '
        'confidence_score=gte.0.85';
  }
  if (!_sameOrder(query['order'], 'confidence_score.desc')) {
    return 'voice_common_correction_rules requires '
        'order=confidence_score.desc';
  }
  if (query['limit'] != '100') {
    return 'voice_common_correction_rules requires limit=100';
  }
  return null;
}

/// Returns null when the table+query+uid combination is allowed, otherwise a
/// short rejection reason. Pure function so unit tests can pin behavior.
String? readTableReason({
  required String table,
  required Map<String, String> query,
  required String uid,
}) {
  if (table == kVoicePersonalRuleTable) {
    return _personalRuleReadReason(query, uid);
  }
  if (table == kVoiceCommonRuleTable) {
    return _commonRuleReadReason(query);
  }
  if (!kAllowedReadTables.contains(table)) {
    return 'table $table not in read allowlist';
  }
  switch (table) {
    case 'events':
    case 'user_settings':
      if (query['user_id'] != 'eq.$uid') {
        return '$table requires user_id=eq.<uid>';
      }
      return null;
    case 'users':
      if (query['id'] != 'eq.$uid') return 'users requires id=eq.<uid>';
      return null;
  }
  return 'unhandled table';
}

/// Allowed weather host allowlist. Exact HTTPS host:443, no userinfo, paths
/// limited to the documented endpoints.
const Set<String> kAllowedWeatherHosts = {
  'api.open-meteo.com',
  'geocoding-api.open-meteo.com',
};

const Set<String> kAllowedWeatherPaths = {'/v1/forecast', '/v1/reverse'};

const Set<String> kAllowedWeatherQueryKeys = {
  'latitude',
  'longitude',
  'language',
  'count',
  'timezone',
  'current',
  'name',
};

const Set<String> kMintedWeatherHeaders = {'accept', 'user-agent'};

String? weatherRequestReason({
  required Uri uri,
  required Map<String, String> forwardedHeaders,
}) {
  if (uri.scheme != 'https') return 'weather scheme must be https';
  if (uri.port != 443) return 'weather port must be 443';
  if (uri.userInfo.isNotEmpty) return 'weather url has userinfo';
  if (!kAllowedWeatherHosts.contains(uri.host)) {
    return 'weather host ${uri.host} not in allowlist';
  }
  if (!kAllowedWeatherPaths.contains(uri.path)) {
    return 'weather path ${uri.path} not in allowlist';
  }
  for (final key in uri.queryParameters.keys) {
    if (!kAllowedWeatherQueryKeys.contains(key)) {
      return 'weather query key $key not in allowlist';
    }
  }
  for (final coord in const ['latitude', 'longitude']) {
    final raw = uri.queryParameters[coord];
    if (raw != null && double.tryParse(raw) == null) {
      return 'weather coord $coord not numeric';
    }
  }
  for (final entry in forwardedHeaders.entries) {
    final k = entry.key;
    final lk = k.toLowerCase();
    if (k.startsWith(':') ||
        lk == 'authorization' ||
        lk == 'cookie' ||
        lk == 'apikey' ||
        lk == 'x-api-key' ||
        lk.startsWith('x-supabase') ||
        lk.startsWith('supabase')) {
      return 'weather header $k must not be forwarded';
    }
    if (!kMintedWeatherHeaders.contains(lk)) {
      return 'weather header $k not in minted-header allowlist';
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// R2 map/place contract: the ONLY permitted map network path is the existing
// backend Supabase Edge Function proxy configured through the public
// NAVER_MAP_PROXY_URL define (AppEnv.naverMapProxyUrl; .env.example shows
// https://<project>.supabase.co/functions/v1/naver-geocode). That function
// verifies the caller JWT backend-side and mints the provider secrets from
// its own Deno env; direct naveropenapi.apigw.ntruss.com / apis.openapi.sk.com
// / maps.googleapis.com requests are NEVER allowed — the request host must
// equal the approved backend host.
// ---------------------------------------------------------------------------

/// Finite per-run cap on approved map-proxy GETs (fallback-query bursts
/// included). Exceeding it is a fatal deny, not a silent skip.
const int kMaxMapProxyCallsPerRun = 200;

/// Minted-header allowlist for proxy GETs. Provider secret headers
/// (x-ncp-apigw-*, appkey, x-goog-*) are structurally absent from this set.
const Set<String> kMapProxyHeaderAllowlist = {
  'accept',
  'accept-encoding',
  'authorization',
  'apikey',
  'content-length',
  'content-type',
  'user-agent',
};

/// Bounded "lng,lat" wire shape used by MapService start/goal params.
final RegExp kMapProxyCoordPair =
    RegExp(r'^-?\d{1,3}\.\d{1,7},-?\d{1,3}\.\d{1,7}$');

const int kMapProxyMaxQueryLength = 120;

/// Returns null when the request is exactly the configured backend proxy
/// route with an approved bounded GET shape, otherwise a short rejection
/// reason. [configuredProxy] is the parsed AppEnv.naverMapProxyUrl; null
/// (public define absent) denies every map request.
String? mapProxyRequestReason({
  required String method,
  required Uri uri,
  required Map<String, String> headers,
  required Uri? configuredProxy,
  required String backendHost,
}) {
  if (configuredProxy == null) {
    return 'map proxy not configured (NAVER_MAP_PROXY_URL absent)';
  }
  if (method != 'GET') return 'map proxy must be GET';
  if (uri.scheme != 'https') return 'map proxy scheme must be https';
  if (uri.port != 443) return 'map proxy port must be 443';
  if (uri.userInfo.isNotEmpty) return 'map proxy url has userinfo';
  if (uri.host != backendHost) {
    return 'map proxy host ${uri.host} must be the approved backend host';
  }
  if (uri.path != configuredProxy.path) {
    return 'map proxy path ${uri.path} is not the configured proxy route';
  }
  final q = uri.queryParameters;
  final statics = configuredProxy.queryParameters;
  for (final entry in statics.entries) {
    if (q[entry.key] != entry.value) {
      return 'map proxy static param ${entry.key} tampered';
    }
  }
  final dynamicParams = <String, String>{
    for (final entry in q.entries)
      if (!statics.containsKey(entry.key)) entry.key: entry.value,
  };
  final shapeKeys = dynamicParams.keys.toSet();
  final isGeocode = _sameQueryKeys(shapeKeys, const <String>{'query'});
  final isDirection = shapeKeys.containsAll(const ['start', 'goal', 'mode']) &&
      shapeKeys.difference(
          const <String>{'start', 'goal', 'mode', 'option'}).isEmpty;
  if (isGeocode) {
    final query = dynamicParams['query'] ?? '';
    if (query.isEmpty || query.length > kMapProxyMaxQueryLength) {
      return 'map proxy query length out of bounds';
    }
  } else if (isDirection) {
    final mode = dynamicParams['mode'] ?? '';
    final option = dynamicParams['option'];
    if (mode != 'car' && mode != 'transit') {
      return 'map proxy mode must be car or transit';
    }
    for (final coord in const ['start', 'goal']) {
      if (!kMapProxyCoordPair.hasMatch(dynamicParams[coord] ?? '')) {
        return 'map proxy $coord must be a bounded lng,lat pair';
      }
    }
    if (option != null && option != 'trafast') {
      return 'map proxy option must be trafast';
    }
    if (mode == 'car' && option == null) {
      return 'map proxy car mode must send option=trafast';
    }
    if (mode == 'transit' && option != null) {
      return 'map proxy transit mode must not send option';
    }
  } else {
    return 'map proxy query shape mismatch (query or start/goal/mode only)';
  }
  for (final entry in headers.entries) {
    final k = entry.key.toLowerCase();
    if (!kMapProxyHeaderAllowlist.contains(k)) {
      return 'map proxy header $k not in minted-header allowlist';
    }
    if (k == 'authorization' && !entry.value.startsWith('Bearer ')) {
      return 'map proxy authorization must be a bearer token';
    }
  }
  return null;
}

/// Preserve the existing fail-closed HTTP status rule, except for the one
/// authenticated, already shape-validated map response the client is designed
/// to handle: this proxy explicitly does not implement transit directions.
/// This never admits auth/provider errors, arbitrary 501s, or another route.
bool isNativeHttpResponseStatusAllowed({
  required int statusCode,
  required String method,
  required Uri uri,
  required Map<String, String> headers,
  required Uri? configuredProxy,
  required String backendHost,
  required List<int> bodyBytes,
}) {
  if (statusCode >= 200 && statusCode < 300) return true;
  if (statusCode != 501 ||
      uri.queryParameters['mode'] != 'transit' ||
      bodyBytes.length > 1024 ||
      mapProxyRequestReason(
            method: method,
            uri: uri,
            headers: headers,
            configuredProxy: configuredProxy,
            backendHost: backendHost,
          ) !=
          null) {
    return false;
  }
  try {
    final decoded = jsonDecode(utf8.decode(bodyBytes));
    return decoded is Map &&
        decoded.length == 2 &&
        decoded['code'] == 'unsupported_transit' &&
        decoded['error'] ==
            'Transit directions are not supported by this proxy.';
  } catch (_) {
    return false;
  }
}

/// Pure next-state calculation shared by runtime reservation and focused persistence tests.
/// Every allowed request consumes one count; phase metadata is a unique set.
BudgetLedgerSnapshot nextAiReservationSnapshot(
    BudgetLedgerSnapshot snap, String phase) {
  final reason = reasonForReserveAi(snap, phase);
  if (reason != null) throw StateError(reason);
  return snap.copyWith(
    aiRequests: snap.aiRequests + 1,
    usedPhases: <String>{...snap.usedPhases, phase}.toList(),
  );
}

/// Explicit parent-approved map exclusion is available only in isolated debug
/// QA. It never changes the validation of an incoming proxy request.
bool skipOptionalMapForQa({
  required bool debug,
  required bool guideQa,
  required bool isolatedQa,
  required bool skipMap,
}) =>
    debug && guideQa && isolatedQa && skipMap;

String? reasonForReserveAi(BudgetLedgerSnapshot snap, String phase) {
  if (!kAllowedAiPhases.contains(phase)) return 'phase $phase not allowed';
  if (snap.aiRequests >= snap.maxAiRequests) {
    return 'ledger ai cap reached '
        '(${snap.aiRequests}/$kLedgerMaxAiRequests)';
  }
  // 사용자 전용 QA 앱이므로 단계 재사용 제한은 두지 않는다.
  return null;
}

/// Returns null when an event-create reservation is currently allowed,
/// otherwise a short rejection reason.
String? reasonForReserveEventCreate(BudgetLedgerSnapshot snap) {
  if (snap.createAttempted && snap.createdId == null) {
    return 'ledger createAttempted=true with unknown id; retry forbidden';
  }
  return null;
}

// ---------------------------------------------------------------------------
// Strict related-insert allowlist for the actual _saveRelatedRecords path.
// Only POST (no on_conflict, no Prefer upsert/resolution), phase=save, ledger
// has a captured createAttempted + createdId, every row links back to that id,
// no `id` is supplied, and the row keys are exactly the documented set with
// the per-table boolean explicitly `false`. Batch size is bounded.
// ---------------------------------------------------------------------------

const Set<String> kRelatedInsertTables = <String>{
  'pre_actions',
  'reminders',
  'voice_logs',
  'location_history',
};

const Map<String, Set<String>> kRelatedInsertKeys = <String, Set<String>>{
  'pre_actions': <String>{
    'event_id',
    'user_id',
    'title',
    'notify_at',
    'is_done'
  },
  'reminders': <String>{'event_id', 'user_id', 'type', 'notify_at', 'is_sent'},
  'voice_logs': <String>{'user_id', 'event_id', 'raw_text', 'parsed_json'},
  'location_history': <String>{'user_id', 'event_id', 'location', 'supplies'},
};

const Map<String, String> kRelatedInsertFalseBoolColumns = <String, String>{
  'pre_actions': 'is_done',
  'reminders': 'is_sent',
};

const int kMaxRelatedInsertBatch = 20;

String _preferHeaderLower(Map<String, String> headers) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'prefer') return entry.value.toLowerCase();
  }
  return '';
}

/// Returns null when the related-insert path is fully allowed; otherwise a
/// short reason describing the first failure.
String? relatedInsertReason({
  required String table,
  required Object? body,
  required Map<String, String> query,
  required Map<String, String> headers,
  required BudgetLedgerSnapshot ledger,
  required String expectedUid,
  required String phase,
}) {
  if (!kRelatedInsertTables.contains(table)) {
    return 'table $table not in related-insert allowlist';
  }
  if (phase != 'save') {
    return 'related insert requires phase=save (was: $phase)';
  }
  if (query.containsKey('on_conflict')) {
    return 'related insert forbids on_conflict query param';
  }
  final prefer = _preferHeaderLower(headers);
  if (prefer.contains('merge-duplicates') ||
      prefer.contains('ignore-duplicates') ||
      prefer.contains('upsert')) {
    return 'related insert forbids upsert/resolution Prefer header';
  }
  final createdId = ledger.createdId;
  if (!ledger.createAttempted || createdId == null) {
    return 'related insert requires ledger createAttempted=true and createdId set';
  }
  if (body is! List) {
    return 'related insert body must be an array of rows';
  }
  if (body.length > kMaxRelatedInsertBatch) {
    return 'related insert batch > $kMaxRelatedInsertBatch rows';
  }
  final allowedKeys = kRelatedInsertKeys[table]!;
  final falseBoolCol = kRelatedInsertFalseBoolColumns[table];
  for (final raw in body) {
    if (raw is! Map) return 'related insert rows must be objects';
    if (raw.containsKey('id')) {
      return 'related insert rows must not supply id';
    }
    if (raw['user_id'] != expectedUid) {
      return 'related insert row user_id mismatch';
    }
    if (raw['event_id'] != createdId) {
      return 'related insert row event_id mismatch';
    }
    final extras = raw.keys.where((k) => !allowedKeys.contains(k)).toList();
    if (extras.isNotEmpty) {
      return 'related insert row has unknown keys: ${extras.join(',')}';
    }
    if (falseBoolCol != null && raw[falseBoolCol] != false) {
      return 'related insert row $falseBoolCol must be false';
    }
  }
  return null;
}
