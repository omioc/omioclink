import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omioclink_client/app_state.dart';
import 'package:omioclink_client/data/api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _room({
  required String roomId,
  required String name,
  bool isPublic = true,
  int memberCount = 0,
  int ownerId = 7,
}) => <String, dynamic>{
  'roomId': roomId,
  'name': name,
  'ownerId': ownerId,
  'ownerName': '小明',
  'capacity': 5,
  'memberCount': memberCount,
  'hasPassword': false,
  'isPublic': isPublic,
  'online': memberCount > 0,
  'joined': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Uri> requested;
  late Map<String, dynamic> Function(Uri uri) handler;

  /// 让用例能模拟失败响应（默认 200）。
  late int status;

  AppState buildState() {
    requested = <Uri>[];
    return AppState(
      apiFactory: (endpoint) => ApiClient(
        endpoint: endpoint,
        httpClient: MockClient((request) async {
          requested.add(request.url);
          return http.Response(
            jsonEncode(handler(request.url)),
            status,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
    );
  }

  /// 走完「连服务器 → 登录」，此时房间列表已刷过一轮。
  Future<AppState> signedIn() async {
    final state = buildState();
    expect(await state.connectToServer('127.0.0.1:21077'), isTrue);
    expect(
      await state.signIn(username: 'alice', password: 'password123'),
      isTrue,
    );
    return state;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    status = 200;
    handler = (uri) {
      final path = uri.path;
      if (path.endsWith('/server/info')) {
        return <String, dynamic>{
          'name': 'OmiocLink',
          'version': '0.1.0',
          'allowRegistration': false,
          'iceServers': <String>['stun:stun.example.com:3478'],
        };
      }
      if (path.endsWith('/auth/login')) {
        return <String, dynamic>{
          'accessToken': 'test-token',
          'expiresIn': 1,
          'user': <String, dynamic>{
            'id': 7,
            'username': 'alice',
            'displayName': '小明',
          },
        };
      }
      if (path.endsWith('/rooms')) {
        return uri.queryParameters['scope'] == 'mine'
            ? <String, dynamic>{
                'items': <Map<String, dynamic>>[
                  _room(
                    roomId: 'PRIV01',
                    name: '我们的私密房',
                    isPublic: false,
                    memberCount: 2,
                  ),
                ],
                'total': 1,
              }
            : <String, dynamic>{
                'items': <Map<String, dynamic>>[
                  _room(roomId: 'PUB001', name: '游戏开黑', memberCount: 3),
                ],
                'total': 1,
              };
      }
      if (path.endsWith('/friends') || path.endsWith('/friends/requests')) {
        return <String, dynamic>{'items': <Object>[], 'total': 0};
      }
      return <String, dynamic>{'ok': true};
    };
  });

  test('房间列表同时拉公开与我的房间，私有房间不会消失', () async {
    final state = await signedIn();
    addTearDown(state.dispose);

    final scopes = requested
        .where((uri) => uri.path.endsWith('/rooms'))
        .map((uri) => uri.queryParameters['scope'])
        .toSet();
    expect(scopes, <String>{
      'public',
      'mine',
    }, reason: '两个范围都要请求：私房不在公开列表里，只拉公开列表会让用户自己的私房看不见');

    expect(state.publicRooms.map((room) => room.roomId), <String>['PUB001']);
    expect(state.myRooms.map((room) => room.roomId), <String>['PRIV01']);
  });

  test('「我创建的房间」只含我是房主的（我加入过的别人的房不算）', () async {
    final state = await signedIn();
    addTearDown(state.dispose);

    // 夹具里 scope=mine 只有一条 PRIV01（ownerId 7 = 自己）；
    // 这里再补一条「别人的房」，验证筛选是看 ownerId 而不是「在不在我的列表里」
    expect(state.myRooms.map((room) => room.roomId), <String>['PRIV01']);
    expect(state.createdRooms.map((room) => room.roomId), <String>['PRIV01']);
    expect(state.createdRooms.single.ownerId, state.user!.id);

    final joinedOthers = _room(roomId: 'JOIN01', name: '别人建的房', ownerId: 8);
    handler = (uri) => uri.path.endsWith('/rooms')
        ? <String, dynamic>{
            'items': <Map<String, dynamic>>[
              _room(roomId: 'PRIV01', name: '我的私密房', isPublic: false),
              joinedOthers,
            ],
            'total': 2,
          }
        : <String, dynamic>{'items': <Object>[], 'total': 0};
    await state.refreshRooms();

    expect(
      state.myRooms.map((room) => room.roomId),
      <String>['PRIV01', 'JOIN01'],
      reason: '「我加入的」两套数据都收',
    );
    expect(
      state.createdRooms.map((room) => room.roomId),
      <String>['PRIV01'],
      reason: '「我创建的房间」只有自己建的',
    );
  });

  test('刷新一次会把「我加入的」与「公开」两份列表都拿回来', () async {
    final state = await signedIn();
    addTearDown(state.dispose);

    expect(state.myRooms.map((room) => room.roomId), <String>['PRIV01']);
    expect(state.publicRooms.map((room) => room.roomId), <String>['PUB001']);
    expect(state.myRooms.single.isPublic, isFalse, reason: '自己的私有房只在「我加入的」里');

    // 只统计房间请求：登录之后还有音源脚本下发（/music/sources）等后台请求，
    // 它们与「刷新房间列表」无关。
    int roomRequests() =>
        requested.where((uri) => uri.path.endsWith('/rooms')).length;
    final before = roomRequests();
    await state.refreshRooms();
    expect(
      roomRequests() - before,
      2,
      reason: '一次刷新 = 两个 scope，各一发',
    );
  });

  test('未登录时不请求房间列表', () async {
    final state = buildState();
    addTearDown(state.dispose);
    await state.refreshRooms();
    expect(requested.where((uri) => uri.path.endsWith('/rooms')), isEmpty);
  });

  test('不在房间里时人数用列表快照', () async {
    final state = await signedIn();
    addTearDown(state.dispose);

    expect(state.session, isNull);
    for (final room in state.myRooms) {
      expect(state.memberCountFor(room), room.memberCount);
    }
  });

  test('登录成功后记住服务器地址、用户名与密码，供连接页回填', () async {
    final state = await signedIn();
    addTearDown(state.dispose);

    expect(state.rememberedLoaded, isTrue);
    expect(state.rememberedAddress, '127.0.0.1:21077');
    expect(state.rememberedUsername, 'alice');
    expect(state.rememberedPassword, 'password123');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('omioclink.server_address'), '127.0.0.1:21077');
    expect(prefs.getString('omioclink.username'), 'alice');
    expect(prefs.getString('omioclink.password'), 'password123');
  });

  test('启动时读回上次的地址、账号密码与记住的房间密码', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'omioclink.server_address': '127.0.0.1:21077',
      'omioclink.username': 'alice',
      'omioclink.password': 'password123',
      'omioclink.room_password.PRIV01': 'room-pw',
    });
    final state = buildState();
    addTearDown(state.dispose);

    await state.bootstrap();

    expect(state.rememberedAddress, '127.0.0.1:21077');
    expect(state.rememberedUsername, 'alice');
    expect(state.rememberedPassword, 'password123');
    expect(state.hasRememberedRoomPassword('PRIV01'), isTrue);
    expect(state.roomPasswordFor('PRIV01'), 'room-pw');
    expect(state.hasRememberedRoomPassword('NOPE01'), isFalse);
    expect(state.roomPasswordFor('NOPE01'), isNull);
  });

  test('连不上服务器时也要记住这个地址（否则下次会回到硬编码默认值）', () async {
    status = 503;
    final state = buildState();
    addTearDown(state.dispose);

    expect(await state.connectToServer('192.168.1.9:21077'), isFalse);

    expect(state.rememberedAddress, '192.168.1.9:21077');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('omioclink.server_address'), '192.168.1.9:21077');
  });

  test('退出登录回到未登录状态，且服务器地址/用户名/密码都留着', () async {
    final state = await signedIn();
    addTearDown(state.dispose);
    expect(state.isLoggedIn, isTrue);

    await state.logout();

    expect(state.isLoggedIn, isFalse, reason: '退出后要回登录页');
    expect(state.user, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('omioclink.access_token'),
      isNull,
      reason: '令牌必须清掉，否则下次启动又自动登录回来了',
    );
    expect(prefs.getString('omioclink.server_address'), '127.0.0.1:21077');
    expect(prefs.getString('omioclink.username'), 'alice');
    expect(prefs.getString('omioclink.password'), 'password123');
    expect(state.rememberedAddress, '127.0.0.1:21077');
    expect(state.rememberedUsername, 'alice');
    expect(state.rememberedPassword, 'password123');
  });

  test('好友申请接口解析失败时，好友列表照样落地（首屏不会一直空着）', () async {
    handler = (uri) {
      final path = uri.path;
      if (path.endsWith('/server/info')) {
        return <String, dynamic>{
          'name': 'OmiocLink',
          'version': '0.1.0',
          'allowRegistration': false,
          'iceServers': <String>[],
        };
      }
      if (path.endsWith('/auth/login')) {
        return <String, dynamic>{
          'accessToken': 'test-token',
          'expiresIn': 1,
          'user': <String, dynamic>{
            'id': 7,
            'username': 'alice',
            'displayName': '小明',
          },
        };
      }
      if (path.endsWith('/friends/requests')) {
        // 申请接口回来一条坏数据（id 不是数字）：解析会抛，整轮不能因此作废
        return <String, dynamic>{
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'not-a-number',
              'user': <String, dynamic>{'id': 9, 'username': 'carol'},
              'direction': 'incoming',
            },
          ],
          'total': 1,
        };
      }
      if (path.endsWith('/friends')) {
        return <String, dynamic>{
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'user': <String, dynamic>{
                'id': 8,
                'username': 'bob',
                'displayName': '小明',
              },
              'online': true,
            },
          ],
          'total': 1,
        };
      }
      if (path.endsWith('/rooms')) {
        return <String, dynamic>{'items': <Object>[], 'total': 0};
      }
      return <String, dynamic>{'ok': true};
    };

    final state = await signedIn();
    addTearDown(state.dispose);

    expect(
      state.friends,
      hasLength(1),
      reason: '好友接口成功就该落地，不能被申请接口的解析失败一起拖掉',
    );
    expect(state.friends.single.user.username, 'bob');
    expect(state.onlineFriends, hasLength(1));
  });

  test('启动时用记住的令牌自动登录，并立刻拉房间与好友（不用手动刷新）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'omioclink.server_address': '127.0.0.1:21077',
      'omioclink.access_token': 'test-token',
    });
    handler = (uri) {
      final path = uri.path;
      if (path.endsWith('/server/info')) {
        return <String, dynamic>{
          'name': 'OmiocLink',
          'version': '0.1.0',
          'allowRegistration': false,
          'iceServers': <String>[],
        };
      }
      if (path.endsWith('/auth/me')) {
        return <String, dynamic>{
          'id': 7,
          'username': 'alice',
          'displayName': '小明',
        };
      }
      if (path.endsWith('/rooms')) {
        return uri.queryParameters['scope'] == 'mine'
            ? <String, dynamic>{
                'items': <Map<String, dynamic>>[
                  _room(roomId: 'PRIV01', name: '我的私密房', isPublic: false),
                  _room(roomId: 'PUB002', name: '我的公开房'),
                ],
                'total': 2,
              }
            : <String, dynamic>{
                'items': <Map<String, dynamic>>[
                  _room(roomId: 'PUB001', name: '游戏开黑', memberCount: 3),
                ],
                'total': 1,
              };
      }
      if (path.endsWith('/friends') || path.endsWith('/friends/requests')) {
        return <String, dynamic>{'items': <Object>[], 'total': 0};
      }
      return <String, dynamic>{'ok': true};
    };

    final state = buildState();
    addTearDown(state.dispose);

    await state.bootstrap();

    expect(state.isLoggedIn, isTrue);
    expect(
      requested.where((uri) => uri.path.endsWith('/rooms')).map(
        (uri) => uri.queryParameters['scope'],
      ).toSet(),
      <String>{'public', 'mine'},
      reason: '首屏两个 tab 都要有数据，缺了自动登录后的这一轮刷新它们就是空的',
    );
    expect(state.publicRooms.map((room) => room.roomId), <String>['PUB001']);
    expect(state.myRooms.map((room) => room.roomId), <String>[
      'PRIV01',
      'PUB002',
    ], reason: '我创建的公开房与私有房都要在「我的房间」里');
    expect(
      requested.where((uri) => uri.path.endsWith('/friends')),
      isNotEmpty,
      reason: '好友列表同属首屏数据，也要一起拉',
    );
  });

  test('修改密码后记住的密码跟着换新（否则下次回填的是旧密码）', () async {
    final state = await signedIn();
    addTearDown(state.dispose);
    handler = (uri) => <String, dynamic>{
      'accessToken': 'token-2',
      'expiresIn': 1,
      'user': <String, dynamic>{
        'id': 7,
        'username': 'alice',
        'displayName': '小明',
      },
    };

    await state.changePassword(
      currentPassword: 'password123',
      newPassword: 'newpassword456',
    );

    expect(state.rememberedPassword, 'newpassword456');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('omioclink.password'), 'newpassword456');
  });

  test('改昵称：去掉首尾空格后落库并持久化', () async {
    final state = await signedIn();
    addTearDown(state.dispose);
    handler = (uri) => <String, dynamic>{
      'id': 7,
      'username': 'alice',
      'displayName': '小明改名了',
    };

    await state.updateDisplayName('  小明改名了  ');

    expect(state.user!.displayName, '小明改名了');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('omioclink.display_name'), '小明改名了');
    expect(state.error, isNull);
  });

  test('昵称没变 / 为空都不发请求', () async {
    final state = await signedIn();
    addTearDown(state.dispose);
    requested.clear();

    await state.updateDisplayName('小明'); // 与当前一致
    expect(requested, isEmpty);

    await expectLater(
      () => state.updateDisplayName('   '),
      throwsA(isA<ApiException>()),
    );
    expect(requested, isEmpty);
  });

  test('改密码成功后换用服务端新签发的令牌', () async {
    final state = await signedIn();
    addTearDown(state.dispose);
    handler = (uri) => <String, dynamic>{
      'accessToken': 'brand-new-token',
      'expiresIn': 100,
      'user': <String, dynamic>{
        'id': 7,
        'username': 'alice',
        'displayName': '小明',
      },
    };

    await state.changePassword(
      currentPassword: 'password123',
      newPassword: 'password456',
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('omioclink.access_token'), 'brand-new-token');
    expect(state.error, isNull);
  });

  test('上传头像后本地账号立刻带上新版本号', () async {
    final state = await signedIn();
    addTearDown(state.dispose);
    handler = (uri) => <String, dynamic>{
      'id': 7,
      'username': 'alice',
      'displayName': '小明',
      'avatar': 'abcdef0123456789',
    };

    await state.uploadAvatar(Uint8List.fromList(<int>[1, 2, 3]));

    expect(state.user!.avatar, 'abcdef0123456789');
    expect(state.error, isNull);
  });

  test('移除头像后版本号清空', () async {
    final state = await signedIn();
    addTearDown(state.dispose);
    handler = (uri) => <String, dynamic>{
      'id': 7,
      'username': 'alice',
      'displayName': '小明',
      'avatar': null,
    };

    await state.removeAvatar();

    expect(state.user!.avatar, isNull);
  });

  test('当前密码填错：原地抛错，登录态与令牌都不动', () async {
    final state = await signedIn();
    addTearDown(state.dispose);
    status = 403;
    handler = (uri) => <String, dynamic>{
      'code': 'bad_current_password',
      'message': '当前密码不正确',
    };

    await expectLater(
      () => state.changePassword(
        currentPassword: 'wrong-one',
        newPassword: 'password456',
      ),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'bad_current_password',
        ),
      ),
    );

    expect(state.user, isNotNull, reason: '不该被登出');
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('omioclink.access_token'),
      'test-token',
      reason: '失败时不能把本地令牌换掉',
    );
  });
}
