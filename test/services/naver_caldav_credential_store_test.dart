import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/naver_caldav_service.dart';

void main() {
  test('prefers remote credentials without touching local cache', () async {
    final remote = _FakeCredentialStore(
      readValue: const NaverCalDavCredentials(
        naverId: 'remote-id',
        appPassword: 'remote-password',
      ),
    );
    final local = _FakeCredentialStore(
      readValue: const NaverCalDavCredentials(
        naverId: 'local-id',
        appPassword: 'local-password',
      ),
    );
    final store = CompositeNaverCalDavCredentialStore(
      remoteStore: remote,
      localStore: local,
    );

    final credentials = await store.readCredentials();

    expect(credentials?.naverId, 'remote-id');
    expect(credentials?.appPassword, 'remote-password');
    expect(remote.readCount, 1);
    expect(local.readCount, 0);
    expect(remote.saveCount, 0);
    expect(local.saveCount, 0);
  });

  test('migrates local credentials back to remote when remote is empty',
      () async {
    final remote = _FakeCredentialStore();
    final local = _FakeCredentialStore(
      readValue: const NaverCalDavCredentials(
        naverId: 'local-id',
        appPassword: 'local-password',
      ),
    );
    final store = CompositeNaverCalDavCredentialStore(
      remoteStore: remote,
      localStore: local,
    );

    final credentials = await store.readCredentials();

    expect(credentials?.naverId, 'local-id');
    expect(credentials?.appPassword, 'local-password');
    expect(remote.saveCount, 1);
    expect(remote.savedValue?.naverId, 'local-id');
    expect(remote.savedValue?.appPassword, 'local-password');
    expect(local.readCount, 1);
  });

  test('saves credentials to both remote and local stores', () async {
    final remote = _FakeCredentialStore();
    final local = _FakeCredentialStore();
    final store = CompositeNaverCalDavCredentialStore(
      remoteStore: remote,
      localStore: local,
    );

    await store.saveCredentials(
      naverId: 'planflow-id',
      appPassword: 'planflow-password',
    );

    expect(remote.saveCount, 1);
    expect(local.saveCount, 1);
    expect(remote.savedValue?.naverId, 'planflow-id');
    expect(local.savedValue?.appPassword, 'planflow-password');
  });

  test('clears both remote and local stores', () async {
    final remote = _FakeCredentialStore(
      readValue: const NaverCalDavCredentials(
        naverId: 'remote-id',
        appPassword: 'remote-password',
      ),
    );
    final local = _FakeCredentialStore(
      readValue: const NaverCalDavCredentials(
        naverId: 'local-id',
        appPassword: 'local-password',
      ),
    );
    final store = CompositeNaverCalDavCredentialStore(
      remoteStore: remote,
      localStore: local,
    );

    await store.clearCredentials();

    expect(remote.clearCount, 1);
    expect(local.clearCount, 1);
    expect(remote.readValue, isNull);
    expect(local.readValue, isNull);
  });
}

class _FakeCredentialStore extends NaverCalDavCredentialStore {
  _FakeCredentialStore({this.readValue});

  NaverCalDavCredentials? readValue;
  NaverCalDavCredentials? savedValue;
  int readCount = 0;
  int saveCount = 0;
  int clearCount = 0;

  @override
  Future<NaverCalDavCredentials?> readCredentials() async {
    readCount += 1;
    return readValue;
  }

  @override
  Future<void> saveCredentials({
    required String naverId,
    required String appPassword,
  }) async {
    saveCount += 1;
    savedValue = NaverCalDavCredentials(
      naverId: naverId,
      appPassword: appPassword,
    );
    readValue = savedValue;
  }

  @override
  Future<void> clearCredentials() async {
    clearCount += 1;
    readValue = null;
    savedValue = null;
  }
}
