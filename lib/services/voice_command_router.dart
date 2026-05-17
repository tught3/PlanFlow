import 'voice_command_pipeline.dart';
import 'voice_text_cleanup_service.dart';

enum VoiceCommandRouteIntent {
  add,
  edit,
  delete,
  query,
  choose,
}

class VoiceCommandRouteResult {
  const VoiceCommandRouteResult({
    required this.rawText,
    required this.cleanedText,
    required this.normalizedText,
    required this.intent,
    required this.targetText,
    required this.changeText,
    required this.targetQuery,
    required this.requestedChanges,
    required this.requestedFieldValues,
    required this.confidence,
    required this.requiresUserChoice,
    required this.safeDirectApply,
  });

  final String rawText;
  final String cleanedText;
  final String normalizedText;
  final VoiceCommandRouteIntent intent;
  final String targetText;
  final String changeText;
  final String targetQuery;
  final List<String> requestedChanges;
  final Map<String, String> requestedFieldValues;
  final double confidence;
  final bool requiresUserChoice;
  final bool safeDirectApply;
}

class VoiceCommandRouter {
  const VoiceCommandRouter();

  static const VoiceCommandPipeline _pipeline = VoiceCommandPipeline();

  VoiceCommandRouteIntent resolveIntent(
    String text, {
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
  }) {
    return _routeIntentFromPipeline(
      _pipeline.resolveIntent(text, context: context),
    );
  }

  VoiceCommandRouteResult route(
    String rawText, {
    VoiceCommandRouteIntent? intent,
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
    Iterable<VoiceTextCleanupCandidate> candidates = const [],
  }) {
    final plan = _pipeline.analyze(
      rawText,
      intent: intent == null ? null : _pipelineIntentFromRoute(intent),
      context: context,
      candidates: candidates,
    );
    return VoiceCommandRouteResult(
      rawText: plan.rawText,
      cleanedText: plan.cleanedText,
      normalizedText: plan.normalizedText,
      intent: _routeIntentFromPipeline(plan.intent),
      targetText: plan.targetText,
      changeText: plan.changeText,
      targetQuery: plan.targetQuery,
      requestedChanges: plan.requestedChanges,
      requestedFieldValues: plan.requestedFieldValues,
      confidence: plan.confidence,
      requiresUserChoice: plan.requiresUserChoice,
      safeDirectApply: plan.safeDirectApply,
    );
  }

  String buildTargetQuery(
    String text, {
    required VoiceCommandRouteIntent intent,
    Iterable<VoiceTextCleanupCandidate> candidates = const [],
    List<String> requestedChanges = const [],
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
  }) {
    final plan = _pipeline.analyze(
      text,
      intent: _pipelineIntentFromRoute(intent),
      context: context,
      candidates: candidates,
    );
    return plan.targetQuery;
  }

  List<String> extractRequestedChanges(String text) {
    return _pipeline.extractRequestedChanges(text);
  }

  Map<String, dynamic>? buildTargetEventHint(
    String text,
    Iterable<VoiceTextCleanupCandidate> candidates, {
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
  }) {
    if (context == VoiceTextCleanupContext.add || candidates.isEmpty) {
      return null;
    }

    final queryTokens = analysisTokens(text);
    if (queryTokens.isEmpty) {
      return null;
    }

    VoiceTextCleanupCandidate? bestCandidate;
    var bestScore = 0;
    for (final candidate in candidates) {
      final candidateTokens = analysisTokens(candidate.searchableText);
      if (candidateTokens.isEmpty) {
        continue;
      }
      final score =
          queryTokens.toSet().intersection(candidateTokens.toSet()).length;
      if (score > bestScore) {
        bestScore = score;
        bestCandidate = candidate;
      }
    }

    if (bestCandidate == null || bestScore == 0) {
      return null;
    }

    return <String, dynamic>{
      'title': bestCandidate.title,
      if (bestCandidate.location != null &&
          bestCandidate.location!.trim().isNotEmpty)
        'location': bestCandidate.location!.trim(),
      if (bestCandidate.startAt != null)
        'start_at': bestCandidate.startAt!.toIso8601String(),
      'score': bestScore,
    };
  }

