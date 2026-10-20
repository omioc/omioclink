import 'dart:io';

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

  group('手机端的 JSON 副本（安卓上 prefs 会静默失手）', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omioclink-session-test-');
    });

    tearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    String mirrorPath() => '${dir.path}${Platform.pathSeparator}session.json';

    test('prefs 里什么都没了（杀的进程/读不出来），地址与账号密码仍能读回', () async {
      final path = mirrorPath();
      final store = SessionStore(mirrorPath: path);
      await store.saveServerAddress('10.0.0.2:21077');
      await store.saveAuth(
        accessToken: 'token-1',
        username: 'alice',
        password: 'password123',
      );

      // 杀掉进程再进来：prefs 这一侧什么都没留下
      SharedPreferences.setMockInitialValues(<String, Object>{});

      final stored = await SessionStore(mirrorPath: path).load();
      expect(stored.serverAddress, '10.0.0.2:21077');
      expect(stored.username, 'alice');
      expect(stored.password, 'password123');
      expect(stored.hasToken, isTrue);
    });

    test('退出登录只清副本里的令牌，地址/用户名/密码还在', () async {
      final path = mirrorPath();
      final store = SessionStore(mirrorPath: path);
      await store.saveServerAddress('10.0.0.2:21077');
      await store.saveAuth(
        accessToken: 'token-1',
        username: 'alice',
        password: 'password123',
      );

      await store.clearAuth();

      final stored = await SessionStore(mirrorPath: path).load();
      expect(stored.hasToken, isFalse);
      expect(stored.serverAddress, '10.0.0.2:21077');
      expect(stored.username, 'alice');
      expect(stored.password, 'password123');
    });

    test('从老版本升级（只有 prefs）时，第一次读就把数据搬进副本', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'omioclink.server_address': '1.2.3.4:21077',
        'omioclink.username': 'bob',
        'omioclink.password': 'password123',
      });
      final path = mirrorPath();
      final first = await SessionStore(mirrorPath: path).load();
      expect(first.username, 'bob');
      expect(File(path).existsSync(), isTrue, reason: '读完要顺手落一份副本');

      SharedPreferences.setMockInitialValues(<String, Object>{});
      final stored = await SessionStore(mirrorPath: path).load();
      expect(stored.serverAddress, '1.2.3.4:21077');
      expect(stored.username, 'bob');
      expect(stored.password, 'password123');
    });

    test('记住的房间密码也跟着副本走', () async {
      final path = mirrorPath();
      await SessionStore(mirrorPath: path).saveRoomPassword('ABC123', 'room-pw');

      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(
        (await SessionStore(mirrorPath: path).load()).roomPasswords,
        <String, String>{'ABC123': 'room-pw'},
      );

      await SessionStore(mirrorPath: path).clearRoomPassword('ABC123');
      expect(
        (await SessionStore(mirrorPath: path).load()).roomPasswords,
        isEmpty,
      );
    });
  });
}
