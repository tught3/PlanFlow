// Tests for the voice-first practice tour controller.
//
// SIMULATED TRANSCRIPTS: every Korean string below is a typed test input,
// NOT acoustic ASR output. No native plugin or microphone is involved.
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueChanged;
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/onboarding/voice_first_tour_controller.dart';
import 'package:planflow/screens/onboarding/voice_first_tour_voice_capture.dart';

void main() {
  // Frozen tour session reference: Sunday 2026-10-18 09:00.
  final DateTime ref = DateTime(2026, 10, 18, 9, 0);

  VoiceFirstTourController buildController() =>
      VoiceFirstTourController(nowProvider: () => ref);

  group('SIMULATED transcripts (typed strings, not acoustic ASR)', () {
    test('create → staged preview → save → query → edit preview → save', () {
      final controller = buildController();

      // CREATE: preview is staged, saved state untouched.
      final outcome = controller.applyTranscript('내일 오전9시에 강남역에서 팀장님과 면담');
      final add = outcome.addDraft;
      expect(add, isNotNull);
      expect(add!.title, '강남역 팀장님과 면담');
      expect(add.date, DateTime(2026, 10, 19));
      expect(add.time, const TimeOfDay(hour: 9, minute: 0));
      expect(add.location, '강남역');
      expect(controller.events, isEmpty);
      expect(controller.hasPending, isTrue);

      // Explicit save commits exactly once.
      expect(controller.savePending(), 1);
      expect(controller.hasPending, isFalse);
      expect(controller.events.single.eventTime, DateTime(2026, 10, 19, 9));
      // Example assumptions: travel 20 + buffer 10, prep 15.
      expect(controller.events.single.departure, DateTime(2026, 10, 19, 8, 30));
      expect(
        controller.events.single.preparation,
        DateTime(2026, 10, 19, 8, 15),
      );

      // QUERY: rendered list binds the ordinal.
      final query = controller.applyTranscript('내일 일정보여줘');
      expect(query.queryRange, isNotNull);
      expect(query.queryRange!.start, DateTime(2026, 10, 19));
      expect(query.queryRange!.end, DateTime(2026, 10, 20));
      expect(controller.lastQueryEvents.map((e) => e.id).toList(), [1]);

      // EDIT: preview only, original record untouched before save.
      final edit = controller.applyTranscript('첫번째일정 오후1시로 미뤄줘');
      expect(edit.editTarget, isNotNull);
      expect(edit.editTarget!.ordinalIndex, 1);
      expect(edit.editTarget!.newTime, const TimeOfDay(hour: 13, minute: 0));
      final pending = controller.pendingEdit;
      expect(pending, isNotNull);
      expect(pending!.eventId, 1);
      expect(pending.originalEvent.eventTime, DateTime(2026, 10, 19, 9));
      expect(controller.events.single.eventTime, DateTime(2026, 10, 19, 9));
      expect(controller.events.single.departure, DateTime(2026, 10, 19, 8, 30));

      // Second explicit save: time-only edit keeps date/title/location and
      // recomputes the derived departure/preparation (12:30 / 12:15).
      expect(controller.savePending(), 1);
      final updated = controller.events.single;
      expect(updated.eventTime, DateTime(2026, 10, 19, 13));
      expect(updated.departure, DateTime(2026, 10, 19, 12, 30));
      expect(updated.preparation, DateTime(2026, 10, 19, 12, 15));
      expect(updated.title, '강남역 팀장님과 면담');
      expect(updated.location, '강남역');
      expect(updated.eventTime.day, 19);
    });

    test('missing or invalid input is rejected and preserves saved state', () {
      final controller = buildController();
      expect(
        controller.applyTranscript('안녕하세요').unsupported,
        isNotNull,
      );
      // No time.
      expect(
        controller.applyTranscript('내일 팀장님과 면담').unsupported,
        isNotNull,
      );
      // No date.
      expect(
        controller.applyTranscript('오전 9시에 미팅').unsupported,
        isNotNull,
      );
      expect(controller.events, isEmpty);
      expect(controller.hasPending, isFalse);
      expect(controller.savePending(), isNull);

      // A new unsupported utterance supersedes a staged preview.
      expect(
        controller.applyTranscript('내일 오후 3시에 병원 예약').addDraft,
        isNotNull,
      );
      expect(controller.pendingAdd, isNotNull);
      expect(
        controller.applyTranscript('안녕하세요').unsupported,
        isNotNull,
      );
      expect(controller.pendingAdd, isNull);
      expect(controller.savePending(), isNull);
      expect(controller.events, isEmpty);
    });

    test('Korean spacing and numeric variants parse to the same draft', () {
      final controller = buildController();
      final spaced = controller.applyTranscript('내일 오전 9시에 강남역에서 팀장님과 면담');
      expect(spaced.addDraft!.date, DateTime(2026, 10, 19));
      expect(spaced.addDraft!.time, const TimeOfDay(hour: 9, minute: 0));
      final tight = controller.applyTranscript('내일오전 9시에 강남역에서 팀장님과 면담');
      expect(tight.addDraft!.date, DateTime(2026, 10, 19));
      expect(tight.addDraft!.time, const TimeOfDay(hour: 9, minute: 0));
      controller.discardPending();

      // Ordinal edits require a rendered query list first.
      expect(
        controller.applyTranscript('내일 오전 9시에 미팅').addDraft,
        isNotNull,
      );
      expect(controller.savePending(), 1);
      controller.applyTranscript('내일 일정보여줘');

      final spacedOrdinal = controller.applyTranscript('첫 번째 일정 오후 1시로 미뤄줘');
      expect(spacedOrdinal.editTarget!.ordinalIndex, 1);
      expect(
        spacedOrdinal.editTarget!.newTime,
        const TimeOfDay(hour: 13, minute: 0),
      );
      controller.discardPending();
      final digitOrdinal = controller.applyTranscript('1번째일정 오후1시로 미뤄줘');
      expect(digitOrdinal.editTarget!.ordinalIndex, 1);
      controller.discardPending();

      final query = controller.applyTranscript('내일 일정 보여줘');
      expect(query.queryRange, isNotNull);
      expect(query.queryRange!.start, DateTime(2026, 10, 19));
    });

    test('relative date is frozen per session across midnight', () {
      var now = DateTime(2026, 10, 18, 23, 59);
      final controller = VoiceFirstTourController(nowProvider: () => now);
      final before = controller.applyTranscript('내일 오전 9시에 미팅');
      expect(before.addDraft!.date, DateTime(2026, 10, 19));
      // Wall clock crosses midnight: the session reference must NOT move.
      now = DateTime(2026, 10, 19, 0, 1);
      final after = controller.applyTranscript('내일 오전 9시에 미팅');
      expect(after.addDraft!.date, DateTime(2026, 10, 19));
      expect(controller.sessionNow, DateTime(2026, 10, 18, 23, 59));
    });

    test('ordinal binds to the rendered sorted list, not insertion order',
        () {
      final controller = buildController();
      // Inserted first but LATER in the day.
      expect(
        controller.applyTranscript('내일 오후 8시에 저녁 약속').addDraft,
        isNotNull,
      );
      expect(controller.savePending(), 1);
      // Inserted second but EARLIER in the day.
      expect(
        controller.applyTranscript('내일 오전 9시에 아침 미팅').addDraft,
        isNotNull,
      );
      expect(controller.savePending(), 2);

      controller.applyTranscript('내일 일정보여줘');
      expect(controller.lastQueryEvents.map((e) => e.id).toList(), [2, 1]);

      // "두번째" must target the SECOND rendered row (id 1), not event 2.
      expect(
        controller.applyTranscript('두번째일정 오전 11시로 당겨줘').editTarget,
        isNotNull,
      );
      expect(controller.pendingEdit!.eventId, 1);
      expect(controller.savePending(), 1);
      expect(controller.findById(1)!.eventTime, DateTime(2026, 10, 19, 11));
      // id 2 was the 09:00 morning meeting and must stay untouched.
      expect(controller.findById(2)!.eventTime, DateTime(2026, 10, 19, 9));
    });

    test('edit without a rendered query list is rejected', () {
      final controller = buildController();
      expect(
        controller.applyTranscript('내일 오전 9시에 미팅').addDraft,
        isNotNull,
      );
      controller.savePending();
      final outcome = controller.applyTranscript('첫번째일정 오후 5시로 미뤄줘');
      expect(outcome.unsupported, isNotNull);
      expect(controller.events.single.eventTime, DateTime(2026, 10, 19, 9));
      expect(controller.hasPending, isFalse);
    });

    test('out-of-range ordinal is rejected without touching saved state', () {
      final controller = buildController();
      expect(
        controller.applyTranscript('내일 오전 9시에 미팅').addDraft,
        isNotNull,
      );
      controller.savePending();
      controller.applyTranscript('내일 일정보여줘');
      final outcome = controller.applyTranscript('세번째일정 오후 2시로 미뤄줘');
      expect(outcome.unsupported, isNotNull);
      expect(controller.hasPending, isFalse);
      expect(controller.events.single.eventTime, DateTime(2026, 10, 19, 9));
    });

    test('restart clears events, rendered list and staged previews', () {
      final controller = buildController();
      controller.applyTranscript('내일 오전 9시에 미팅');
      controller.savePending();
      controller.applyTranscript('내일 일정보여줘');
      controller.applyTranscript('첫번째일정 오후 3시로 미뤄줘');
      expect(controller.hasPending, isTrue);

      controller.restart();
      expect(controller.events, isEmpty);
      expect(controller.lastQueryEvents, isEmpty);
      expect(controller.hasPending, isFalse);
      expect(controller.savePending(), isNull);
      expect(
        controller.applyTranscript('첫번째일정 오후 3시로 미뤄줘').unsupported,
        isNotNull,
      );
      // Ids are never reused across restarts.
      controller.applyTranscript('내일 오전 10시에 후속 미팅');
      expect(controller.savePending(), 2);
    });

    test('duplicate saves are guarded', () {
      final controller = buildController();
      controller.applyTranscript('내일 오전 9시에 미팅');
      expect(controller.savePending(), 1);
      expect(controller.savePending(), isNull);
      expect(controller.events.length, 1);

      controller.applyTranscript('내일 일정보여줘');
      controller.applyTranscript('첫번째일정 오후 1시로 미뤄줘');
      expect(controller.savePending(), 1);
      // Second save of the same preview is a no-op: time must not shift.
      expect(controller.savePending(), isNull);
      expect(controller.events.single.eventTime, DateTime(2026, 10, 19, 13));
    });
  });

  group('glue: capture result feeds the controller (SIMULATED)', () {
    test('final transcript flows through the capture seam into a save',
        () async {
      final controller = buildController();
      final capture = FakeVoiceCapture();
      final partials = <String>[];
      final future = capture.listen(onPartial: partials.add);
      await capture.completeWith('내일 오전9시에 강남역에서 팀장님과 면담');
      final result = await future;
      expect(result.isSuccess, isTrue);
      expect(partials, isNotEmpty); // partials were display-only

      final outcome = controller.applyTranscript(result.text!);
      expect(outcome.addDraft, isNotNull);
      expect(controller.savePending(), 1);
      expect(controller.events.single.eventTime, DateTime(2026, 10, 19, 9));
    });

    test('cancelled capture rejects stale text and keeps saved state',
        () async {
      final controller = buildController();
      final capture = FakeVoiceCapture();
      final future = capture.listen(onPartial: (_) {});
      await capture.cancelWithPending();
      final result = await future;
      expect(result.isSuccess, isFalse);

      // Saved state still works after a cancel.
      expect(
        controller.applyTranscript('내일 오전 9시에 미팅').addDraft,
        isNotNull,
      );
      expect(controller.savePending(), 1);
    });
  });
}

/// Deterministic test double for the [VoiceCapture] seam.
class FakeVoiceCapture implements VoiceCapture {
  Completer<VoiceCaptureResult>? _pending;
  ValueChanged<String>? _onPartial;

  @override
  bool get isListening => _pending != null && !_pending!.isCompleted;

  @override
  Future<VoiceCaptureResult> listen({
    required ValueChanged<String> onPartial,
    ValueChanged<bool>? onReady,
  }) {
    _onPartial = onPartial;
    final completer = Completer<VoiceCaptureResult>();
    _pending = completer;
    return completer.future;
  }

  Future<void> completeWith(String text) async {
    _onPartial?.call('$text (입력 중)');
    _pending!.complete(VoiceCaptureResult(text: text));
  }

  Future<void> cancelWithPending() async {
    _pending!.complete(
      const VoiceCaptureResult(silence: true, message: '취소했어요.'),
    );
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() => cancelWithPending();
}
