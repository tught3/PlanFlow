import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:planflow/screens/settings/naver_ics_import_screen.dart';
import 'package:planflow/services/naver_ics_import_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('clears spinner and reports unexpected import errors',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: NaverIcsImportScreen(
      initialPaths: const ['a.ics'],
      importService: _ScriptedImportService([StateError('private detail')]),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('ICS 파일을 읽고 일정을 저장하는 중입니다.'), findsNothing);
    expect(find.text('가져오기 확인 필요'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(naverIcsImportUnexpectedErrorMessage),
      ),
      findsOneWidget,
    );
  });

  testWidgets('continues after one failed file and shows the successful import',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: NaverIcsImportScreen(
      initialPaths: const ['a.ics', 'b.ics'],
      importService: _ScriptedImportService([
        StateError('private detail'),
        const NaverIcsImportResult(
            success: true, message: 'ok', imported: 1, total: 1),
      ]),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('가져옴 1개'), findsOneWidget);
    expect(find.text('가져오기 완료'), findsOneWidget);
    expect(find.text('ICS 파일을 읽고 일정을 저장하는 중입니다.'), findsNothing);
  });

  testWidgets(
      'shows corrected guide copy across all three pages without overflow',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: NaverIcsImportScreen(
        importService: _ScriptedImportService(const []),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 1200));
    await tester.pumpAndSettle();
    expect(find.text('캘린더 파일(.ics)로 일정 가져오기'), findsOneWidget);
    expect(find.text('네이버에서 공유하면 PlanFlow가 자동으로 저장해요'), findsNothing);
    expect(find.textContaining('중복 없이'), findsNothing);

    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('2. PlanFlow로 보내기'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('3. 파일 직접 선택'), findsOneWidget);
    expect(find.textContaining('중복 없이'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _ScriptedImportService extends Fake implements NaverIcsImportService {
  _ScriptedImportService(this.outcomes);

  final List<Object> outcomes;
  int _index = 0;

  @override
  Future<NaverIcsImportResult> importFile(String path, {String? userId}) async {
    final outcome = outcomes[_index++];
    if (outcome is Error) throw outcome;
    if (outcome is Exception) throw outcome;
    return outcome as NaverIcsImportResult;
  }
}
