import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:planflow/core/startup_route_gate.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'loading -> original intro -> observed guide -> modal; hold through Skip gap',
      () async {
    final gate = StartupRouteGate()..beginGuideChoice('a');
    final ready = Completer<void>();
    final guide = Completer<void>();
    final calls = <String>[];
    final flow = runGuideStartupSequence(
      ready: () => ready.future,
      intro: () async {
        calls.add('intro');
      },
      introConfirmed: () => true,
      guide: () async {
        calls.add('guide');
        await guide.future;
      },
      sameAccount: () => true,
      syncChoice: () async {
        calls.add('modal');
        expect(gate.calendarSyncHeldFor('a'), isTrue);
        await GuideSyncChoiceStore().close('a');
        expect(await GuideSyncChoiceStore().isClosed('a'), isTrue);
        gate.closeGuideChoice('a');
        return true;
      },
    );
    SharedPreferences.setMockInitialValues({});
    expect(calls, isEmpty);
    expect(gate.startupWorkDeferred, isFalse);
    ready.complete();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['intro', 'guide']);
    expect(gate.calendarSyncHeldFor('a'), isTrue);
    guide.complete();
    expect(await flow, isTrue);
    expect(calls, ['intro', 'guide', 'modal']);
    expect(gate.calendarSyncHeldFor('a'), isFalse);
    expect(await GuideSyncChoiceStore().isClosed('b'), isFalse);
    expect(gate.calendarSyncHeldFor('b'), isTrue);
    gate.dispose();
  });
  test('auth switch during guide cannot open previous UID modal', () async {
    var uid = 'a';
    var modal = false;
    final result = await runGuideStartupSequence(
      ready: () async {},
      intro: () async {},
      introConfirmed: () => true,
      guide: () async {
        uid = 'b';
      },
      sameAccount: () => uid == 'a',
      syncChoice: () async {
        modal = true;
        return true;
      },
    );
    expect(result, isFalse);
    expect(modal, isFalse);
  });
  test('unconfirmed intro cannot enter real guide or modal', () async {
    var guide = false;
    expect(
        await runGuideStartupSequence(
          ready: () async {},
          intro: () async {},
          introConfirmed: () => false,
          guide: () async {
            guide = true;
          },
          sameAccount: () => true,
          syncChoice: () async => throw StateError('unexpected modal'),
        ),
        isFalse);
    expect(guide, isFalse);
  });
}
