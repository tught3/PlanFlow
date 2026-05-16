import 'package:flutter/material.dart';

class PlanFlowRegion {
  const PlanFlowRegion({
    required this.countryCode,
    required this.countryName,
    required this.localeCode,
    required this.uiLocaleCode,
    required this.timeZoneId,
    required this.languageHint,
  });

  final String countryCode;
  final String countryName;
  final String localeCode;
  final String uiLocaleCode;
  final String timeZoneId;
  final String languageHint;

  Locale get locale {
    final parts = localeCode.split('-');
    if (parts.length < 2) {
      return Locale(parts.first);
    }
    return Locale(parts.first, parts[1]);
  }

  Locale get uiLocale {
    final parts = uiLocaleCode.split('-');
    if (parts.length < 2) {
      return Locale(parts.first);
    }
    return Locale(parts.first, parts[1]);
  }
}

class PlanFlowRegions {
  const PlanFlowRegions._();

  static const korea = PlanFlowRegion(
    countryCode: 'KR',
    countryName: '대한민국',
    localeCode: 'ko-KR',
    uiLocaleCode: 'ko-KR',
    timeZoneId: 'Asia/Seoul',
    languageHint: 'ko-KR',
  );

  static const supported = <PlanFlowRegion>[
    korea,
    PlanFlowRegion(
      countryCode: 'US',
      countryName: '미국',
      localeCode: 'en-US',
      uiLocaleCode: 'en-US',
      timeZoneId: 'America/New_York',
      languageHint: 'en-US',
    ),
    PlanFlowRegion(
      countryCode: 'JP',
      countryName: '일본',
      localeCode: 'ja-JP',
      uiLocaleCode: 'en-US',
      timeZoneId: 'Asia/Tokyo',
      languageHint: 'ja-JP',
    ),
    PlanFlowRegion(
      countryCode: 'GB',
      countryName: '영국',
      localeCode: 'en-GB',
      uiLocaleCode: 'en-US',
      timeZoneId: 'Europe/London',
      languageHint: 'en-GB',
    ),
    PlanFlowRegion(
      countryCode: 'DE',
      countryName: '독일',
      localeCode: 'de-DE',
      uiLocaleCode: 'en-US',
      timeZoneId: 'Europe/Berlin',
      languageHint: 'de-DE',
    ),
    PlanFlowRegion(
      countryCode: 'FR',
      countryName: '프랑스',
      localeCode: 'fr-FR',
      uiLocaleCode: 'en-US',
      timeZoneId: 'Europe/Paris',
      languageHint: 'fr-FR',
    ),
    PlanFlowRegion(
      countryCode: 'AU',
      countryName: '호주',
      localeCode: 'en-AU',
      uiLocaleCode: 'en-US',
      timeZoneId: 'Australia/Sydney',
      languageHint: 'en-AU',
    ),
  ];

  static PlanFlowRegion byCountryCode(String? countryCode) {
    final normalized = countryCode?.trim().toUpperCase();
    for (final region in supported) {
      if (region.countryCode == normalized) {
        return region;
      }
    }
    return korea;
  }

  static PlanFlowRegion byLocaleAndTimeZone({
    required String? countryCode,
    required String? localeCode,
    required String? timeZoneId,
  }) {
    final base = byCountryCode(countryCode);
    final locale = localeCode?.trim();
    final timeZone = timeZoneId?.trim();
    if ((locale == null || locale.isEmpty || locale == base.localeCode) &&
        (timeZone == null || timeZone.isEmpty || timeZone == base.timeZoneId)) {
      return base;
    }
    return PlanFlowRegion(
      countryCode: base.countryCode,
      countryName: base.countryName,
      localeCode: locale == null || locale.isEmpty ? base.localeCode : locale,
      uiLocaleCode: base.uiLocaleCode,
      timeZoneId:
          timeZone == null || timeZone.isEmpty ? base.timeZoneId : timeZone,
      languageHint: locale == null || locale.isEmpty ? base.languageHint : locale,
    );
  }
}

class PlanFlowRegionController extends ChangeNotifier {
  PlanFlowRegionController._();

  static final PlanFlowRegionController instance =
      PlanFlowRegionController._();

  PlanFlowRegion _region = PlanFlowRegions.korea;

  PlanFlowRegion get region => _region;

  void setRegion(PlanFlowRegion region) {
    if (_region.countryCode == region.countryCode &&
        _region.localeCode == region.localeCode &&
        _region.timeZoneId == region.timeZoneId) {
      return;
    }
    _region = region;
    notifyListeners();
  }

  void reset() => setRegion(PlanFlowRegions.korea);
}
