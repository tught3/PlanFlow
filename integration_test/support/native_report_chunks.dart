import 'dart:convert';

// Chunks are in-memory only.
const String _reportChunkPrefix = 'VOICE_TOUR_NATIVE_REPORT_CHUNK';

List<String> encodeVoiceTourReportChunks(Map<String, dynamic> report) {
  final String runId = report['runId'] as String;
  final String encoded = base64Encode(utf8.encode(jsonEncode(report)));
  final int total = (encoded.length + 511) ~/ 512;
  return List<String>.generate(total, (int index) {
    final int start = index * 512;
    final String data = encoded.substring(
        start, start + 512 < encoded.length ? start + 512 : encoded.length);
    return '$_reportChunkPrefix ${jsonEncode(<String, Object>{
          'runId': runId,
          'index': index,
          'total': total,
          'data': data,
        })}';
  }, growable: false);
}

void emitVoiceTourReportChunks(Map<String, dynamic> report) {
  for (final String line in encodeVoiceTourReportChunks(report)) {
    // ignore: avoid_print
    print(line);
  }
}

// Call emitVoiceTourReportChunks(report) immediately before the legacy print:
// print('$_prefixReport ${jsonEncode(report)}');