  List<String> searchTokens(
    String text, {
    VoiceCommandRouteIntent? intent,
    List<String> requestedChanges = const [],
    Iterable<VoiceTextCleanupCandidate> candidates = const [],
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
  }) {
    final source = intent == null
        ? text
        : _pipeline
            .analyze(
              text,
              intent: _pipelineIntentFromRoute(intent),
              context: context,
              candidates: candidates,
            )
            .targetText;
    return _pipeline.searchTokens(source);
  }

  bool hasFuzzyTokenMatch(String token, List<String> searchableTokens) {
    if (token.length < 3) {
      return false;
    }
    for (final candidate in searchableTokens) {
      if (candidate.length < 3) {
        continue;
      }
      if ((candidate.length - token.length).abs() > 1) {
        continue;
      }
      if (editDistanceAtMostOne(token, candidate)) {
        return true;
      }
    }
    return false;
  }

  bool hasPrefixMatch(String token, List<String> searchableTokens) {
    if (token.length < 3) {
      return false;
    }
    final prefix = token.substring(0, 2);
    for (final candidate in searchableTokens) {
      if (candidate.length < 2) {
        continue;
      }
      if (candidate.startsWith(prefix) || candidate.contains(prefix)) {
        return true;
      }
    }
    return false;
  }

  bool editDistanceAtMostOne(String left, String right) {
    if (left == right) {
      return true;
    }
    if ((left.length - right.length).abs() > 1) {
      return false;
    }
    var leftIndex = 0;
    var rightIndex = 0;
    var edits = 0;
    while (leftIndex < left.length && rightIndex < right.length) {
      if (left.codeUnitAt(leftIndex) == right.codeUnitAt(rightIndex)) {
        leftIndex += 1;
        rightIndex += 1;
        continue;
      }
      edits += 1;
      if (edits > 1) {
        return false;
      }
      if (left.length > right.length) {
        leftIndex += 1;
      } else if (right.length > left.length) {
        rightIndex += 1;
      } else {
        leftIndex += 1;
        rightIndex += 1;
      }
    }
    if (leftIndex < left.length || rightIndex < right.length) {
      edits += 1;
    }
    return edits <= 1;
  }

  String normalizeManagementText(String text) {
    return _pipeline.normalizeManagementText(text);
  }

  List<String> analysisTokens(String text) {
    return _pipeline.analysisTokens(text);
  }

  List<String> tokenVariants(String rawToken) {
    return _pipeline.tokenVariants(rawToken);
  }

  String stripKoreanParticles(String token) {
    return _pipeline.stripKoreanParticles(token);
  }

  bool isAmbiguousFieldAddition(String text) {
    return _pipeline.isAmbiguousFieldAddition(text);
  }

  VoiceCommandPipelineIntent _pipelineIntentFromRoute(
    VoiceCommandRouteIntent intent,
  ) {
    return switch (intent) {
      VoiceCommandRouteIntent.add => VoiceCommandPipelineIntent.add,
      VoiceCommandRouteIntent.edit => VoiceCommandPipelineIntent.edit,
      VoiceCommandRouteIntent.delete => VoiceCommandPipelineIntent.delete,
      VoiceCommandRouteIntent.query => VoiceCommandPipelineIntent.query,
      VoiceCommandRouteIntent.choose => VoiceCommandPipelineIntent.choose,
    };
  }

  VoiceCommandRouteIntent _routeIntentFromPipeline(
    VoiceCommandPipelineIntent intent,
  ) {
    return switch (intent) {
      VoiceCommandPipelineIntent.add => VoiceCommandRouteIntent.add,
      VoiceCommandPipelineIntent.edit => VoiceCommandRouteIntent.edit,
      VoiceCommandPipelineIntent.delete => VoiceCommandRouteIntent.delete,
      VoiceCommandPipelineIntent.query => VoiceCommandRouteIntent.query,
      VoiceCommandPipelineIntent.choose => VoiceCommandRouteIntent.choose,
    };
  }
}
