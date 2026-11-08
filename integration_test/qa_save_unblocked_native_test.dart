// Native verification of QA save without map coordinates and persisted
// repeated-phase AI reservations. Uses synthetic repository/ledger fixtures;
// this is not a live backend save or a replay of a failed user utterance.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'support/native_guide_budget_ledger.dart';
import '../test/screens/confirm_screen_test.dart' as confirm_suite;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Android UiAutomator needs a semantics tree while the test waits for the
  // real OS tap. Keep this handle alive independently of individual widgets.
  binding.shouldPropagateDevicePointerEvents = true;
  // ignore: avoid_print
  print('QA_SAVE_OS_INPUT_ENABLED');
  final semanticsHandle = binding.ensureSemantics();
  tearDownAll(semanticsHandle.dispose);
  // ignore: avoid_print
  print('QA_SAVE_SEMANTICS_READY');
  // A distinct marker prevents installing an earlier, different test target.
  // ignore: avoid_print
  print('QA_SAVE_UNBLOCKED_NATIVE_REGISTERED');
  test('native disk preserves two same-phase reservations', () async {
    final dir = await Directory.systemTemp.createTemp('qa-ledger-native');
    const uid = '11111111-1111-4111-8111-111111111111';
    const budget = 'planflow-guide-FRM9-10300620';
    final file = File('${dir.path}/native-guide-budget-$budget.json');
    try {
      await writeBudgetLedgerAtomic(
          file: file,
          snapshot: BudgetLedgerSnapshot.initial(budgetId: budget, uid: uid));
      for (var i = 0; i < 2; i++) {
        final loaded = await loadBudgetLedger(
            file: file, expectedBudgetId: budget, expectedUid: uid);
        await writeBudgetLedgerAtomic(
            file: file, snapshot: nextAiReservationSnapshot(loaded, 'create'));
      }
      final saved = await loadBudgetLedger(
          file: file, expectedBudgetId: budget, expectedUid: uid);
      expect(saved.aiRequests, 2);
      expect(saved.usedPhases, ['create']);
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('native QA map exclusion needs all four opt-ins', () {
    for (var b = 0; b < 16; b++) {
      expect(
          skipOptionalMapForQa(
              debug: b & 1 != 0,
              guideQa: b & 2 != 0,
              isolatedQa: b & 4 != 0,
              skipMap: b & 8 != 0),
          b == 15);
    }
  });
  confirm_suite.registerConfirmScreenGuideSaveStageTests(nativeOsSaveTap: true);
}
