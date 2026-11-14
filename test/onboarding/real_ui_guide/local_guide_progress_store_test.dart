import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _ControlledPreferences extends InMemorySharedPreferencesStore {
  _ControlledPreferences() : super.empty();

  final writes = <({String key, String raw})>[];
  FutureOr<bool?> Function(int attempt)? respond;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes.add((key: key, raw: value as String));
    final response = await respond?.call(writes.length);
    if (response != null) return response;
    return super.setValue(valueType, key, value);
  }
}

Future<bool> _returnTrueWithStaleReadback() async {
  // setString updates its cache before the platform call. Reload the old
  // platform value while the write is pending to force a readback mismatch.
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return true;
}

const _uid = 'guide-user';
const _version = 'real_ui_v1';
const _first = GuideSnapshot(
  uid: _uid,
  version: _version,
  revision: 1,
  serverRevision: 0,
  step: GuideStep.homeMic,
  run: GuideRun.active,
);
final _second = _first.copyWith(revision: 2, step: GuideStep.createSpeech);
final _writeFailure = isA<StateError>()
    .having((error) => error.message, 'message', 'Guide write readback failed');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferencesStorePlatform previousPlatform;
  late _ControlledPreferences prefs;
  late LocalGuideProgressStore store;

  setUp(() {
    previousPlatform = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    prefs = _ControlledPreferences();
    SharedPreferencesStorePlatform.instance = prefs;
    store = LocalGuideProgressStore();
  });

  tearDown(() {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = previousPlatform;
  });

  test('concurrent saves both succeed in invocation order', () async {
    final firstWriteStarted = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    prefs.respond = (attempt) async {
      if (attempt == 1) {
        firstWriteStarted.complete();
        await releaseFirstWrite.future;
      }
      return null;
    };

    final saves = expectLater(
      Future.wait([store.save(_first), store.save(_second)]),
      completes,
    );
    await firstWriteStarted.future;
    await Future<void>.delayed(Duration.zero);
    final writesWhileFirstWasPending = prefs.writes.length;
    releaseFirstWrite.complete();
    await saves;

    expect(writesWhileFirstWasPending, 1);
    expect(prefs.writes, hasLength(2));
    expect(
        (await prefs.getAll())[prefs.writes.last.key], prefs.writes.last.raw);
    final saved = await store.load(uid: _uid, version: _version);
    expect(saved?.revision, _second.revision);
    expect(saved?.step, _second.step);
  });

  test('a transient readback mismatch rewrites the same key and value once',
      () async {
    prefs.respond =
        (attempt) => attempt == 1 ? _returnTrueWithStaleReadback() : null;

    await store.save(_first);

    expect(prefs.writes, hasLength(2));
    expect(prefs.writes.last, prefs.writes.first);
    expect(prefs.writes.first.key, 'flutter.guide_progress:$_version:$_uid');
    final saved = await store.load(uid: _uid, version: _version);
    expect(saved?.revision, _first.revision);
  });

  test('a persistent readback mismatch fails and the next queued save succeeds',
      () async {
    prefs.respond =
        (attempt) => attempt <= 2 ? _returnTrueWithStaleReadback() : null;

    final failed = expectLater(store.save(_first), throwsA(_writeFailure));
    final next = store.save(_second);
    await failed;
    await next;

    expect(prefs.writes, hasLength(3));
    expect(prefs.writes[1], prefs.writes.first);
    expect(prefs.writes.last.raw, isNot(prefs.writes.first.raw));
    final saved = await store.load(uid: _uid, version: _version);
    expect(saved?.revision, _second.revision);
  });

  test('a rejected retry fails with the readback error', () async {
    prefs.respond = (attempt) {
      if (attempt == 1) return _returnTrueWithStaleReadback();
      return false;
    };

    await expectLater(store.save(_first), throwsA(_writeFailure));

    expect(prefs.writes, hasLength(2));
    expect(prefs.writes.last, prefs.writes.first);
  });

  test('a rejected first write fails without retrying', () async {
    prefs.respond = (_) => false;

    await expectLater(store.save(_first), throwsA(_writeFailure));

    expect(prefs.writes, hasLength(1));
  });

  test('an exception from the first write propagates without retrying',
      () async {
    final error = StateError('platform write failed');
    prefs.respond = (_) => throw error;

    await expectLater(store.save(_first), throwsA(same(error)));

    expect(prefs.writes, hasLength(1));
  });
}
