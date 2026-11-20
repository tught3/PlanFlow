/// Location requirement for a personal guide-created event.
///
/// Place text remains mandatory in every mode. Unresolved coordinates are
/// permitted when the caller can resolve them after saving.
bool guideCreateLocationAllowed({
  required String location,
  required double? latitude,
  required double? longitude,
  required bool allowUnresolvedCoordinates,
}) {
  return location.trim().isNotEmpty &&
      (allowUnresolvedCoordinates || (latitude != null && longitude != null));
}
