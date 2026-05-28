import '../data/models/voice_correction_rule.dart';

class VoiceCorrectionApplicationResult {
  const VoiceCorrectionApplicationResult({
    required this.text,
    this.appliedRules = const <VoiceCorrectionRule>[],
    this.suggestions = const <VoiceCorrectionRule>[],
  });

  final String text;
  final List<VoiceCorrectionRule> appliedRules;
  final List<VoiceCorrectionRule> suggestions;
}

class VoiceCorrectionLearningService {
  const VoiceCorrectionLearningService();

  List<VoiceCorrectionRule> extractRules({
    required String originalText,
    required String correctedText,
    required VoiceCorrectionStage stage,
    required VoiceCorrectionField field,
    String? userId,
  }) {
    final original = _normalize(originalText);
    final corrected = _normalize(correctedText);
    if (original.isEmpty || corrected.isEmpty || original == corrected) {
      return const <VoiceCorrectionRule>[];
    }

    final diff = _diffWindow(original, corrected);
    if (diff == null ||
        diff.fromText.isEmpty ||
        diff.toText.isEmpty ||
        diff.fromText == diff.toText) {
      return const <VoiceCorrectionRule>[];
    }

    return <VoiceCorrectionRule>[
      VoiceCorrectionRule(
        userId: userId,
        stage: stage,
        field: field,
        fromText: diff.fromText,
        toText: diff.toText,
        contextBefore: diff.contextBefore,
        contextAfter: diff.contextAfter,
        isSensitive: _isSensitiveField(field),
      ),
    ];
  }

  VoiceCorrectionApplicationResult applyRules(
    String text, {
    required Iterable<VoiceCorrectionRule> rules,
    required VoiceCorrectionStage stage,
    required VoiceCorrectionField field,
  }) {
    var result = _normalize(text);
    final applied = <VoiceCorrectionRule>[];
    final suggestions = <VoiceCorrectionRule>[];

    for (final rule in rules) {
      if (!rule.enabled ||
          rule.stage != stage ||
          rule.field != field ||
          rule.fromText.trim().isEmpty ||
          rule.toText.trim().isEmpty ||
          !result.contains(rule.fromText) ||
          !_contextMatches(result, rule)) {
        continue;
      }

      if (rule.canAutoApply) {
        final index = result.indexOf(rule.fromText);
        final after = result.substring(index + rule.fromText.length);
        final needsBoundarySpace = rule.contextAfter.isNotEmpty &&
            after.startsWith(rule.contextAfter) &&
            rule.toText.isNotEmpty &&
            !rule.toText.endsWith(' ') &&
            after.isNotEmpty &&
            !after.startsWith(' ');
        final replacement =
            needsBoundarySpace ? '${rule.toText} ' : rule.toText;
        result = result.replaceFirst(rule.fromText, replacement);
        applied.add(rule);
      } else {
        suggestions.add(rule);
      }
    }

    return VoiceCorrectionApplicationResult(
      text: result,
      appliedRules: List<VoiceCorrectionRule>.unmodifiable(applied),
      suggestions: List<VoiceCorrectionRule>.unmodifiable(suggestions),
    );
  }

  Map<String, dynamic> applyParsedScheduleRules(
    Map<String, dynamic> parsed, {
    required Iterable<VoiceCorrectionRule> rules,
  }) {
    final updated = Map<String, dynamic>.from(parsed);
    final title = updated['title']?.toString();
    if (title != null && title.trim().isNotEmpty) {
      final titleResult = applyRules(
        title,
        rules: rules,
        stage: VoiceCorrectionStage.parse,
        field: VoiceCorrectionField.title,
      );
      updated['title'] = titleResult.text;
      if (titleResult.appliedRules.isNotEmpty) {
        updated['voice_correction_applied'] = true;
      }
    }

    final location = updated['location']?.toString();
    if (location != null && location.trim().isNotEmpty) {
      final locationResult = applyRules(
        location,
        rules: rules,
        stage: VoiceCorrectionStage.parse,
        field: VoiceCorrectionField.location,
      );
      updated['location'] = locationResult.text;
      if (locationResult.appliedRules.isNotEmpty) {
        updated['voice_correction_applied'] = true;
      }
    }

    return updated;
  }

  bool shouldRecordRule(VoiceCorrectionRule rule) {
    if (rule.fromText.length < 2 || rule.toText.length < 2) {
      return false;
    }
    if (rule.fromText == rule.toText) {
      return false;
    }
    return true;
  }

  static bool _isSensitiveField(VoiceCorrectionField field) {
    return field == VoiceCorrectionField.location ||
        field == VoiceCorrectionField.supplies;
  }

  static String _normalize(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static bool _contextMatches(String text, VoiceCorrectionRule rule) {
    final index = text.indexOf(rule.fromText);
    if (index < 0) {
      return false;
    }
    final before = text.substring(0, index).trim();
    final after = text.substring(index + rule.fromText.length).trim();
    if (rule.contextBefore.isNotEmpty && !before.endsWith(rule.contextBefore)) {
      return false;
    }
    if (rule.contextAfter.isNotEmpty && !after.startsWith(rule.contextAfter)) {
      return false;
    }
    return true;
  }

  static _CorrectionDiff? _diffWindow(String original, String corrected) {
    var prefix = 0;
    while (prefix < original.length &&
        prefix < corrected.length &&
        original.codeUnitAt(prefix) == corrected.codeUnitAt(prefix)) {
      prefix += 1;
    }

    var originalEnd = original.length;
    var correctedEnd = corrected.length;
    while (originalEnd > prefix &&
        correctedEnd > prefix &&
        original.codeUnitAt(originalEnd - 1) ==
            corrected.codeUnitAt(correctedEnd - 1)) {
      originalEnd -= 1;
      correctedEnd -= 1;
    }

    final from = original.substring(prefix, originalEnd).trim();
    final to = corrected.substring(prefix, correctedEnd).trim();
    if (from.isEmpty || to.isEmpty) {
      return null;
    }

    final contextBefore = _lastWords(original.substring(0, prefix), 2);
    final contextAfter = _firstWords(original.substring(originalEnd), 2);
    return _CorrectionDiff(
      fromText: from,
      toText: to,
      contextBefore: contextBefore,
      contextAfter: contextAfter,
    );
  }

  static String _lastWords(String text, int count) {
    final words = _normalize(text)
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    if (words.isEmpty) {
      return '';
    }
    return words
        .skip(words.length > count ? words.length - count : 0)
        .join(' ');
  }

  static String _firstWords(String text, int count) {
    final words = _normalize(text)
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    if (words.isEmpty) {
      return '';
    }
    return words.take(count).join(' ');
  }
}

class _CorrectionDiff {
  const _CorrectionDiff({
    required this.fromText,
    required this.toText,
    required this.contextBefore,
    required this.contextAfter,
  });

  final String fromText;
  final String toText;
  final String contextBefore;
  final String contextAfter;
}
