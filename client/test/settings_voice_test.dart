import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omioclink_client/app_state.dart';
import 'package:omioclink_client/core/app_locales.dart';
import 'package:omioclink_client/data/api_client.dart';
import 'package:omioclink_client/data/server_endpoint.dart';
import 'package:omioclink_client/features/home_shell.dart';
import 'package:omioclink_client/media/mic_volume_controller.dart';
import 'package:omioclink_client/media/voice_profile.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_volume_test.dart' show FakeMicVolumePort;

/// 走 MockClient 的接口工厂：与音量测试同一套桩，只回登录与空列表。
ApiClient _api(ServerEndpoint endpoint) => ApiClient(
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
      _ => <String, dynamic>{'items': <Object>[], 'total': 0},
    };
    return http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }),
);

/// 用假端口建一个麦克风音量控制器（不碰真实系统音量）。
MicVolumeController _fakeMicVolume() => MicVolumeController(
  port: FakeMicVolumePort(),
  load: () async => null,
  save: (_) async {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppState> signedIn(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppLocales.setActive('zh');
    final mic = _fakeMicVolume();
    final state = AppState(micVolume: mic, apiFactory: _api);
    addTearDown(mic.dispose);
    addTearDown(state.dispose);
    // 设置页整列很长（语音卡片在音量卡片下面），窗口放高一点才都能点到
    await tester.binding.setSurfaceSize(const Size(1320, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    expect(await state.connectToServer('127.0.0.1:21077'), isTrue);
    expect(await state.signIn(username: 'alice', password: 'password123'), isTrue);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: HomeShell())),
      ),
    );
    await tester.pump();
    return state;
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.text('设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
  }

  Future<void> tearDownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('设置页有语音档位卡片，默认标准档', (tester) async {
    final state = await signedIn(tester);
    await openSettings(tester);

    expect(find.text('语音处理'), findsOneWidget);
    for (final profile in VoiceProfile.values) {
      expect(
        find.byKey(Key('voice-profile-${profile.storageId}')),
        findsOneWidget,
        reason: '三档都要能选',
      );
      // 文案也要真的渲染出来（页面上同名的文字可能不止一处，按「至少一处」算）
      expect(find.text(profile.label), findsWidgets, reason: '档位文案要显示');
    }
    expect(state.voiceProfile, VoiceProfile.standard);

    await tearDownTree(tester);
    // 主动收尾：房间列表轮询是周期定时器，留到 test 结束会被判成「挂着的 Timer」
    state.dispose();
  });

  testWidgets('点「保真」切档并落盘（下次启动还按这一档采集）', (tester) async {
    final state = await signedIn(tester);
    await openSettings(tester);

    final tile = find.byKey(const Key('voice-profile-preserve'));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pump();
    expect(state.voiceProfile, VoiceProfile.preserve);

    await tester.pump(const Duration(milliseconds: 20));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('omioclink.voice.profile'), 'preserve');

    // 再切回标准档：同一张卡片上反复切换不能出错
    final back = find.byKey(const Key('voice-profile-standard'));
    await tester.ensureVisible(back);
    await tester.tap(back);
    await tester.pump();
    expect(state.voiceProfile, VoiceProfile.standard);

    await tearDownTree(tester);
    state.dispose();
  });

  testWidgets('启动时读回上次的档位', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'omioclink.voice.profile': 'aggressive',
    });
    AppLocales.setActive('zh');
    final mic = _fakeMicVolume();
    final state = AppState(micVolume: mic, apiFactory: _api);
    addTearDown(mic.dispose);
    addTearDown(state.dispose);

    // 构造里那次读取是异步的（共享偏好要等一次事件循环），先让它跑完
    await tester.pump(const Duration(milliseconds: 20));
    expect(state.voiceProfile, VoiceProfile.aggressive);
  });
}
