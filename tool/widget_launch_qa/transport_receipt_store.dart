// QA-only file evidence, with no production initialization.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';

const transportReceiptName = 'widget-transport-receipts.jsonl';
const transportMaxBytes = 128 * 1024;
const transportMaxRows = 128;
const transportSources = {
  'applinks_initial',
  'applinks_warm',
  'homewidget_initial',
  'homewidget_warm'
};

// Pure lifecycle gate: captured callback data stays in memory until READY flush.
class TransportSourceContext {
  int _epoch = 0;
  bool _live = true;
  bool _ready = false;
  final List<Future<void> Function()> _pending = [];
  int get epoch => _epoch;
  bool valid(int epoch) => _live && epoch == _epoch;
  Future<void> dispatch(int epoch, Future<void> Function() action) async {
    if (!valid(epoch)) return;
    if (!_ready) {
      if (_pending.length >= transportMaxRows) throw StateError('buffer_limit');
      _pending.add(() async {
        if (valid(epoch)) await action();
      });
      return;
    }
    await action();
  }

  Future<void> ready(int epoch) async {
    if (!valid(epoch)) return;
    _ready = true;
    final pending = List<Future<void> Function()>.of(_pending);
    _pending.clear();
    for (final action in pending) {
      if (valid(epoch)) await action();
    }
  }

  void dispose() {
    _live = false;
    _epoch++;
    _pending.clear();
  }
}

class TransportReceiptStore {
  TransportReceiptStore({File? file})
      : file =
            file ?? File('${Directory.systemTemp.path}/$transportReceiptName'),
        bootId = List.generate(
            16,
            (_) => Random.secure()
                .nextInt(256)
                .toRadixString(16)
                .padLeft(2, '0')).join();
  final File file;
  final String bootId;
  Future<void> _tail = Future<void>.value();
  bool _failed = false;
  bool _booted = false;
  Future<void> drain() => _tail;
  Future<void> boot() => _append('BOOT');
  Future<void> ready() => _append('READY');
  Future<void> outcome(String source, String kind,
      {String? reason, bool Function()? active}) {
    if (!transportSources.contains(source) ||
        !{'NULL', 'ERROR'}.contains(kind) ||
        (kind == 'ERROR' &&
            !{'timeout', 'plugin', 'stream'}.contains(reason)) ||
        (kind == 'NULL' && reason != null)) {
      return Future<void>.error(StateError('invalid_receipt'));
    }
    return _append(kind, source: source, reason: reason, active: active);
  }

  Future<void> record(String source, Uri? uri, {bool Function()? active}) {
    if (active != null && !active()) return Future<void>.value();
    if (!transportSources.contains(source)) {
      return Future<void>.error(StateError('invalid_source'));
    }
    if (uri == null) return outcome(source, 'NULL', active: active);
    final nonce = uri.queryParameters['qaNonce'];
    final target = uri.scheme == 'planflow' &&
            uri.host == 'day' &&
            uri.path == '/2026-10-14'
        ? 'calendar'
        : uri.scheme == 'planflow' &&
                uri.host == 'voice-launcher' &&
                uri.path.isEmpty
            ? 'voice'
            : null;
    if (nonce == null ||
        nonce.length > 96 ||
        !RegExp(r'^[a-z0-9_]+$').hasMatch(nonce) ||
        target == null) {
      return Future<void>.value();
    }
    return _append('RECEIVED',
        source: source,
        target: target,
        nonceHash: sha256.convert(utf8.encode(nonce)).toString(),
        active: active);
  }

  Future<void> _append(String kind,
      {String? source,
      String? target,
      String? nonceHash,
      String? reason,
      bool Function()? active}) {
    final next = _tail.then((_) async {
      if (active != null && !active()) return;
      if (_failed ||
          (kind != 'BOOT' && !_booted) ||
          (kind == 'BOOT' && _booted)) {
        throw StateError('sink_failed');
      }
      final row = <String, Object>{
        'kind': kind,
        'bootId': bootId,
        'pid': pid,
        if (source != null) 'source': source,
        if (target != null) 'target': target,
        if (nonceHash != null) 'nonceHash': nonceHash,
        if (reason != null) 'reason': reason
      };
      final line = '${jsonEncode(row)}\n';
      final exists = await file.exists();
      final length = exists ? await file.length() : 0;
      if (length > transportMaxBytes ||
          length + utf8.encode(line).length > transportMaxBytes) {
        throw StateError('sink_limit');
      }
      if (exists) {
        final previous = await file.readAsString();
        if (previous.isNotEmpty && !previous.endsWith('\n')) {
          throw StateError('sink_invalid');
        }
        if ('\n'.allMatches(previous).length >= transportMaxRows) {
          throw StateError('sink_limit');
        }
      }
      if (active != null && !active()) return;
      await file.writeAsString(line, mode: FileMode.append, flush: true);
      if (kind == 'BOOT') _booted = true;
    });
    _tail = next.catchError((Object _) {
      _failed = true;
    });
    return next;
  }
}
