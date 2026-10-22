import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/data/models.dart';
import 'package:omioclink_client/data/server_endpoint.dart';
import 'package:omioclink_client/features/screen_fullscreen.dart';
import 'package:omioclink_client/room/room_session.dart';
import 'package:omioclink_client/signaling/signaling_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'room_session_test.dart' show FakeMediaPort, memberPayload, roomStatePayload;
import 'signaling_client_test.dart' show FakeTransport, helloPayload, pump;

const _endpoint = ServerEndpoint(host: '127.0.0.1', port: 21077);
const _me = User(id: 7, username: 'alice', displayName: '小明');

/// 会话夹具：进房后房间里有一个共享屏幕的成员。
class _Harness {
  _Harness(this.session, this.signaling, this.transports);

  final RoomSession session;
  final SignalingClient signaling;
  final List<FakeTransport> transports;
}

Future<_Harness> _joinWithSharingMember({bool selfSharing = false}) async {
  final media = FakeMediaPort();
  // 「自己正在共享」必须是媒体层真的在采集：房间层进房时会按本地采集状态纠正
  // 服务器快照（避免服务端残留的 sharing=true 让界面画黑屏），只改快照会被纠回去
  media.screenSharing = selfSharing;
  final transports = <FakeTransport>[];
  final signaling = SignalingClient(
    endpoint: _endpoint,
    accessToken: 'token',
    random: Random(11),
    transportFactory: (uri) {
      final transport = FakeTransport(uri);
      transports.add(transport);
      return transport;
    },
  );
  final session = RoomSession(
    signaling: signaling,
    media: media,
    currentUser: _me,
    statsInterval: const Duration(hours: 1), // 测试里不跑统计定时器
  );

  final joinFuture = session.join(roomId: 'BX4K9K');
  // 建连是异步的：全量测试并行跑时事件循环被抢，单次 pump 可能还没连上
  for (var i = 0; i < 100 && transports.isEmpty; i += 1) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(transports, isNotEmpty, reason: '进房后应当建起信令连接');
  transports.first.emit(helloPayload());
  await pump();
  transports.first.emit(
    roomStatePayload(
      members: <Map<String, dynamic>>[
        memberPayload(
          peerId: 'ac4b0391',
          userId: 7,
          displayName: '小明',
          sharing: selfSharing,
        ),
        memberPayload(
          peerId: 'f9caeec5',
          userId: 8,
          displayName: '小红',
          sharing: !selfSharing,
        ),
      ],
    ),
  );
  await joinFuture;
  await pump();
  return _Harness(session, signaling, transports);
}

/// 宿主页：点按钮进入全屏，返回后靠这行文案证明已经退出。
class _Host extends StatelessWidget {
  const _Host({required this.session});

  final RoomSession session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('宿主页'),
            TextButton(
              onPressed: () => showScreenFullscreen(
                context,
                session: session,
                rendererOf: () => null, // 测试里不接真渲染器：走「正在接收…」分支
              ),
              child: const Text('看全屏'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _enterFullscreen(WidgetTester tester) async {
  await tester.tap(find.text('看全屏'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400)); // 转场动画
}

/// 窗口全屏的调用序列（`window_manager.setFullScreen` 的参数）。
List<bool> _fullScreenCalls(List<MethodCall> calls) => calls
    .where((call) => call.method == 'setFullScreen')
    .map(
      (call) =>
          (call.arguments as Map<Object?, Object?>)['isFullScreen'] as bool,
    )
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 这些用例会真的走 RoomSession.join，它会顺手读一次本机的成员音量偏好；
  // 没装 mock 的 SharedPreferences 在测试环境里会抛 MissingPluginException，
  // 表现为「偶发」的未捕获异步错误——这里补一个空实现。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 进全屏要真的去切系统全屏（无边框窗口下的「更大」），这里打桩记录调用。
  late List<MethodCall> windowCalls;

  setUp(() {
    windowCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          call,
        ) async {
          windowCalls.add(call);
          return null;
        });
  });

