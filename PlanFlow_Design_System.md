# PlanFlow 디자인 시스템 & 스타일 가이드

---

## 🎨 컬러 시스템

```dart
// lib/core/theme.dart 에 적용할 색상 상수

class PlanFlowColors {
  // 베이스 (배경)
  static const background     = Color(0xFFEEF5FB); // 전체 배경
  static const surface        = Color(0xFFFFFFFF); // 카드 배경 (예정 일정)
  static const surfaceFaint   = Color(0xFFF5F8FB); // 완료 일정 배경

  // 메인 컬러 (스틸블루 계열)
  static const primary        = Color(0xFF1E3A5F); // 헤더, 주요 텍스트
  static const primaryMid     = Color(0xFF2E6DA4); // 시간 텍스트, 태그
  static const primaryLight   = Color(0xFF7AB3D4); // 완료 텍스트, 보조 강조
  static const primaryFaint   = Color(0xFFD0E4F0); // 카드 테두리, 구분선

  // 액션 컬러 (코발트블루 — 진행중 강조)
  static const active         = Color(0xFF1A4FD6); // 진행중 카드 배경, NOW 뱃지 텍스트
  static const activeLight    = Color(0xFFA8C8FF); // 진행중 카드 시간 텍스트

  // 브리핑 컬러
  static const briefing       = Color(0xFF2E6DA4); // 브리핑 카드 배경 (진한 스틸블루)
  static const briefingLabel  = Color(0xFFA8D4F0); // 브리핑 라벨 텍스트

  // 말하기 버튼
  static const fab            = Color(0xFF5D61A8); // FAB 버튼 (중간 인디고)

  // 텍스트
  static const textPrimary    = Color(0xFF1E3A5F); // 주요 텍스트
  static const textSecondary  = Color(0xFF4A6080); // 보조 텍스트, 날짜
  static const textDisabled   = Color(0xFF7AB3D4); // 완료 일정 텍스트

  // 태그
  static const tagNormalBg    = Color(0xFFEEF5FB);
  static const tagNormalText  = Color(0xFF2E6DA4);
  static const tagActiveBg    = Color(0x33FFFFFF); // rgba(255,255,255,0.2)
  static const tagActiveText  = Color(0xFFFFFFFF);
  static const tagDoneBg      = Color(0xFFF5F8FB);
  static const tagDoneText    = Color(0xFF7AB3D4);
}
```

---

## 📐 컴포넌트 스펙

### 전체 배경
```
배경색: #EEF5FB
```

### 일정 카드 — 3가지 상태

**진행중 카드 (Active)**
```
배경: #1A4FD6
시간 텍스트: #A8C8FF
제목 텍스트: #FFFFFF
태그 배경: rgba(255,255,255,0.2)
태그 텍스트: #FFFFFF
NOW 뱃지: 흰 배경 + #1A4FD6 텍스트
Border-radius: 10px
Padding: 10px 12px
```

**예정 카드 (Normal)**
```
배경: #FFFFFF
테두리: 0.5px solid #D0E4F0
시간 텍스트: #2E6DA4
제목 텍스트: #1E3A5F
태그 배경: #EEF5FB
태그 텍스트: #2E6DA4
Border-radius: 10px
Padding: 10px 12px
```

**완료 카드 (Done)**
```
배경: #F5F8FB
테두리: 0.5px solid #D0E4F0
시간 텍스트: #7AB3D4
제목 텍스트: #7AB3D4 (흐릿하게)
완료 뱃지: #EEF5FB 배경 + #7AB3D4 텍스트
Border-radius: 10px
Padding: 10px 12px
```

### 브리핑 카드
```
배경: #2E6DA4
라벨 텍스트: #A8D4F0 (opacity 0.8)
본문 텍스트: #FFFFFF
Border-radius: 10px
Padding: 10px 12px
```

### 말하기 FAB 버튼
```
배경: #5D61A8
텍스트: #FFFFFF
아이콘: 흰 원형 배경 + #5D61A8 점
Border-radius: 28px
Padding: 10px 20px
전체 너비
```

### 섹션 라벨 (오전/오후)
```
폰트 사이즈: 10px
색상: #4A6080
Letter-spacing: 0.05em
Text-transform: uppercase
```

### 태그/뱃지
```
폰트 사이즈: 9px
Padding: 2px 7px
Border-radius: 8px
```

