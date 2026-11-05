import 'launch_signal_ledger.dart';

enum IcsShareDecision {
  noCandidate,
  skipMissingFile,
  skipAlreadyHandled,
  route
}

/// Decides whether a share should be routed and records identifiable content.
Future<IcsShareDecision> decideIcsShare({
  required String source,
  required List<String> paths,
  required LaunchSignalLedger ledger,
}) async {
  if (paths.isEmpty) return IcsShareDecision.noCandidate;

  final key = await LaunchSignalLedger.computeShareKey(paths);
  if (source == 'initial') {
    if (key == null) return IcsShareDecision.skipMissingFile;
    if (await ledger.hasShareKey(key)) {
      return IcsShareDecision.skipAlreadyHandled;
    }
  }
  if (key != null) await ledger.recordShareKey(key);
  return IcsShareDecision.route;
}

/// Accepts calendar shares without treating arbitrary binary files as calendars.
bool isIcsShareCandidate({required String path, String? mimeType}) {
  if (path.trim().toLowerCase().endsWith('.ics')) return true;
  return const <String>{
    'text/calendar',
    'text/x-vcalendar',
    'application/ics',
  }.contains(mimeType?.trim().toLowerCase());
}
