import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/data/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('保存服务器地址与登录凭据后能原样读回（含密码）', () async {
    final store = SessionStore();
    await store.saveServerAddress('sv.example.com:21077');
    await store.saveAuth(
      accessToken: 'token-1',
      username: 'alice',
      displayName: '小明',
      password: 'password123',
    );

    final stored = await store.load();
    expect(stored.serverAddress, 'sv.example.com:21077');
    expect(stored.username, 'alice');
    expect(stored.displayName, '小明');
    expect(stored.password, 'password123');
    expect(stored.hasToken, isTrue);
  });

  test('不带密码保存时保留已记住的密码（改昵称、换令牌都走这条路）', () async {
    final store = SessionStore();
    await store.saveAuth(
      accessToken: 'token-1',
      username: 'alice',
      password: 'password123',
    );
    await store.saveAuth(
      accessToken: 'token-2',
      username: 'alice',
      displayName: '小明',
    );

    final stored = await store.load();
    expect(stored.accessToken, 'token-2');
    expect(stored.password, 'password123', reason: '省略 password 不应该把记住的密码冲掉');
  });

  test('退出登录只清令牌：地址、用户名与密码留着，下次不用重输', () async {
    final store = SessionStore();
    await store.saveServerAddress('sv.example.com:21077');
    await store.saveAuth(
      accessToken: 'token-1',
      username: 'alice',
      password: 'password123',
    );

    await store.clearAuth();

    final stored = await store.load();
    expect(stored.hasToken, isFalse);
    expect(stored.serverAddress, 'sv.example.com:21077');
    expect(stored.username, 'alice');
    expect(stored.password, 'password123');
  });

  test('房间密码按房间分开存，能单独清除', () async {
    final store = SessionStore();
    await store.saveRoomPassword('ABC123', 'room-pw');
    await store.saveRoomPassword('XYZ789', 'other-pw');

    var stored = await store.load();
    expect(stored.roomPasswords, <String, String>{
      'ABC123': 'room-pw',
      'XYZ789': 'other-pw',
    });

    await store.clearRoomPassword('ABC123');
    stored = await store.load();
    expect(stored.roomPasswords, <String, String>{'XYZ789': 'other-pw'});
  });

  test('同一房间重新记住密码会覆盖旧的', () async {
    final store = SessionStore();
    await store.saveRoomPassword('ABC123', 'old-pw');
    await store.saveRoomPassword('ABC123', 'new-pw');

    expect((await store.load()).roomPasswords['ABC123'], 'new-pw');
  });
}
