/// Accepts calendar shares without treating arbitrary binary files as calendars.
bool isIcsShareCandidate({required String path, String? mimeType}) {
  if (path.trim().toLowerCase().endsWith('.ics')) return true;
  return const <String>{
    'text/calendar',
    'text/x-vcalendar',
    'application/ics',
  }.contains(mimeType?.trim().toLowerCase());
}
