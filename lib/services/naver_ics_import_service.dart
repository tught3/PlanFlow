import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:ical_parser/ical_parser.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models/event_model.dart';
import '../data/repositories/event_repository.dart';

class NaverIcsImportService {
  NaverIcsImportService({
    EventRepository? eventRepository,
    SupabaseClient? client,
    DateTime Function()? now,
  })  : _eventRepository = eventRepository ?? EventRepository.supabase(),
        _client = client,
        _now = now ?? DateTime.now;

  final EventRepository _eventRepository;
  final SupabaseClient? _client;
  final DateTime Function() _now;

  Future<NaverIcsImportResult> importFile(
    String path, {
    String? userId,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      return const NaverIcsImportResult.failure(
        message: 'ICS 파일을 찾지 못했습니다.',
      );
    }
    final content = await file.readAsString();
    return importContent(content, userId: userId, sourcePath: path);
  }

  Future<NaverIcsImportResult> importContent(
    String content, {
    String? userId,
    String? sourcePath,
  }) async {
    final resolvedUserId = _resolveUserId(userId);
    if (resolvedUserId == null || resolvedUserId.isEmpty) {
      return const NaverIcsImportResult.failure(
        message: '먼저 PlanFlow에 로그인해 주세요.',
      );
    }

    final parsedEvents = parseEvents(content);
    if (parsedEvents.isEmpty) {
      return const NaverIcsImportResult(
        success: false,
        message: 'ICS 파일에서 가져올 일정을 찾지 못했습니다.',
      );
    }

    final existingEvents = List<EventModel>.from(
      await _eventRepository.listEvents(userId: resolvedUserId),
    );
    final cleanedCount = await _cleanupSuspiciousImportedEvents(
      resolvedUserId,
    );
    if (cleanedCount > 0) {
      debugPrint(
        'Naver ICS cleanup removed $cleanedCount suspicious imported events before import.',
      );
      existingEvents.removeWhere(
        (event) =>
            _isImportedSource(event.source) &&
            event.startAt != null &&
            _isSuspiciousImportedDate(event.startAt!),
      );
    }
    var imported = 0;
    var skipped = 0;
    var failed = 0;

    for (final parsed in parsedEvents) {
      if (_isSuspiciousImportedDate(parsed.startAt) ||
          (parsed.endAt != null && _isSuspiciousImportedDate(parsed.endAt!)) ||
          (parsed.endAt != null && parsed.endAt!.isBefore(parsed.startAt))) {
        debugPrint(
          'Naver ICS suspicious event skipped: '
          'externalId=${parsed.externalId}, '
          'title="${parsed.title}", '
          'startAt=${parsed.startAt.toIso8601String()}, '
          'endAt=${parsed.endAt?.toIso8601String()}',
        );
        skipped += 1;
        continue;
      }
      final externalId = parsed.externalId;
      final duplicateReason = _duplicateReason(
        existingEvents: existingEvents,
        externalId: externalId,
        title: parsed.title,
        startAt: parsed.startAt,
      );
      if (duplicateReason != null) {
        debugPrint(
          'Naver ICS duplicate skipped: '
          'externalId=$externalId, '
          'title="${parsed.title}", '
          'startAt=${parsed.startAt.toIso8601String()}, '
          'reason=$duplicateReason',
        );
        skipped += 1;
        continue;
      }

      try {
        final event = EventModel(
          id: '',
          userId: resolvedUserId,
          title: parsed.title,
          startAt: parsed.startAt,
          endAt: parsed.endAt,
          location: parsed.location,
          memo: parsed.description,
          source: 'naver_ics',
          externalId: externalId,
          externalCalendarId: 'naver-ics',
          externalEtag: parsed.uid,
          externalUpdatedAt: parsed.lastModifiedAt ?? _now().toUtc(),
          lastSyncedAt: _now().toUtc(),
        );
        final saved = await _eventRepository.createEvent(event);
        existingEvents.add(saved);
        imported += 1;
      } catch (_) {
        failed += 1;
      }
    }

    final message = failed > 0
        ? '네이버 ICS에서 $imported개를 가져오고, $skipped개는 중복이라 건너뛰었어요. $failed개는 저장하지 못했습니다.'
        : '네이버 ICS에서 $imported개를 가져왔어요. 중복 $skipped개는 건너뛰었습니다.';
    return NaverIcsImportResult(
      success: imported > 0 || skipped > 0,
      message: message,
      imported: imported,
      skipped: skipped,
      failed: failed,
      total: parsedEvents.length,
      sourcePath: sourcePath,
    );
  }

