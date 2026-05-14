# 버그 기록: FilledButton + Row + Expanded → Scaffold 전체 미렌더링

**발생 일자**: 2026-05-15  
**파일**: `lib/screens/location/location_picker_screen.dart`  
**증상**: LocationPickerScreen 진입 시 AppBar만 보이고 body + bottomNavigationBar가 완전히 사라짐

---

## 증상 요약

- AppBar(제목 텍스트)는 정상 표시
- body 영역 → 완전 빈 화면 (파란 Container도 안 보임)
- bottomNavigationBar(`_MapControlSheet`) → 완전 빈 화면
- Flutter Inspector에는 위젯 트리가 정상으로 보임
- 에러 로그 없음 (또는 레이아웃 assertion이 release 빌드에서 소거됨)

---

## 근본 원인

### 핵심: `Size.fromHeight(48)` = `Size(double.infinity, 48)`

앱 테마(`AppTheme`)에 아래 설정이 있음:

```dart
filledButtonTheme: FilledButtonThemeData(
  style: FilledButton.styleFrom(
    minimumSize: Size.fromHeight(48), // ← 이게 문제
  ),
),
```

`Size.fromHeight(48)`은 Flutter에서 `Size(double.infinity, 48)`과 동일하다.  
즉, **최소 너비 = 무한대**.

### Row 안에서 벌어지는 일

```dart
Row(
  children: [
    Expanded(child: TextField(...)),  // flex 자식
    SizedBox(width: 8),               // 고정 8px
    FilledButton(...),                // 비-flex 자식, minWidth = ∞
  ],
)
```

Flutter Row 레이아웃 알고리즘:

1. **비-flex 자식 먼저 측정** (SizedBox, FilledButton)
2. SizedBox → 8px
3. FilledButton → `minWidth = ∞` → Row 가용 너비(예: 360px)에서 클램핑 → **352px 차지**
4. **남은 공간 = 360 - 8 - 352 = 0px**
5. `Expanded(TextField)` → **0px 할당** → 레이아웃 assertion 발생
6. 해당 Column 전체 렌더 실패 → `_MapControlSheet` 위젯이 0 높이가 됨
7. `bottomNavigationBar`가 0높이 → Scaffold가 body 높이를 화면 전체로 확장
8. NaverMap(HybridComposition PlatformView)이 Flutter canvas 아래 네이티브 레이어에서 전체 화면 차지 → body의 Flutter 위젯들이 가려짐
9. 결과적으로 **AppBar만 보이고 나머지는 완전히 안 보이는 것처럼** 보임

### 왜 AppBar만 살아남았나

HC(Hybrid Composition) 모드에서 NaverMap은 네이티브 Android View로 Flutter canvas **아래**에 렌더링된다. AppBar는 Flutter의 별도 오버레이 레이어에 있어 PlatformView에 덮이지 않는다. 그래서 AppBar만 보였던 것.

---

## 수정 방법

`FilledButton`에 명시적 `minimumSize`를 지정해 Row 안에서 무한 확장을 막는다:

```dart
// 수정 전 (테마 기본값 Size.fromHeight(48) = Size(∞, 48) 사용)
FilledButton(
  onPressed: onSearch,
  child: const Text('검색'),
),

// 수정 후 (명시적 너비 지정)
FilledButton(
  style: FilledButton.styleFrom(
    minimumSize: const Size(64, 48), // ← 너비를 유한 값으로 고정
  ),
  onPressed: onSearch,
  child: const Text('검색'),
),
```

---

## 안전한 패턴 vs 위험한 패턴

| 패턴 | 결과 | 이유 |
|------|------|------|
| `Row([Expanded(...), FilledButton()])` | **위험** | 테마 `Size.fromHeight` = `Size(∞, 48)` → Row 전체 차지 |
| `Row([Expanded(...), FilledButton(style: styleFrom(minimumSize: Size(64,48)))])` | **안전** | 너비 유한 → Expanded에 공간 남김 |
| `Row([Expanded(...), IconButton(constraints: BoxConstraints(minWidth:36))])` | **안전** | `minWidth=36` (유한) → 문제 없음 |
| `Column([FilledButton()])` + `crossAxisAlignment.stretch` | **안전** | Row 아니라 Column이므로 너비 계산 다름 |

---

## 재발 방지 체크리스트

- `Row` 안에 `Expanded` 자식과 `FilledButton`을 함께 쓸 때는 **반드시** `minimumSize`에 유한 너비를 명시
- `Size.fromHeight(n)` = `Size(∞, n)` — 이 값을 Row 안 비-flex 자식에 쓰면 레이아웃이 깨짐
- 글로벌 테마에 `Size.fromHeight` 설정이 있는 프로젝트에서는 Row 안 버튼에 특히 주의
- 증상이 "AppBar만 보이고 body/bottomNav가 안 보임"이라면 → bottomNavigationBar 높이 0 의심 → Row + FilledButton 레이아웃 먼저 확인

---

## 디버깅 과정에서 쓸모 있었던 방법

1. `bottomNavigationBar`를 단순 `Container(color: Colors.red, height: 100)`으로 교체 → 보이면 위젯 자체 문제, 안 보이면 외부 원인
2. `_MapControlSheet.build()`를 `return Container(color: Colors.green)` 단순화 → 보임 → 위젯 클래스 자체는 무죄
3. Row 하나씩 추가하며 어느 Row가 문제인지 이진 탐색
4. `FilledButton` vs `IconButton` 비교 → `IconButton`은 `constraints: BoxConstraints(minWidth: 36)` 명시돼 있어 통과
