import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omioclink_client/app_state.dart';
import 'package:omioclink_client/core/app_theme.dart';
import 'package:omioclink_client/data/api_client.dart';
import 'package:omioclink_client/data/models.dart';
import 'package:omioclink_client/data/server_endpoint.dart';
import 'package:omioclink_client/features/call_view.dart';
import 'package:omioclink_client/room/room_session.dart';
import 'package:omioclink_client/signaling/signaling_client.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'room_session_test.dart' show FakeMediaPort;

const _endpoint = ServerEndpoint(host: '127.0.0.1', port: 21077);
const _me = User(id: 7, username: 'alice', displayName: '小明');

/// 服务器能力位 + 空房间/好友列表的最小 REST 夹具。
AppState _buildState({required bool musicEnabled}) {
  return AppState(
    apiFactory: (endpoint) => ApiClient(
      endpoint: endpoint,
      httpClient: MockClient((request) async {
        final path = request.url.path;
        Object body = <String, dynamic>{'items': <Object>[], 'total': 0};
        if (path.endsWith('/server/info')) {
          body = <String, dynamic>{
            'name': 'OmiocLink',
            'version': '0.1.0',
            'allowRegistration': false,
            'iceServers': <String>['stun:stun.example.com:3478'],
            'musicEnabled': musicEnabled,
          };
        } else if (path.endsWith('/auth/login')) {
          body = <String, dynamic>{
            'accessToken': 'test-token',
            'expiresIn': 3600,
            'user': <String, dynamic>{
              'id': 7,
              'username': 'alice',
              'displayName': '小明',
            },
          };
        } else if (path.endsWith('/music/home')) {
          body = <String, dynamic>{
            'platform': 'wy',
            'topics': <dynamic>[
              <String, dynamic>{'id': 'night', 'name': '夜晚氛围', 'kind': 'search'},
            ],
            'charts': <dynamic>[],
          };
        } else if (path.endsWith('/music/platforms')) {
          body = <String, dynamic>{
            'items': <dynamic>[
              <String, dynamic>{
                'platform': 'wy',
                'name': '网易云音乐',
                'capabilities': <String>['search', 'charts'],
              },
            ],
            'total': 1,
          };
        } else if (path.endsWith('/music/charts')) {
          body = <String, dynamic>{
            'items': <dynamic>[],
            'total': 0,
            'errors': <dynamic>[],
          };
        }
        return http.Response(
          jsonEncode(body),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    ),
  );
}

/// 走完「连服务器 → 登录」的应用状态。
Future<AppState> _signedIn({required bool musicEnabled}) async {
  final state = _buildState(musicEnabled: musicEnabled);
  await state.connectToServer('127.0.0.1:21077');
  await state.signIn(username: 'alice', password: 'password123');
  return state;
}

/// 房间会话。
///
/// 这里刻意**不**走「建连 → 入房」的完整流程：那套夹具依赖真实时钟的
/// `pump()` 助手，而 `testWidgets` 跑在 FakeAsync 里会永久挂起。
/// 本用例只关心布局与页签，未入房的会话（成员为空、房间为 null）已经足够，
/// CallView 对空会话是安全的。
RoomSession _session() => RoomSession(
  signaling: SignalingClient(
    endpoint: _endpoint,
    accessToken: 'token',
    random: Random(11),
  ),
  media: FakeMediaPort(),
  currentUser: _me,
  statsInterval: const Duration(hours: 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> pumpCallView(
    WidgetTester tester, {
    required AppState state,
    required RoomSession session,
  }) async {
    // 通话页是给桌面大窗设计的：默认 800×600 会溢出（既有界面测试同样抬高画布）
    await tester.binding.setSurfaceSize(const Size(1320, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(backgroundColor: AppThemePacks.night.palette.stage, body: CallView(session: session)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('服务器开启点歌台：显示两个页签、氛围音卡片，可切到点歌台', (tester) async {
    final state = await _signedIn(musicEnabled: true);
    final session = _session();

    await pumpCallView(tester, state: state, session: session);

    expect(find.text('屏幕共享'), findsOneWidget);
    expect(find.text('点歌台'), findsOneWidget);
    // 共享页顶部是「房间氛围音」卡片，并带上那条架构说明
    expect(find.text('房间氛围音'), findsOneWidget);
    expect(find.text('等待点歌'), findsOneWidget);
    expect(
      find.text('客户端直连音源 · 服务端仅同步曲目与开始时间，不转发音频'),
      findsOneWidget,
    );

    await tester.tap(find.text('点歌台'));
    await tester.pumpAndSettle();

    // 点歌台只有三个模式：搜索 / 排行榜 / 热门歌单（旧的「推荐」页已经去掉）
    expect(find.text('排行榜'), findsOneWidget);
    expect(find.text('热门歌单'), findsOneWidget);
    expect(find.text('搜索歌曲、歌手或歌单'), findsOneWidget);
    expect(find.text('房间播放队列 (0)'), findsOneWidget);
    // 点歌台底部是常驻的正在播放条
    expect(find.text('还没有人点歌'), findsOneWidget);

    // 显式收尾：AppState 带着 5 秒房间轮询定时器，测试结束前必须释放，
    // 否则 Flutter 测试框架会报「Timer is still pending」
    session.dispose();
    state.dispose();
  });

  testWidgets('服务器关闭点歌台：不显示页签与氛围音卡片', (tester) async {
    final state = await _signedIn(musicEnabled: false);
    final session = _session();

    await pumpCallView(tester, state: state, session: session);

    expect(find.text('屏幕共享'), findsNothing);
    expect(find.text('点歌台'), findsNothing);
    expect(find.text('房间氛围音'), findsNothing);

    session.dispose();
    state.dispose();
  });
}