  List<NaverIcsParsedEvent> parseEvents(String content) {
    final json = ICal.toJson(content);
    final rawEvents = json['VEVENT'];
    if (rawEvents is! List) {
      return const <NaverIcsParsedEvent>[];
    }

    final events = <NaverIcsParsedEvent>[];
    for (final raw in rawEvents) {
      if (raw is! Map) {
        continue;
      }
      final data = raw.map(
        (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
      );
      final title = _textProperty(data, 'SUMMARY')?.trim();
      final startAt = _dateTimeProperty(data, 'DTSTART');
      if (title == null || title.isEmpty || startAt == null) {
        continue;
      }
      final hasEndRaw = _hasProperty(data, 'DTEND');
      final endAt = _dateTimeProperty(data, 'DTEND');
      if (hasEndRaw && endAt == null) {
        debugPrint(
          'Naver ICS event skipped because DTEND failed to parse: '
          'title="$title", rawEnd=${_textProperty(data, "DTEND")}',
        );
        continue;
      }
      final uid = _textProperty(data, 'UID')?.trim();
      events.add(
        NaverIcsParsedEvent(
          uid: uid,
          title: _unescapeText(title),
          startAt: startAt,
          endAt: endAt,
          location: _blankToNull(
            _unescapeText(_textProperty(data, 'LOCATION') ?? ''),
          ),
          description: _blankToNull(
            _unescapeText(_textProperty(data, 'DESCRIPTION') ?? ''),
          ),
          lastModifiedAt: _dateTimeProperty(data, 'LAST-MODIFIED') ??
              _dateTimeProperty(data, 'DTSTAMP'),
        ),
      );
    }
    return events;
  }

  String? _duplicateReason({
    required List<EventModel> existingEvents,
    required String externalId,
    required String title,
    required DateTime startAt,
  }) {
    final normalizedTitle = _normalizeTitle(title);
    for (final event in existingEvents) {
      if ((event.externalId ?? '').trim() == externalId) {
        return 'external_id 일치';
      }
      final existingStart = event.startAt;
      if (existingStart == null) {
        continue;
      }
      if (_sameLocalDay(existingStart, startAt) &&
          _normalizeTitle(event.title) == normalizedTitle) {
        return '같은 날짜+제목 중복';
      }
    }
    return null;
  }

  String? _resolveUserId(String? userId) {
    if (userId != null && userId.isNotEmpty) {
      return userId;
    }
    try {
      final client = _client ?? Supabase.instance.client;
      return client.auth.currentSession?.user.id ?? client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  Future<int> _cleanupSuspiciousImportedEvents(String userId) async {
    final events = await _eventRepository.listEvents(userId: userId);
    var deletedCount = 0;
    for (final event in events) {
      if (!_isImportedSource(event.source)) {
        continue;
      }
      final startAt = event.startAt;
      if (startAt == null || !_isSuspiciousImportedDate(startAt)) {
        continue;
      }
      try {
        await _eventRepository.deleteEvent(event.id, userId: userId);
        deletedCount += 1;
      } catch (error) {
        debugPrint('Naver ICS cleanup delete failed: ${event.id} / $error');
      }
    }
    return deletedCount;
  }

  bool _isImportedSource(String source) {
    return source == 'naver_caldav' ||
        source == 'naver_ics' ||
        source == 'naver_device' ||
        source == 'device_calendar';
  }

  bool _isSuspiciousImportedDate(DateTime value) {
    return value.toUtc().year < 2000;
  }
}

class NaverIcsParsedEvent {
  const NaverIcsParsedEvent({
    required this.uid,
    required this.title,
    required this.startAt,
    this.endAt,
    this.location,
    this.description,
    this.lastModifiedAt,
  });

  final String? uid;
  final String title;
  final DateTime startAt;
  final DateTime? endAt;
  final String? location;
  final String? description;
  final DateTime? lastModifiedAt;

  String get externalId {
    final normalizedUid = uid?.trim();
    if (normalizedUid != null && normalizedUid.isNotEmpty) {
      return 'naver-ics:uid:$normalizedUid';
    }
    final key =
        '${startAt.toLocal().toIso8601String().split("T").first}:${_normalizeTitle(title)}';
    final digest = sha1.convert(utf8.encode(key)).toString();
    return 'naver-ics:date-title:$digest';
  }
}

class NaverIcsImportResult {
  const NaverIcsImportResult({
    required this.success,
    required this.message,
    this.imported = 0,
    this.skipped = 0,
    this.failed = 0,
    this.total = 0,
    this.sourcePath,
  });

  const NaverIcsImportResult.failure({
    required this.message,
  })  : success = false,
        imported = 0,
        skipped = 0,
        failed = 0,
        total = 0,
        sourcePath = null;

  final bool success;
  final String message;
  final int imported;
  final int skipped;
  final int failed;
  final int total;
  final String? sourcePath;

  NaverIcsImportResult merge(NaverIcsImportResult other) {
    final importedCount = imported + other.imported;
    final skippedCount = skipped + other.skipped;
    final failedCount = failed + other.failed;
    final totalCount = total + other.total;
    return NaverIcsImportResult(
      success:
          success || other.success || importedCount > 0 || skippedCount > 0,
      message: failedCount > 0
          ? '네이버 ICS에서 $importedCount개를 가져오고, $skippedCount개는 중복이라 건너뛰었어요. $failedCount개는 저장하지 못했습니다.'
          : '네이버 ICS에서 $importedCount개를 가져왔어요. 중복 $skippedCount개는 건너뛰었습니다.',
      imported: importedCount,
      skipped: skippedCount,
      failed: failedCount,
      total: totalCount,
      sourcePath: other.sourcePath ?? sourcePath,
    );
  }
}

String? _textProperty(Map<String, String> data, String name) {
  final exact = data[name];
  if (exact != null) {
    return exact;
  }
  for (final entry in data.entries) {
    if (entry.key.split(';').first.toUpperCase() == name) {
      return entry.value;
    }
  }
  return null;
}

DateTime? _dateTimeProperty(Map<String, String> data, String name) {
  String? key;
  String? value;
  for (final entry in data.entries) {
    if (entry.key.split(';').first.toUpperCase() == name) {
      key = entry.key;
      value = entry.value;
      break;
    }
  }
  if (value == null || value.trim().isEmpty) {
    return null;
  }
  return _parseIcsDateTime(value.trim(), key ?? name);
}

DateTime? _parseIcsDateTime(String value, String key) {
  final normalized = value.trim();
  if (RegExp(r'^\d{8}$').hasMatch(normalized)) {
    final year = int.parse(normalized.substring(0, 4));
    final month = int.parse(normalized.substring(4, 6));
    final day = int.parse(normalized.substring(6, 8));
    final localLike = DateTime(year, month, day);
    if (localLike.year != year ||
        localLike.month != month ||
        localLike.day != day) {
      return null;
    }
    final parsed = DateTime.utc(year, month, day);
    return _isSuspiciousImportedDate(parsed) ? null : parsed;
  }

  final match = RegExp(
    r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$',
  ).firstMatch(normalized);
  if (match == null) {
    final parsed = DateTime.tryParse(normalized)?.toUtc();
    if (parsed == null || _isSuspiciousImportedDate(parsed)) {
      return null;
    }
    return parsed;
  }

  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6)!);
  final localLike = DateTime(
    year,
    month,
    day,
    hour,
    minute,
    second,
  );
  if (localLike.year != year ||
      localLike.month != month ||
      localLike.day != day ||
      localLike.hour != hour ||
      localLike.minute != minute ||
      localLike.second != second) {
    return null;
  }
  final isUtc = match.group(7) == 'Z';
  final hasAsiaSeoulTz = key.toUpperCase().contains('TZID=ASIA/SEOUL');
  final parsed = isUtc
      ? DateTime.utc(
          localLike.year,
          localLike.month,
          localLike.day,
          localLike.hour,
          localLike.minute,
          localLike.second,
        )
      : hasAsiaSeoulTz
          ? DateTime.utc(
              localLike.year,
              localLike.month,
              localLike.day,
              localLike.hour - 9,
              localLike.minute,
              localLike.second,
            )
          : localLike.toUtc();
  return _isSuspiciousImportedDate(parsed) ? null : parsed;
}

String _unescapeText(String text) {
  return text
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\N', '\n')
      .replaceAll(r'\,', ',')
      .replaceAll(r'\;', ';')
      .replaceAll('\\\\', '\\')
      .trim();
}

String? _blankToNull(String text) {
  final trimmed = text.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _normalizeTitle(String text) {
  return text.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
}

bool _sameLocalDay(DateTime a, DateTime b) {
  final localA = a.toLocal();
  final localB = b.toLocal();
  return localA.year == localB.year &&
      localA.month == localB.month &&
      localA.day == localB.day;
}

bool _hasProperty(Map<String, String> data, String name) {
  return data.keys.any((key) => key.split(';').first.toUpperCase() == name);
}

bool _isSuspiciousImportedDate(DateTime value) {
  return value.toUtc().year < 2000;
}
