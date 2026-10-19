import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omioclink_client/app_state.dart';
import 'package:omioclink_client/core/app_theme.dart';
import 'package:omioclink_client/data/api_client.dart';
import 'package:omioclink_client/features/home_shell.dart';
import 'package:omioclink_client/widgets/common.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 房间列表的响应体，字段与真实接口一致（本用例关心的是「我的房间」怎么展示）。
Map<String, dynamic> _room({
  required String roomId,
  required String name,
  bool isPublic = true,
  int ownerId = 7,
  String ownerName = '小明',
  int memberCount = 0,
}) => <String, dynamic>{
  'roomId': roomId,
  'name': name,
  'ownerId': ownerId,
  'ownerName': ownerName,
  'capacity': 8,
  'memberCount': memberCount,
  'hasPassword': false,
  'isPublic': isPublic,
  'online': memberCount > 0,
  'joined': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 登录后进主界面，返回状态。
  Future<AppState> signedIn(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final state = AppState(
      apiFactory: (endpoint) => ApiClient(
        endpoint: endpoint,
        httpClient: MockClient((request) async {
          final path = request.url.path;
          final Object body = switch (path) {
            _ when path.endsWith('/server/info') => <String, dynamic>{
              'name': 'OmiocLink',
              'version': '0.1.0',
              'allowRegistration': true,
              'iceServers': <String>[],
            },
            _ when path.endsWith('/auth/login') => <String, dynamic>{
              'accessToken': 'test-token',
              'expiresIn': 1,
              'user': <String, dynamic>{
                'id': 7,
                'username': 'alice',
                'displayName': '小明',
              },
            },
            // scope=mine（「我加入的房间」）＝ 我建的两个 + 我加入过的别人的一个；
            // 我建的：LOL（私有）、HAH（公开）；别人的：OTHR（公开，房主是小红的 id=8）
            _ when path.endsWith('/rooms') =>
              request.url.queryParameters['scope'] == 'mine'
                  ? <String, dynamic>{
                      'items': <Map<String, dynamic>>[
                        _room(
                          roomId: 'N35JSN',
                          name: 'LOL',
                          isPublic: false,
                          memberCount: 1,
                        ),
                        _room(roomId: 'BDZ2XH', name: 'HAH'),
                        _room(
                          roomId: 'OTHR01',
                          name: '红红の房',
                          ownerId: 8,
                          ownerName: '小红',
                        ),
                      ],
                      'total': 3,
                    }
                  : <String, dynamic>{
                      'items': <Map<String, dynamic>>[
                        _room(roomId: 'BDZ2XH', name: 'HAH'),
                        _room(
                          roomId: 'OTHR01',
                          name: '红红の房',
                          ownerId: 8,
                          ownerName: '小红',
                        ),
                      ],
                      'total': 2,
                    },
            _ => <String, dynamic>{'items': <Object>[], 'total': 0},
          };
          return http.Response(
            jsonEncode(body),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
    );
    addTearDown(state.dispose);
    // 主界面是给桌面窗口用的（默认 1320×860），测试画布别用 800×600 挤爆布局
    await tester.binding.setSurfaceSize(const Size(1320, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    expect(await state.connectToServer('127.0.0.1:21077'), isTrue);
    expect(await state.signIn(username: 'alice', password: 'password123'), isTrue);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        // 生产里 HomeShell 挂在 _Root 的 Scaffold 下（Material 祖先是它给的）
        child: const MaterialApp(home: Scaffold(body: HomeShell())),
      ),
    );
    await tester.pump();
    return state;
  }

  /// 收尾：先拆界面再释放状态。
  ///
  /// AppState 带 5 秒的房间列表轮询定时器，不显式 dispose 会被测试框架判成定时器泄漏。
  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  }

  /// 左栏导航行的选中态（判断两个控件各自的高亮）。
  bool navSelected(WidgetTester tester, String label) => tester
      .widget<NavRow>(
        find.ancestor(of: find.text(label), matching: find.byType(NavRow)),
      )
      .selected;

  /// tab 文字是否高亮（选中的那个用正文色，未选中是灰字）。
  bool tabSelected(WidgetTester tester, String label) {
    final color = tester.widget<Text>(find.text(label)).style?.color;
    return color == AppThemePacks.defaultPack.palette.textPrimary ||
        color == Colors.white;
  }

  testWidgets('默认进「我加入的」：我建的和别人建的都在，导航项不抢高亮', (tester) async {
    final state = await signedIn(tester);

    expect(find.text('我加入的房间'), findsWidgets, reason: '标题写清楚这是哪一套');
    expect(find.text('我创建的房间'), findsNothing);
    expect(tabSelected(tester, '我加入的'), isTrue, reason: '默认选中这个 tab');
    expect(tabSelected(tester, '公开'), isFalse);
    expect(navSelected(tester, '我的房间'), isFalse, reason: '两套各自高亮');

    // 中栏卡片按「房间号 …」定位（左栏不显示房间号）
    expect(find.textContaining('N35JSN'), findsOneWidget, reason: '我建的私有房');
    expect(find.textContaining('BDZ2XH'), findsOneWidget, reason: '我建的公开房');
    expect(find.textContaining('OTHR01'), findsOneWidget, reason: '加入过的别人的房也要在');
    expect(find.text('红红の房'), findsWidgets, reason: '左栏列表同样是这一套');

    await close(tester, state);
  });

  testWidgets('点导航「我的房间」＝另一套：只我创建的，别人建的房不混进来', (tester) async {
    final state = await signedIn(tester);

    await tester.tap(find.text('我的房间'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(navSelected(tester, '我的房间'), isTrue);
    expect(tabSelected(tester, '我加入的'), isFalse, reason: '切到导航那一套后 tab 不再高亮');
    expect(find.textContaining('N35JSN'), findsOneWidget);
    expect(find.textContaining('BDZ2XH'), findsOneWidget);
    expect(
      find.textContaining('OTHR01'),
      findsNothing,
      reason: '我加入过、但不是我建的房，不该出现在「我创建的房间」里',
    );
    expect(find.text('红红の房'), findsNothing, reason: '左栏列表同样只列我建的');

    // 再点回 tab：那一套数据原样回来（两套互不影响）
    await tester.tap(find.text('我加入的'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(tabSelected(tester, '我加入的'), isTrue);
    expect(navSelected(tester, '我的房间'), isFalse);
    expect(find.textContaining('OTHR01'), findsOneWidget);

    await close(tester, state);
  });

  testWidgets('手机端分段 tab 能直接切回「我创建的」（不用再点一次底部导航）', (tester) async {
    final state = await signedIn(tester);

    // 换成手机尺寸重挂一次：布局要按 393dp 的约束走，MediaQuery 也显式给成同一档
    // （test binding 里 setSurfaceSize 不改 MediaQuery，useCompactLayout 会读到旧尺寸）
    await tester.binding.setSurfaceSize(const Size(393, 852));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(393, 852)),
            child: Scaffold(body: HomeShell()),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('我加入'), findsOneWidget, reason: '手机端文案缩成「我加入」');
    expect(
      find.text('我创建'),
      findsOneWidget,
      reason: '「我创建的」必须在分段 tab 里，否则点完「公开」就回不去了',
    );

    await tester.tap(find.text('我创建'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('我创建的房间'), findsOneWidget);
    expect(find.textContaining('N35JSN'), findsOneWidget);
    expect(find.textContaining('BDZ2XH'), findsOneWidget);
    expect(
      find.textContaining('OTHR01'),
      findsNothing,
      reason: '别人建的房不该混进「我创建的」',
    );

    await close(tester, state);
  });

  testWidgets('选中房间就地展开操作区，不会把其它房间顶掉', (tester) async {
    final state = await signedIn(tester);

    // 点卡片（落在那行房间号上），等单击判定结束
    await tester.tap(find.textContaining('N35JSN'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('进入房间'), findsOneWidget, reason: '选中的房间展开操作区');
    expect(find.text('解散'), findsOneWidget, reason: '自己建的房间可以解散');
    expect(
      find.textContaining('BDZ2XH'),
      findsOneWidget,
      reason: '展开详情后，另一个自建房间仍然留在列表里',
    );

    // 切到公开 tab：私有房不在这个范围里，公开房照常列出
    await tester.tap(find.text('公开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.textContaining('N35JSN'), findsNothing);
    expect(find.textContaining('OTHR01'), findsOneWidget);
    expect(find.text('进入房间'), findsNothing, reason: '当前范围里没有选中项，不展开');

    await close(tester, state);
  });
}