### 범례 (Legend)
```
점 크기: 8px 원형
텍스트: 10px #4A6080
진행중: #1A4FD6
예정: #1E3A5F
완료: #D0E4F0
```

---

## 🔤 타이포그래피

```
헤더 날짜:   11px / #4A6080
헤더 제목:   18px / font-weight 500 / #1E3A5F
헤더 부제:   11px / #4A6080
카드 시간:   10px
카드 제목:   13px / font-weight 500
브리핑 라벨: 9px / letter-spacing 0.05em
브리핑 본문: 11px / line-height 1.5
```

---

## 📱 Flutter 테마 적용 코드

```dart
// lib/core/theme.dart

import 'package:flutter/material.dart';

class PlanFlowTheme {
  static ThemeData get light => ThemeData(
    scaffoldBackgroundColor: const Color(0xFFEEF5FB),
    colorScheme: const ColorScheme.light(
      primary:    Color(0xFF1E3A5F),
      secondary:  Color(0xFF1A4FD6),
      surface:    Color(0xFFFFFFFF),
      background: Color(0xFFEEF5FB),
    ),
    cardTheme: CardTheme(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xFFD0E4F0), width: 0.5),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFF5D61A8),
      foregroundColor: Colors.white,
    ),
    textTheme: const TextTheme(
      titleLarge:  TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: Color(0xFF1E3A5F)),
      titleMedium: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF1E3A5F)),
      bodySmall:   TextStyle(fontSize: 11, color: Color(0xFF4A6080)),
      labelSmall:  TextStyle(fontSize: 10, color: Color(0xFF4A6080), letterSpacing: 0.05),
    ),
  );
}
```

---

## 🧩 위젯별 구현 가이드

### 진행중 카드
```dart
Container(
  decoration: BoxDecoration(
    color: Color(0xFF1A4FD6),
    borderRadius: BorderRadius.circular(10),
  ),
  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  // ...
)
```

### 예정 카드
```dart
Container(
  decoration: BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(10),
    border: Border.all(color: Color(0xFFD0E4F0), width: 0.5),
  ),
  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  // ...
)
```

### 완료 카드
```dart
Container(
  decoration: BoxDecoration(
    color: Color(0xFFF5F8FB),
    borderRadius: BorderRadius.circular(10),
    border: Border.all(color: Color(0xFFD0E4F0), width: 0.5),
  ),
  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  // ...
)
```

### 브리핑 카드
```dart
Container(
  decoration: BoxDecoration(
    color: Color(0xFF2E6DA4),
    borderRadius: BorderRadius.circular(10),
  ),
  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  // ...
)
```

### 말하기 FAB
```dart
FloatingActionButton.extended(
  backgroundColor: Color(0xFF5D61A8),
  icon: Icon(Icons.mic, color: Colors.white),
  label: Text('말하기', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
  onPressed: () => // 음성 입력 화면으로 이동,
)
```

### 태그 위젯
```dart
// 진행중 태그
Container(
  padding: EdgeInsets.symmetric(horizontal: 7, vertical: 2),
  decoration: BoxDecoration(
    color: Colors.white.withOpacity(0.2),
    borderRadius: BorderRadius.circular(8),
  ),
  child: Text(label, style: TextStyle(fontSize: 9, color: Colors.white)),
)

// 예정 태그
Container(
  padding: EdgeInsets.symmetric(horizontal: 7, vertical: 2),
  decoration: BoxDecoration(
    color: Color(0xFFEEF5FB),
    borderRadius: BorderRadius.circular(8),
  ),
  child: Text(label, style: TextStyle(fontSize: 9, color: Color(0xFF2E6DA4))),
)
```

---

## ⚠️ 디자인 원칙

1. **일정 상태는 색으로 즉시 구분** — 진행중(코발트), 예정(흰색), 완료(흐릿)
2. **브리핑 카드는 항상 가장 진한 색** — 다른 요소와 확실히 구분
3. **말하기 버튼은 브리핑/진행중보다 연하게** — 시각적 위계 유지
4. **테두리는 항상 0.5px** — 두꺼운 테두리 사용 금지
5. **그림자(elevation) 사용 금지** — 플랫 디자인 유지
6. **배경색(#EEF5FB)은 절대 변경 금지** — 전체 통일성 기준
