import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/app_locales.dart';
import '../core/app_log.dart';
import '../core/l10n_ext.dart';
import '../signaling/protocol.dart';
import 'models.dart';
import 'server_endpoint.dart';

/// 服务端返回的结构化错误（`{code, message}`）。
class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.statusCode = 0,
  });

  final String code;
  final String message;
  final int statusCode;

  bool get isUnauthorized => statusCode == 401 || code == 'unauthorized';
  bool get isNetworkIssue => code == 'network_error' || code == 'timeout';

  @override
  String toString() => message;
}

/// REST 客户端。
class ApiClient {
  ApiClient({
    required this.endpoint,
    http.Client? httpClient,
    String? apiPrefix,
    this.timeout = const Duration(seconds: 15),
  }) : _http = httpClient ?? http.Client(),
       _apiPrefix = apiPrefix ?? '/api/v1';

  final ServerEndpoint endpoint;
  final Duration timeout;
  final http.Client _http;
  final String _apiPrefix;

  /// 登录后的 JWT；为空表示未登录。
  String? token;

  Uri _uri(String path, [Map<String, String>? query]) => endpoint.httpBase
      .replace(path: '$_apiPrefix$path', queryParameters: query);

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    final request = http.Request(method, _uri(path, query));
    request.headers['Accept'] = 'application/json';
    // 带语言：服务端的错误文案按这个头选，缺了就是中文
    request.headers['Accept-Language'] = AppLocales.activeLanguageCode;
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }
    _authorize(request);
    return _decode(await _perform(request));
  }

  /// 取二进制内容（头像）：不做 JSON 解码，直接把字节交出去。
  Future<Uint8List> _sendBytes(
    String method,
    String path, {
    Map<String, String>? query,
  }) async {
    final request = http.Request(method, _uri(path, query));
    request.headers['Accept'] = 'image/*';
    request.headers['Accept-Language'] = AppLocales.activeLanguageCode;
    _authorize(request);
    final response = await _perform(request);
    _ensureSuccess(response);
    return response.bodyBytes;
  }

  void _authorize(http.BaseRequest request) {
    final currentToken = token;
    if (currentToken != null && currentToken.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $currentToken';
    }
  }

  Future<http.Response> _perform(http.BaseRequest request) async {
    try {
      final streamed = await _http.send(request).timeout(timeout);
      return await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw ApiException(code: 'timeout', message: appL10n.apiTimeout);
    } on SocketException catch (error) {
      AppLog.warn('请求失败 ${request.url}', error: error);
      throw ApiException(
        code: 'network_error',
        message: appL10n.apiNetworkError,
      );
    } on http.ClientException catch (error) {
      AppLog.warn('请求失败 ${request.url}', error: error);
      throw ApiException(
        code: 'network_error',
        message: appL10n.apiInterrupted,
      );
    }
  }

  /// 失败时抛出带业务 code 的 [ApiException]（_decode 负责解析错误体）。
  void _ensureSuccess(http.Response response) {
    if (response.statusCode < 400) {
      return;
    }
    _decode(response);
    // _decode 对错误状态一定会抛；这行只是给类型系统一个交代
    throw ApiException(
      code: 'http_${response.statusCode}',
      message: appL10n.apiHttpFailed(response.statusCode),
      statusCode: response.statusCode,
    );
  }

  dynamic _decode(http.Response response) {
    final status = response.statusCode;
    if (status == 204 || response.body.isEmpty) {
      if (status >= 400) {
        throw ApiException(
          code: 'http_$status',
          message: appL10n.apiHttpFailed(status),
          statusCode: status,
        );
      }
      return null;
    }

    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw ApiException(
        code: 'bad_response',
        message: appL10n.apiBadResponse,
        statusCode: status,
      );
    }

    if (status >= 400) {
      final map = decoded is Map<String, dynamic>
          ? decoded
          : const <String, dynamic>{};
      throw ApiException(
        code: map['code'] as String? ?? 'http_$status',
        message: map['message'] as String? ?? appL10n.apiHttpFailed(status),
        statusCode: status,
      );
    }
    return decoded;
  }

  Map<String, dynamic> _asMap(dynamic value) =>
      value is Map<String, dynamic> ? value : const <String, dynamic>{};

  List<Map<String, dynamic>> _asList(dynamic value) {
    if (value is! Map<String, dynamic>) {
      return const <Map<String, dynamic>>[];
    }
    final items = value['items'];
    if (items is! List) {
      return const <Map<String, dynamic>>[];
    }
    return items.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  // ----------------------------------------------------------------- 账号
  Future<AuthSession> register({
    required String username,
    required String password,
    String? displayName,
  }) async {
    final body = await _send(
      'POST',
      '/auth/register',
      body: {
        'username': username,
        'password': password,
        if (displayName != null && displayName.isNotEmpty)
          'displayName': displayName,
      },
    );
    return AuthSession.fromJson(_asMap(body));
  }

  Future<AuthSession> login({
    required String username,
    required String password,
  }) async {
    final body = await _send(
      'POST',
      '/auth/login',
      body: {'username': username, 'password': password},
    );
    return AuthSession.fromJson(_asMap(body));
  }

  Future<User> me() async {
    final body = await _send('GET', '/auth/me');
    return User.fromJson(_asMap(body));
  }

  /// 修改密码。
  ///
  /// 服务端会作废此前签发的**所有**令牌，所以这里返回的是新签发的一张：
  /// 调用方必须用它替换本地保存的那张，否则下次重连就会 401。
  Future<AuthSession> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final body = await _send(
      'POST',
      '/auth/password',
      body: {'currentPassword': currentPassword, 'newPassword': newPassword},
    );
    return AuthSession.fromJson(_asMap(body));
  }

  /// 改昵称。头像不在这里改——见 [uploadAvatar] / [deleteAvatar]。
  Future<User> updateProfile({String? displayName}) async {
    final body = await _send(
      'PATCH',
      '/auth/me',
      body: {'displayName': ?displayName},
    );
    return User.fromJson(_asMap(body));
  }

  /// 上传头像。服务端只认文件头，文件名与 Content-Type 仅供参考。
  Future<User> uploadAvatar(
    Uint8List bytes, {
    String filename = 'avatar.png',
  }) async {
    final request = http.MultipartRequest('POST', _uri('/auth/avatar'));
    _authorize(request);
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: filename),
    );
    final response = await _perform(request);
    return User.fromJson(_asMap(_decode(response)));
  }

  Future<User> deleteAvatar() async {
    final body = await _send('DELETE', '/auth/avatar');
    return User.fromJson(_asMap(body));
  }

  /// 服务器配置的 MusicFree 插件订阅地址（客户端据此自动安装插件）。
  Future<({List<String> urls, String? hash})> musicPluginSubscription() async {
    final body = await _send('GET', '/music/plugin-subscription');
    final map = _asMap(body);
    final urls = (map['urls'] as List<dynamic>? ?? const <dynamic>[])
        .map((item) => item.toString())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final hash = map['hash']?.toString();
    return (urls: urls, hash: hash == null || hash.isEmpty ? null : hash);
  }

  /// 拉取某个用户的头像字节。
  ///
  /// 需要登录，所以不能用 `Image.network` 直接拿——由 `AvatarCache` 带令牌取回来
  /// 再交给 `Image.memory` 显示。
  Future<Uint8List> avatarBytes(int userId, String version) => _sendBytes(
    'GET',
    '/avatars/$userId',
    query: <String, String>{'v': version},
  );

  // ----------------------------------------------------------------- 服务器
  Future<ServerDescriptor> serverInfo() async {
    final body = await _send('GET', '/server/info');
    return ServerDescriptor.fromJson(_asMap(body));
  }

  // ----------------------------------------------------------------- 房间
  Future<List<Room>> listRooms({RoomScope scope = RoomScope.public}) async {
    final body = await _send('GET', '/rooms', query: {'scope': scope.name});
    return _asList(body).map(Room.fromJson).toList(growable: false);
  }

  Future<Room> createRoom({
    required String name,
    int? capacity,
    String? password,
    bool isPublic = true,
  }) async {
    final body = await _send(
      'POST',
      '/rooms',
      body: {
        'name': name,
        'capacity': ?capacity,
        if (password != null && password.isNotEmpty) 'password': password,
        'isPublic': isPublic,
      },
    );
    return Room.fromJson(_asMap(body));
  }

  Future<Room> getRoom(String roomId) async {
    final body = await _send('GET', '/rooms/$roomId');
    return Room.fromJson(_asMap(body));
  }

  Future<Room> updateRoom(
    String roomId, {
    String? name,
    int? capacity,
    bool? isPublic,
  }) async {
    final body = await _send(
      'PATCH',
      '/rooms/$roomId',
      body: {'name': ?name, 'capacity': ?capacity, 'isPublic': ?isPublic},
    );
    return Room.fromJson(_asMap(body));
  }

  Future<void> deleteRoom(String roomId) => _send('DELETE', '/rooms/$roomId');

  Future<List<MemberInfo>> roomMembers(String roomId) async {
    final body = await _send('GET', '/rooms/$roomId/members');
    return _asList(body).map(MemberInfo.fromJson).toList(growable: false);
  }

  /// 兜底退出房间（WebSocket 不可用时使用），返回被摘除的会话数。
  Future<int> leaveRoom(String roomId) async {
    final body = await _send('POST', '/rooms/$roomId/leave');
    final map = _asMap(body);
    return (map['left'] as num?)?.toInt() ?? 0;
  }

  // ----------------------------------------------------------------- 好友
  Future<List<Friend>> listFriends() async {
    final body = await _send('GET', '/friends');
    return _asList(body).map(Friend.fromJson).toList(growable: false);
  }

  Future<List<FriendRequest>> listFriendRequests() async {
    final body = await _send('GET', '/friends/requests');
    return _asList(body).map(FriendRequest.fromJson).toList(growable: false);
  }

  Future<FriendRequest> sendFriendRequest(String username) async {
    final body = await _send(
      'POST',
      '/friends/requests',
      body: {'username': username},
    );
    return FriendRequest.fromJson(_asMap(body));
  }

  Future<void> respondFriendRequest(int requestId, {required bool accept}) =>
      _send('POST', '/friends/requests/$requestId', body: {'accept': accept});

  Future<void> cancelFriendRequest(int requestId) =>
      _send('DELETE', '/friends/requests/$requestId');

  Future<void> removeFriend(String username) =>
      _send('DELETE', '/friends/$username');


  void close() => _http.close();
}
