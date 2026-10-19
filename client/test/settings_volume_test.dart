import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omioclink_client/app_state.dart';
import 'package:omioclink_client/data/api_client.dart';
import 'package:omioclink_client/features/home_shell.dart';
import 'package:omioclink_client/media/mic_volume.dart';
import 'package:omioclink_client/media/mic_volume_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假录音设备端口：只记录写进来的 0~1 标量，绝不碰真实系统音量。
class FakeMicVolumePort implements MicVolumePort {
  FakeMicVolumePort([this._supported = true]);

  @override
  String? get lastError => null;

  final bool _supported;
  final List<double> writes = <double>[];
  double stored = 1.0;

  @override
  bool get supported => _supported;

  @override
  double? readVolume() => stored;

  @override
  bool writeVolume(double value) {
    if (!_supported) {
      return false;
    }
    writes.add(value);
    stored = value;
    return true;
  }

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 登录后进主界面，并把麦克风音量控制器换成假端口（不写真实设备音量）。
  Future<(AppState, FakeMicVolumePort)> signedIn(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final port = FakeMicVolumePort();
    final mic = MicVolumeController(
      port: port,
      load: () async => null,
      save: (_) async {},
    );
    final state = AppState(
      micVolume: mic,
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
            _ => <String, dynamic>{
              'items': <Object>[],
              'total': 0,
            },
          };
          return http.Response(
            jsonEncode(body),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
    );
    addTearDown(mic.dispose);
    addTearDown(state.dispose);
    // 放高一点，设置页整列（含音量卡片）都排进可点区域
    await tester.binding.setSurfaceSize(const Size(1320, 2200));
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
    return (state, port);
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.text('设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  }

  testWidgets('设置页渲染麦克风音量与音乐音量滑块，拖动即时生效', (tester) async {
    final (state, port) = await signedIn(tester);
    await openSettings(tester);

    final micSlider = find.byKey(const Key('mic-volume-slider'));
    final musicSlider = find.byKey(const Key('music-volume-slider'));
    expect(micSlider, findsOneWidget, reason: '设置页要有本机麦克风音量滑块');
    expect(musicSlider, findsOneWidget, reason: '设置页要有音乐音量滑块');
    expect(tester.widget<Slider>(micSlider).max, 100);
    expect(tester.widget<Slider>(musicSlider).max, 100);
    expect(find.text('麦克风音量（对方听到我的大小）'), findsOneWidget);
    expect(find.text('音乐音量（只影响本机）'), findsOneWidget);

    // 麦克风：拖到最左 → 0%，并且真的下发到（假的）录音设备
    await tester.drag(micSlider, const Offset(-2000, 0));
    await tester.pump();
    expect(state.micVolume, 0);
    expect(port.writes.last, 0);

    // 拖到最右 → 100%
    await tester.drag(micSlider, const Offset(2000, 0));
    await tester.pump();
    expect(state.micVolume, 100);
    expect(port.writes.last, 1.0);

    // 音乐：拖到最左 → 0%，再拖回 100%（只影响本机播放器）
    await tester.drag(musicSlider, const Offset(-2000, 0));
    await tester.pump();
    expect(state.musicVolume, 0);

    await tester.drag(musicSlider, const Offset(2000, 0));
    await tester.pump();
    expect(state.musicVolume, 100);

    await close(tester, state);
  });

  test('麦克风不支持时给出降级说明', () {
    final port = FakeMicVolumePort(false);
    final mic = MicVolumeController(
      port: port,
      load: () async => null,
      save: (_) async {},
    );
    expect(mic.supported, isFalse);
    expect(mic.notice, isNotNull);
    mic.dispose();
  });
}