  testWidgets('全屏观看：显示共享者与退出按钮，Esc / 双击都能退出', (tester) async {
    late _Harness harness;
    await tester.runAsync(() async {
      harness = await _joinWithSharingMember();
    });

    await tester.pumpWidget(MaterialApp(home: _Host(session: harness.session)));
    await _enterFullscreen(tester);

    expect(find.text('小红 正在共享屏幕'), findsOneWidget);
    expect(find.text('退出全屏（Esc）'), findsOneWidget);
    // 退出按钮要贴着右上角：徽标那一栏是 Flexible 的，它若不撑满自己分到的宽度，
    // Row 末尾就会漏出一块空白，按钮会停在画面中间（修过一次的 bug，别再退回去）。
    final exitButton = tester.getRect(
      find
          .ancestor(
            of: find.text('退出全屏（Esc）'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    final windowWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(
      windowWidth - exitButton.right,
      lessThan(32),
      reason: '只留页面内边距，其余全部给画面',
    );
    expect(find.text('正在接收 小红 的屏幕…'), findsOneWidget);
    expect(find.text('宿主页'), findsNothing, reason: '全屏时盖住整块窗口');
    expect(_fullScreenCalls(windowCalls), <bool>[true], reason: '进入时切系统全屏');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('宿主页'), findsOneWidget, reason: 'Esc 退出全屏');
    expect(_fullScreenCalls(windowCalls), <bool>[true, false], reason: '退出时恢复窗口');

    // 再进一次，双击画面退出
    await _enterFullscreen(tester);
    expect(find.text('退出全屏（Esc）'), findsOneWidget);
    await tester.tapAt(const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(200, 200));
    await tester.pumpAndSettle();
    expect(find.text('宿主页'), findsOneWidget, reason: '双击画面退出全屏');

    await tester.runAsync(() async {
      harness.session.dispose();
      await harness.signaling.dispose();
    });
  });

  testWidgets('全屏观看：控制条几秒后自动隐藏，自己共享时显示本地预览标签', (tester) async {
    late _Harness harness;
    await tester.runAsync(() async {
      harness = await _joinWithSharingMember(selfSharing: true);
    });

    await tester.pumpWidget(MaterialApp(home: _Host(session: harness.session)));
    await _enterFullscreen(tester);

    expect(find.text('你正在共享屏幕 · 本地预览'), findsOneWidget);
    expect(find.text('正在启动共享…'), findsOneWidget);

    AnimatedOpacity controls() => tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(controls().opacity, 1, reason: '刚进来时控制条可见');

    await tester.pump(const Duration(seconds: 4));
    expect(controls().opacity, 0, reason: '鼠标不动就淡出，把画面让出来');

    // 鼠标一动又回来
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(300, 300));
    await tester.pump();
    await mouse.moveTo(const Offset(320, 320));
    await tester.pump();
    expect(controls().opacity, 1);
    await mouse.removePointer();

    await tester.runAsync(() async {
      harness.session.dispose();
      await harness.signaling.dispose();
    });
  });

  testWidgets('全屏观看：共享结束时自动退出，不把黑屏留在全屏上', (tester) async {
    late _Harness harness;
    await tester.runAsync(() async {
      harness = await _joinWithSharingMember();
    });

    await tester.pumpWidget(MaterialApp(home: _Host(session: harness.session)));
    await _enterFullscreen(tester);
    expect(find.text('小红 正在共享屏幕'), findsOneWidget);

    // 对方停止共享：服务端广播一条新的 room_state
    await tester.runAsync(() async {
      harness.transports.first.emit(
        roomStatePayload(
          members: <Map<String, dynamic>>[
            memberPayload(peerId: 'ac4b0391', userId: 7, displayName: '小明'),
            memberPayload(peerId: 'f9caeec5', userId: 8, displayName: '小红'),
          ],
        ),
      );
      await pump();
    });
    await tester.pumpAndSettle();

    expect(find.text('宿主页'), findsOneWidget, reason: '没人共享了就退出全屏');

    await tester.runAsync(() async {
      harness.session.dispose();
      await harness.signaling.dispose();
    });
  });
}
