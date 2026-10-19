import 'package:shared_preferences/shared_preferences.dart';

/// 本地持久化的会话信息（服务器地址 + 登录凭据 + 上次的昵称 + 记住的房间密码）。
class StoredSession {
  const StoredSession({
    this.serverAddress,
    this.accessToken,
    this.username,
    this.displayName,
    this.password,
    this.roomPasswords = const <String, String>{},
  });

  final String? serverAddress;
  final String? accessToken;
  final String? username;
  final String? displayName;

  /// 记住的登录密码：下次打开连接页直接回填，不用重新输。
  final String? password;

  /// 记住的房间密码：`roomId → 密码`。
  final Map<String, String> roomPasswords;

  bool get hasToken => accessToken != null && accessToken!.isNotEmpty;
}

/// 基于 shared_preferences 的轻量存储。
class SessionStore {
  static const _serverKey = 'omioclink.server_address';
  static const _tokenKey = 'omioclink.access_token';
  static const _usernameKey = 'omioclink.username';
  static const _displayNameKey = 'omioclink.display_name';
  static const _passwordKey = 'omioclink.password';
  static const _roomPasswordPrefix = 'omioclink.room_password.';

  Future<StoredSession> load() async {
    final prefs = await SharedPreferences.getInstance();
    final roomPasswords = <String, String>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_roomPasswordPrefix)) {
        continue;
      }
      final value = prefs.getString(key);
      if (value == null || value.isEmpty) {
        continue;
      }
      roomPasswords[key.substring(_roomPasswordPrefix.length)] = value;
    }
    return StoredSession(
      serverAddress: prefs.getString(_serverKey),
      accessToken: prefs.getString(_tokenKey),
      username: prefs.getString(_usernameKey),
      displayName: prefs.getString(_displayNameKey),
      password: prefs.getString(_passwordKey),
      roomPasswords: roomPasswords,
    );
  }

  Future<void> saveServerAddress(String address) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverKey, address);
  }

  /// 保存登录凭据。[password] 省略时保留原先记住的密码。
  Future<void> saveAuth({
    required String accessToken,
    required String username,
    String? displayName,
    String? password,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, accessToken);
    await prefs.setString(_usernameKey, username);
    if (displayName != null) {
      await prefs.setString(_displayNameKey, displayName);
    }
    if (password != null && password.isNotEmpty) {
      await prefs.setString(_passwordKey, password);
    }
  }

  /// 退出登录只清令牌：服务器地址、用户名与记住的密码都留着，下次不用重输。
  Future<void> clearAuth() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

  /// 记住某个房间的密码（房间被删除或密码失效时用 [clearRoomPassword] 清掉）。
  Future<void> saveRoomPassword(String roomId, String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_roomPasswordPrefix$roomId', password);
  }

  Future<void> clearRoomPassword(String roomId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_roomPasswordPrefix$roomId');
  }
}
