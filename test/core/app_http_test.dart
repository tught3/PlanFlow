import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:planflow/core/app_http.dart';

void main() {
  test('factory is isolated to its asynchronous zone', () async {
    final first = MockClient((_) async => http.Response('first', 200));
    final second = MockClient((_) async => http.Response('second', 200));

    final firstBody = await AppHttp.runWithFactory(
      () => first,
      () async => (await AppHttp.create().get(Uri.https('example.test'))).body,
    );
    final secondBody = await AppHttp.runWithFactory(
      () => second,
      () async => (await AppHttp.create().get(Uri.https('example.test'))).body,
    );

    expect(firstBody, 'first');
    expect(secondBody, 'second');
    first.close();
    second.close();
  });

  test('temporary override restores its previous factory', () {
    final first = MockClient((_) async => http.Response('first', 200));
    final second = MockClient((_) async => http.Response('second', 200));
    AppHttp.overrideFactory(() => first);
    final previous = AppHttp.overrideFactory(() => second);

    expect(AppHttp.create(), same(second));
    AppHttp.overrideFactory(previous);
    expect(AppHttp.create(), same(first));
    AppHttp.overrideFactory(null);
    first.close();
    second.close();
  });
}
