import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../tool/widget_launch_qa/transport_receipt_store.dart';

void main() {
  late Directory dir;
  late File file;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('transport-store-test-');
    file = File('${dir.path}/receipts');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  test(
      'serialized actual filesystem append, boot first, SHA256 mask and no raw fields',
      () async {
    final s = TransportReceiptStore(file: file);
    final futures = [
      s.boot(),
      s.ready(),
      s.record('applinks_initial',
          Uri.parse('planflow://day/2026-10-14?qaNonce=abc&benign=marker')),
      s.record(
          'applinks_warm', Uri.parse('planflow://voice-launcher?qaNonce=warm'))
    ];
    await Future.wait(futures);
    await s.drain();
    final text = await file.readAsString();
    final rows = const LineSplitter()
        .convert(text)
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
    expect(
        rows.map((r) => r['kind']), ['BOOT', 'READY', 'RECEIVED', 'RECEIVED']);
    expect(rows[2]['nonceHash'],
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(text.contains('planflow://'), false);
    expect(text.contains('marker'), false);
    expect(text.contains('qaNonce'), false);
    expect(rows.every((r) => r['pid'] == pid && r['bootId'] == s.bootId), true);
  });
  test('null error and invalid URI never become received', () async {
    final s = TransportReceiptStore(file: file);
    await s.boot();
    await s.record('homewidget_initial', null);
    await s.outcome('applinks_initial', 'ERROR', reason: 'timeout');
    for (final uri in [
      'planflow://day/2026-10-15?qaNonce=abc',
      'planflow://voice-launcher',
      'planflow://voice-launcher?qaNonce=UPPER',
      'https://day/2026-10-14?qaNonce=abc',
      'planflow://voice-launcher?qaNonce=${'a' * 97}'
    ]) {
      await s.record('applinks_warm', Uri.parse(uri));
    }
    expect((await file.readAsString()).contains('RECEIVED'), false);
    await expectLater(
        s.outcome('applinks_initial', 'ERROR', reason: 'benign_marker'),
        throwsStateError);
  });
  test('row overflow fails closed without truncation', () async {
    final s = TransportReceiptStore(file: file);
    await s.boot();
    for (var i = 1; i < transportMaxRows; i++) {
      await s.ready();
    }
    final before = await file.readAsString();
    await expectLater(s.ready(), throwsStateError);
    await expectLater(s.ready(), throwsStateError);
    expect(await file.readAsString(), before);
  });
  test('byte overflow and partial row fail closed', () async {
    for (final content in ['a' * transportMaxBytes, '{']) {
      await file.writeAsString(content);
      final s = TransportReceiptStore(file: file);
      await expectLater(s.boot(), throwsStateError);
      expect(await file.readAsString(), content);
    }
  });
  test('filesystem error and preboot receipt fail closed', () async {
    final s = TransportReceiptStore(file: File('${dir.path}/missing/receipts'));
    await expectLater(s.boot(), throwsA(isA<FileSystemException>()));
    await expectLater(s.ready(), throwsStateError);
    final before = TransportReceiptStore(file: file);
    await expectLater(before.ready(), throwsStateError);
    expect(await file.exists(), false);
  });

  test('sync callbacks buffered until actual BOOT READY flush', () async {
    final s = TransportReceiptStore(file: file);
    final context = TransportSourceContext();
    final epoch = context.epoch;
    await s.boot();
    await context.dispatch(
        epoch,
        () => s.record('applinks_warm',
            Uri.parse('planflow://voice-launcher?qaNonce=sync'),
            active: () => context.valid(epoch)));
    expect((await file.readAsString()).contains('RECEIVED'), false);
    await s.ready();
    await context.ready(epoch);
    expect(
        const LineSplitter()
            .convert(await file.readAsString())
            .map((l) => (jsonDecode(l) as Map)['kind']),
        ['BOOT', 'READY', 'RECEIVED']);
  });
  test('dispose before ready drops buffered and subsequent callback', () async {
    final s = TransportReceiptStore(file: file);
    final context = TransportSourceContext();
    final epoch = context.epoch;
    await s.boot();
    await context.dispatch(
        epoch,
        () => s.record('applinks_warm',
            Uri.parse('planflow://voice-launcher?qaNonce=buffered')));
    context.dispose();
    await s.ready();
    await context.ready(epoch);
    await context.dispatch(
        context.epoch,
        () => s.record('applinks_warm',
            Uri.parse('planflow://voice-launcher?qaNonce=late')));
    expect((await file.readAsString()).contains('RECEIVED'), false);
  });
  test('deferred getter and queued flush invalidated by dispose', () async {
    final s = TransportReceiptStore(file: file);
    final context = TransportSourceContext();
    final epoch = context.epoch;
    await s.boot();
    await s.ready();
    await context.ready(epoch);
    final getter = Completer<Uri?>();
    final deferred = getter.future.then((uri) => context.dispatch(
        epoch,
        () => s.record('applinks_initial', uri,
            active: () => context.valid(epoch))));
    final queued = s.record(
        'applinks_warm', Uri.parse('planflow://voice-launcher?qaNonce=queued'),
        active: () => context.valid(epoch));
    context.dispose();
    getter.complete(Uri.parse('planflow://day/2026-10-14?qaNonce=late'));
    await Future.wait([deferred, queued]);
    await s.drain();
    expect((await file.readAsString()).contains('RECEIVED'), false);
  });
}
