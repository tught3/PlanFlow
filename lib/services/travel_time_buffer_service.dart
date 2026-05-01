import 'dart:math' as math;

enum TravelTimeBufferSource {
  coordinates,
  locationText,
  defaultFallback,
}

class TravelTimeBufferEstimate {
  const TravelTimeBufferEstimate({
    required this.buffer,
    required this.source,
    required this.reason,
  });

  final Duration buffer;
  final TravelTimeBufferSource source;
  final String reason;

  int get minutes => buffer.inMinutes;
}

class TravelTimeBufferService {
  const TravelTimeBufferService();

  /// Returns a deterministic travel buffer for the available location signal.
  ///
  /// This is intentionally not a routing engine. We do not have a map API key
  /// in this scaffold, so the result is a stable heuristic:
  /// - coordinates are mapped to a pseudo-distance score from the origin
  /// - location text is mapped by keyword and length hints
  /// - missing input falls back to a safe default
  TravelTimeBufferEstimate estimate({
    double? latitude,
    double? longitude,
    String? locationText,
  }) {
    if (latitude != null && longitude != null) {
      final minutes = _estimateFromCoordinates(latitude, longitude);
      return TravelTimeBufferEstimate(
        buffer: Duration(minutes: minutes),
        source: TravelTimeBufferSource.coordinates,
        reason: 'Deterministic coordinate heuristic.',
      );
    }

    final normalizedText = _normalizeLocationText(locationText);
    if (normalizedText.isNotEmpty) {
      final minutes = _estimateFromLocationText(normalizedText);
      return TravelTimeBufferEstimate(
        buffer: Duration(minutes: minutes),
        source: TravelTimeBufferSource.locationText,
        reason: 'Deterministic text heuristic.',
      );
    }

    return const TravelTimeBufferEstimate(
      buffer: Duration(minutes: 15),
      source: TravelTimeBufferSource.defaultFallback,
      reason: 'Default buffer when no location signal is available.',
    );
  }

  int estimateMinutes({
    double? latitude,
    double? longitude,
    String? locationText,
  }) {
    return estimate(
      latitude: latitude,
      longitude: longitude,
      locationText: locationText,
    ).minutes;
  }

  Duration estimateBuffer({
    double? latitude,
    double? longitude,
    String? locationText,
  }) {
    return estimate(
      latitude: latitude,
      longitude: longitude,
      locationText: locationText,
    ).buffer;
  }

  int _estimateFromCoordinates(double latitude, double longitude) {
    final pseudoDistance = math.sqrt(
      (latitude * latitude) + (longitude * longitude),
    );
    final normalized = (pseudoDistance / 180.0).clamp(0.0, 1.0);
    return _clampMinutes(15 + (normalized * 45).round());
  }

  int _estimateFromLocationText(String locationText) {
    var score = 12 + (locationText.length ~/ 12);

    const keywordBonuses = <String, int>{
      'airport': 35,
      'station': 18,
      'terminal': 20,
      'downtown': 10,
      'city center': 10,
      'suburb': 8,
      'campus': 10,
      'hospital': 20,
      'clinic': 18,
      'hotel': 12,
      'resort': 12,
      'office': 8,
      'meeting': 10,
      'conference': 15,
      'home': 5,
      'park': 8,
      'museum': 8,
      'port': 12,
      'seaport': 12,
      'mall': 10,
      'market': 10,
      'seoul': 10,
      'busan': 10,
      'incheon': 10,
    };

    for (final entry in keywordBonuses.entries) {
      if (locationText.contains(entry.key)) {
        score += entry.value;
      }
    }

    if (RegExp(r'\d').hasMatch(locationText)) {
      score += 3;
    }

    if (locationText.contains(',')) {
      score += 2;
    }

    if (locationText.length > 24) {
      score += 4;
    }

    return _clampMinutes(score);
  }

  String _normalizeLocationText(String? locationText) {
    final text = locationText?.trim() ?? '';
    if (text.isEmpty) {
      return '';
    }
    return text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  int _clampMinutes(int minutes) {
    return minutes.clamp(10, 75).toInt();
  }
}
