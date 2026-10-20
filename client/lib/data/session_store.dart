import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_log.dart';
import '../core/app_paths.dart';
import '../core/platform.dart';

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

  /// 从手机端那份 JSON 副本读回。
  ///
  /// 字段缺失或类型不对一律当「没有」：副本可能被手改坏，也可能是更早的版本
  /// 写下的——读不出那一个字段而已，不该把整份会话一起丢掉。
  factory StoredSession.fromJson(Map<String, Object?> json) {
    String? text(String key) {
      final value = json[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    final rooms = <String, String>{};
    final rawRooms = json['roomPasswords'];
    if (rawRooms is Map) {
      rawRooms.forEach((key, value) {
        if (key is String && value is String && value.isNotEmpty) {
          rooms[key] = value;
        }
      });
    }
    return StoredSession(
      serverAddress: text('serverAddress'),
      accessToken: text('accessToken'),
      username: text('username'),
      displayName: text('displayName'),
      password: text('password'),
      roomPasswords: rooms,
    );
  }

  final String? serverAddress;
  final String? accessToken;
  final String? username;
  final String? displayName;

  /// 记住的登录密码：下次打开连接页直接回填，不用重新输。
  final String? password;

  /// 记住的房间密码：`roomId → 密码`。
  final Map<String, String> roomPasswords;

  bool get hasToken => accessToken != null && accessToken!.isNotEmpty;

  /// 这份会话是不是什么都没存（用来判断要不要把 prefs 里的老数据搬过来）。
  bool get isEmpty =>
      serverAddress == null &&
      accessToken == null &&
      username == null &&
      displayName == null &&
      password == null &&
      roomPasswords.isEmpty;

  /// 只换传进来的字段，其余原样保留；传 null 表示「这个字段不动」。
  ///
  /// 清令牌不走这里：[SessionStore.clearAuth] 要的是把令牌**置空**，
  /// 和「不动」是两回事，所以那边自己构造一份。
  StoredSession copyWith({
    String? serverAddress,
    String? accessToken,
    String? username,
    String? displayName,
    String? password,
    Map<String, String>? roomPasswords,
  }) => StoredSession(
    serverAddress: serverAddress ?? this.serverAddress,
    accessToken: accessToken ?? this.accessToken,
    username: username ?? this.username,
    displayName: displayName ?? this.displayName,
    password: password ?? this.password,
    roomPasswords: roomPasswords ?? this.roomPasswords,
  );

  /// 写进手机的 JSON 副本：空字段直接省掉，文件里一眼看得出存了什么。
  Map<String, Object?> toJson() => <String, Object?>{
    if (serverAddress != null) 'serverAddress': serverAddress,
    if (accessToken != null) 'accessToken': accessToken,
    if (username != null) 'username': username,
    if (displayName != null) 'displayName': displayName,
    if (password != null) 'password': password,
    if (roomPasswords.isNotEmpty) 'roomPasswords': roomPasswords,
  };
}

/// 本地会话的读写。
///
/// 桌面端只有 `shared_preferences` 一份；手机端那份 JSON 见 [_defaultMirrorPath]。
/// 手机端为什么另存一份文件：安卓上 prefs 会**静默**失手——读不出来时连接页就
/// 回落到硬编码的默认地址、账号密码全空（退出登录时明明还留着，杀掉进程再进来
/// 就没了），写不进去时同样什么都不留。这里存的又恰好是用户找不回来的东西：
/// 服务器地址是别人给的、密码忘了只能重新问一遍。相比之下多写一个几百字节的
/// 文件代价可以忽略，而它落的应用私有目录（日志、壁纸、插件缓存都写在那儿）
/// 在手机上一直工作正常。
///
/// 生效的始终只有一份，不两边并写：哪一份读得到就以哪一份为准（见 [_read]），
/// 写的时候先写 JSON，写不进去才退回 prefs（见 [_write]）。
class SessionStore {
  SessionStore({String? mirrorPath})
    : _mirrorPath = mirrorPath ?? _defaultMirrorPath();

  static const _serverKey = 'omioclink.server_address';
  static const _tokenKey = 'omioclink.access_token';
  static const _usernameKey = 'omioclink.username';
  static const _displayNameKey = 'omioclink.display_name';
  static const _passwordKey = 'omioclink.password';
  static const _roomPasswordPrefix = 'omioclink.room_password.';

  /// 手机端会话副本的落点；桌面端返回 null——那边的 prefs 一直好用，
  /// 不给自己多留一份可能不一致的副本。
  static String? _defaultMirrorPath() =>
      isMobilePlatform ? AppPaths.join('session.json') : null;

  final String? _mirrorPath;

  Future<StoredSession> load() => _read();

  Future<void> saveServerAddress(String address) =>
      _update((current) => current.copyWith(serverAddress: address));

  /// 保存登录凭据。[password] 省略时保留原先记住的密码。
  Future<void> saveAuth({
    required String accessToken,
    required String username,
    String? displayName,
    String? password,
  }) => _update(
    (current) => current.copyWith(
      accessToken: accessToken,
      username: username,
      displayName: displayName,
      // 改昵称、换令牌都不带密码：这里的 null 就是 copyWith 的「不动」
      password: (password != null && password.isNotEmpty) ? password : null,
    ),
  );

  /// 退出登录只清令牌：服务器地址、用户名与记住的密码都留着，下次不用重输。
  Future<void> clearAuth() async {
    await _update(
      (current) => StoredSession(
        serverAddress: current.serverAddress,
        username: current.username,
        displayName: current.displayName,
        password: current.password,
        roomPasswords: current.roomPasswords,
      ),
    );
    if (_mirrorPath != null) {
      // 手机端 prefs 退成了「迁移来源」：顺手把里面残留的令牌清掉，否则哪天
      // 副本被删、或者装回老版本，会拿着已经退出的令牌自动登录
      await _removePrefsToken();
    }
  }

  /// 记住某个房间的密码（房间被删除或密码失效时用 [clearRoomPassword] 清掉）。
  Future<void> saveRoomPassword(String roomId, String password) => _update(
    (current) => current.copyWith(
      roomPasswords: <String, String>{
        ...current.roomPasswords,
        roomId: password,
      },
    ),
  );

  Future<void> clearRoomPassword(String roomId) => _update((current) {
    final rooms = Map<String, String>.of(current.roomPasswords)..remove(roomId);
    return current.copyWith(roomPasswords: rooms);
  });

  // ------------------------------------------------------------------ 读写
  /// 读一份会话：手机端优先 JSON 副本，没有（或读坏了）才回落到 prefs。
  ///
  /// 回落到 prefs 且里面确实有东西时顺手落一份副本——升级上来的用户 prefs 里还
  /// 留着地址与账号密码，搬过去之前 prefs 一旦失手，这些就真没了。
  Future<StoredSession> _read() async {
    final mirror = await _readMirror();
    if (mirror != null) {
      return mirror;
    }
    final prefs = await _readPrefs();
    if (_mirrorPath != null && !prefs.isEmpty) {
      await _writeMirror(prefs);
    }
    return prefs;
  }

  /// 读当前会话 → 应用 [change] → 写回。
  ///
  /// 会话是一整份模型（写 JSON 时本来就得整份重写），所以每次改动都先读一遍，
  /// 免得把没传进来的字段冲掉。
  Future<void> _update(
    StoredSession Function(StoredSession current) change,
  ) async => _write(change(await _read()));

  Future<void> _write(StoredSession session) async {
    if (_mirrorPath != null && await _writeMirror(session)) {
      return;
    }
    await _writePrefs(session);
  }

  /// 读 prefs。存储本身失手（少数安卓机上会抛）就按「什么都没存过」处理：
  /// 连接页宁可停在默认值上，也不能因为一个读不出来的偏好卡住整次启动。
  Future<StoredSession> _readPrefs() async {
    try {
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
    } on Object catch (error) {
      AppLog.warn('读取本地会话失败', error: error);
      return const StoredSession();
    }
  }

  /// 整份写进 prefs：会话是完整模型，缺哪个字段就该把哪个键删掉
  /// （退出登录清令牌、密码失效清房间密码都走这条路）。
  Future<void> _writePrefs(StoredSession session) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _putPrefsString(prefs, _serverKey, session.serverAddress);
      await _putPrefsString(prefs, _tokenKey, session.accessToken);
      await _putPrefsString(prefs, _usernameKey, session.username);
      await _putPrefsString(prefs, _displayNameKey, session.displayName);
      await _putPrefsString(prefs, _passwordKey, session.password);
      for (final key in prefs.getKeys().toList(growable: false)) {
        if (!key.startsWith(_roomPasswordPrefix)) {
          continue;
        }
        final roomId = key.substring(_roomPasswordPrefix.length);
        if (session.roomPasswords.containsKey(roomId)) {
          continue;
        }
        await prefs.remove(key);
      }
      for (final entry in session.roomPasswords.entries) {
        await prefs.setString('$_roomPasswordPrefix${entry.key}', entry.value);
      }
    } on Object catch (error) {
      AppLog.warn('保存本地会话失败', error: error);
    }
  }

  Future<void> _putPrefsString(
    SharedPreferences prefs,
    String key,
    String? value,
  ) async {
    if (value == null || value.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, value);
    }
  }

  Future<void> _removePrefsToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_tokenKey);
    } on Object catch (error) {
      AppLog.warn('清除本地令牌失败', error: error);
    }
  }

  /// 读手机端那份 JSON；没有这个文件或者读坏了都返回 null，让调用方回落。
  Future<StoredSession?> _readMirror() async {
    final path = _mirrorPath;
    if (path == null) {
      return null;
    }
    try {
      final file = File(path);
      if (!await file.exists()) {
        return null;
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return null;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      return StoredSession.fromJson(Map<String, Object?>.from(decoded));
    } on Object catch (error) {
      AppLog.warn('读取会话副本失败', error: error);
      return null;
    }
  }

  /// 整份写进 JSON 副本；成功返回 true，调用方据此决定要不要再写 prefs。
  Future<bool> _writeMirror(StoredSession session) async {
    final path = _mirrorPath;
    if (path == null) {
      return false;
    }
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      // flush：这份数据丢了就补不回来，宁可多等一次落盘
      await file.writeAsString(jsonEncode(session.toJson()), flush: true);
      return true;
    } on Object catch (error) {
      AppLog.warn('写入会话副本失败', error: error);
      return false;
    }
  }
}
