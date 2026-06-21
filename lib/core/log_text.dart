String logSafeText(Object? value) {
  final text = value?.toString() ?? 'null';
  final buffer = StringBuffer();

  for (final rune in text.runes) {
    if (rune == 0x0A) {
      buffer.write(r'\n');
    } else if (rune == 0x0D) {
      buffer.write(r'\r');
    } else if (rune == 0x09) {
      buffer.write(r'\t');
    } else if (rune >= 0x20 && rune <= 0x7E) {
      buffer.writeCharCode(rune);
    } else {
      buffer.write(r'\u{');
      buffer.write(rune.toRadixString(16).toUpperCase());
      buffer.write('}');
    }
  }

  return buffer.toString();
}
