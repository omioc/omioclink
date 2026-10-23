import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omioclink_client/core/app_locales.dart';
import 'package:omioclink_client/data/api_client.dart';
import 'package:omioclink_client/data/models.dart';
import 'package:omioclink_client/data/server_endpoint.dart';

const _endpoint = ServerEndpoint(host: '127.0.0.1', port: 21077);
const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

http.Response _json(Object payload, {int status = 200}) =>
    http.Response(jsonEncode(payload), status, headers: _jsonHeaders);

ApiClient _clientReturning(
  http.Response Function(http.Request request) handler,
) => ApiClient(
  endpoint: _endpoint,
  httpClient: MockClient((request) async => handler(request)),
);

void main() {
  group('请求构造', () {
    test('带 api 前缀、携带 Bearer 令牌、路径与查询串正确', () async {
      late http.Request captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json({'items': <Object>[], 'total': 0});
      })..token = 'jwt-token';

      await client.listRooms(scope: RoomScope.mine);

      expect(captured.method, 'GET');
      expect(
        captured.url.toString(),
        'http://127.0.0.1:21077/api/v1/rooms?scope=mine',
      );
      expect(captured.headers['Authorization'], 'Bearer jwt-token');
    });

    test('未登录时不带 Authorization 头', () async {
      late http.Request captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json({'status': 'ok'});
      });

      await client.serverInfo();

      expect(captured.headers.containsKey('Authorization'), isFalse);
    });
  });

  group('账号资料与密码', () {
    test('改昵称：PATCH /auth/me 只带昵称字段', () async {
      late http.Request captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json({'id': 7, 'username': 'alice', 'displayName': '新名字'});
      })..token = 'jwt-token';

      final user = await client.updateProfile(displayName: '新名字');

      expect(captured.method, 'PATCH');
      expect(captured.url.path, '/api/v1/auth/me');
      expect(jsonDecode(captured.body), {'displayName': '新名字'});
      expect(user.displayName, '新名字');
    });

    test('改密码：POST /auth/password 并返回新令牌', () async {
      late http.Request captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json({
          'accessToken': 'new-token',
          'expiresIn': 100,
          'user': {'id': 7, 'username': 'alice', 'displayName': '小明'},
        });
      })..token = 'jwt-token';

      final session = await client.changePassword(
        currentPassword: 'old-password',
        newPassword: 'new-password-1',
      );

      expect(captured.method, 'POST');
      expect(captured.url.path, '/api/v1/auth/password');
      expect(jsonDecode(captured.body), {
        'currentPassword': 'old-password',
        'newPassword': 'new-password-1',
      });
      expect(session.accessToken, 'new-token');
      expect(session.user.displayName, '小明');
    });

    test('上传头像：multipart 字段名是 file，且带令牌', () async {
      late http.Request captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json({
          'id': 7,
          'username': 'alice',
          'displayName': '小明',
          'avatar': 'abcdef0123456789',
        });
      })..token = 'jwt-token';

      final user = await client.uploadAvatar(
        Uint8List.fromList(utf8.encode('PNG-MARKER')),
        filename: 'me.png',
      );

      expect(captured.method, 'POST');
      expect(captured.url.path, '/api/v1/auth/avatar');
      expect(
        captured.headers['content-type'],
        startsWith('multipart/form-data; boundary='),
      );
      expect(captured.headers['Authorization'], 'Bearer jwt-token');
      expect(captured.body, contains('name="file"'));
      expect(captured.body, contains('filename="me.png"'));
      expect(captured.body, contains('PNG-MARKER'));
      expect(user.avatar, 'abcdef0123456789');
    });

    test('移除头像：DELETE /auth/avatar', () async {
      late http.Request captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json({
          'id': 7,
          'username': 'alice',
          'displayName': '小明',
          'avatar': null,
        });
      })..token = 'jwt-token';

      final user = await client.deleteAvatar();

      expect(captured.method, 'DELETE');
      expect(captured.url.path, '/api/v1/auth/avatar');
      expect(user.avatar, isNull);
    });

    test('拉头像字节：带版本号查询参数，不做 JSON 解码', () async {
      late http.Request captured;
      final client = _clientReturning((request) {
        captured = request;
        return http.Response.bytes(
          <int>[137, 80, 78, 71],
          200,
          headers: const {'content-type': 'image/png'},
        );
      })..token = 'jwt-token';

      final bytes = await client.avatarBytes(7, 'abcdef0123456789');

      expect(captured.method, 'GET');
      expect(captured.url.path, '/api/v1/avatars/7');
      expect(captured.url.queryParameters['v'], 'abcdef0123456789');
      expect(captured.headers['Authorization'], 'Bearer jwt-token');
      expect(bytes, <int>[137, 80, 78, 71]);
    });

    test('头像不存在时抛出带 code 的错误', () async {
      final client = _clientReturning(
        (request) => _json({
          'code': 'avatar_not_found',
          'message': '头像不存在',
        }, status: 404),
      );

      await expectLater(
        () => client.avatarBytes(7, 'abcdef0123456789'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'avatar_not_found')
              .having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });

    test('当前密码不对是 403，不能被当成登录态失效', () async {
      final client = _clientReturning(
        (request) => _json({
          'code': 'bad_current_password',
          'message': '当前密码不正确',
        }, status: 403),
      );

      // 关键：isUnauthorized 必须为 false——否则客户端会把它当成登录态失效而退出登录
      await expectLater(
        () => client.changePassword(
          currentPassword: 'wrong-one',
          newPassword: 'password123',
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'bad_current_password')
              .having((e) => e.isUnauthorized, 'isUnauthorized', isFalse),
        ),
      );
    });
  });

  group('错误映射', () {
    test('注册关闭时把服务端的 code 原样抛出', () async {
      final client = _clientReturning(
        (request) => _json({
          'code': 'registration_disabled',
          'message': '本服务器未开放注册',
        }, status: 403),
      );

      await expectLater(
        () => client.register(username: 'alice', password: 'password123'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'registration_disabled')
              .having((e) => e.message, 'message', '本服务器未开放注册')
              .having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
    });

    test('用户名被占用', () async {
      final client = _clientReturning(
        (request) => _json({
          'code': 'username_taken',
          'message': '用户名已被占用',
        }, status: 409),
      );

      await expectLater(
        () => client.register(username: 'alice', password: 'password123'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'username_taken'),
        ),
      );
    });

    test('401 可被识别为「需要重新登录」', () async {
      final client = _clientReturning(
        (request) => _json({
          'code': 'unauthorized',
          'message': '登录状态无效或已过期',
        }, status: 401),
      );

      await expectLater(
        () => client.me(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.isUnauthorized,
            'isUnauthorized',
            true,
          ),
        ),
      );
    });

    test('连接失败映射为 network_error，不把底层异常抛出去', () async {
      final client = ApiClient(
        endpoint: _endpoint,
        httpClient: MockClient(
          (request) async => throw http.ClientException('broken pipe'),
        ),
      );

      await expectLater(
        () => client.serverInfo(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'network_error')
              .having((e) => e.isNetworkIssue, 'isNetworkIssue', true),
        ),
      );
    });

    test('服务端返回非 JSON 时不崩，给出可读错误', () async {
      final client = _clientReturning(
        (request) => http.Response('<html>gateway error</html>', 502),
      );

      await expectLater(
        () => client.serverInfo(),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'bad_response'),
        ),
      );
    });

    test('204 无响应体时正常返回', () async {
      final client = _clientReturning((request) => http.Response('', 204));

      await expectLater(client.deleteRoom('BX4K9K'), completes);
    });
  });

  group('响应解析', () {
    test('登录返回令牌与用户', () async {
      final client = _clientReturning(
        (request) => _json({
          'accessToken': 'abc.def.ghi',
          'tokenType': 'bearer',
          'expiresIn': 604800,
          'user': {
            'id': 7,
            'username': 'alice',
            'displayName': '小明',
            'online': true,
          },
        }),
      );

      final auth = await client.login(
        username: 'alice',
        password: 'password123',
      );
      expect(auth.accessToken, 'abc.def.ghi');
      expect(auth.expiresIn, 604800);
      expect(auth.user.displayName, '小明');
      expect(auth.user.online, isTrue);
    });

    test('服务器信息包含注册开关与 ICE 列表', () async {
      final client = _clientReturning(
        (request) => _json({
          'name': 'OmiocLink',
          'version': '0.1.0',
          'protocolVersion': 1,
          'roomCapacity': 5,
          'maxRoomCapacity': 8,
          'allowRegistration': true,
          'iceServers': ['stun:stun.example.com:3478'],
          'heartbeatInterval': 30,
          'websocketPath': '/ws',
          'apiPrefix': '/api/v1',
          'mediaRelay': false,
        }),
      );

      final info = await client.serverInfo();
      expect(info.allowRegistration, isTrue);
      expect(info.iceServers, ['stun:stun.example.com:3478']);
      expect(info.mediaRelay, isFalse);
    });

    test('服务器未下发 allowRegistration 时默认为关闭', () {
      final info = ServerDescriptor.fromJson(const {
        'name': 'OmiocLink',
        'version': '0.1.0',
      });
      expect(info.allowRegistration, isFalse);
    });

    test('注册请求体包含用户名与密码', () async {
      late Map<String, dynamic> body;
      final client = _clientReturning((request) {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return _json({
          'accessToken': 't',
          'expiresIn': 1,
          'user': {'id': 1, 'username': 'alice', 'displayName': 'alice'},
        }, status: 201);
      });

      await client.register(username: 'alice', password: 'password123');
      expect(body, {'username': 'alice', 'password': 'password123'});
    });

    test('房间列表解析实时成员数', () async {
      final client = _clientReturning(
        (request) => _json({
          'total': 1,
          'items': [
            {
              'roomId': 'BX4K9K',
              'name': '游戏开黑',
              'ownerId': 7,
              'ownerName': '小明',
              'capacity': 5,
              'memberCount': 3,
              'hasPassword': true,
              'isPublic': true,
              'online': true,
              'joined': false,
            },
          ],
        }),
      );

      final rooms = await client.listRooms();
      expect(rooms, hasLength(1));
      expect(rooms.single.name, '游戏开黑');
      expect(rooms.single.memberCount, 3);
      expect(rooms.single.hasPassword, isTrue);
      expect(rooms.single.isFull, isFalse);
    });
  });

  group('点歌台', () {
    test('插件订阅：路径与结果解析', () async {
      late http.Request captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json({
          'urls': <String>['https://example.com/list.json', 'https://example.com/one.js'],
          'hash': 'sha256:abc123',
        });
      });

      final subscription = await client.musicPluginSubscription();

      expect(captured.url.path, '/api/v1/music/plugin-subscription');
      expect(subscription.urls, <String>[
        'https://example.com/list.json',
        'https://example.com/one.js',
      ]);
      expect(subscription.hash, 'sha256:abc123');
    });

    test('插件订阅：服务器没配置时是空列表、hash 可缺省', () async {
      final client = _clientReturning((request) => _json({'urls': <String>[]}));

      final subscription = await client.musicPluginSubscription();

      expect(subscription.urls, isEmpty);
      expect(subscription.hash, isNull);
    });
  });

  test('请求带 Accept-Language：服务端才知道用哪种语言回错误文案', () async {
    AppLocales.setActive('ja');
    addTearDown(() => AppLocales.setActive('zh'));

    String? sent;
    final client = _clientReturning((request) {
      sent =
          request.headers['Accept-Language'] ??
          request.headers['accept-language'];
      return _json(const <Object>[]);
    });
    await client.listRooms();
    expect(sent, 'ja');
  });
}
